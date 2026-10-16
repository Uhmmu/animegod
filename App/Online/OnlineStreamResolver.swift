import AnimeGodCore
import Foundation
import WebKit

/// Where an episode's video actually is, once a browser has been let at the
/// page.
struct ResolvedStream: Sendable, Equatable {
    let url: URL
    /// Headers the stream has to be fetched with, from the rule.
    let headers: [String: String]
    /// How the URL was found, for the diagnostics line on the page.
    let method: Method

    enum Method: String, Sendable {
        /// A `<video>` element's own `src`.
        case videoElement
        /// An `#EXTM3U` playlist seen going past as the page fetched it.
        case playlistRequest
        /// A player iframe whose query string carries the media URL.
        case iframeQuery
    }
}

enum OnlineStreamError: Error, LocalizedError {
    case timedOut(seconds: Int)
    case cancelled
    case notFound

    var errorDescription: String? {
        switch self {
        case let .timedOut(seconds):
            String(localized: "The page did not give up a video within \(seconds) seconds.")
        case .cancelled:
            String(localized: "Finding the video was cancelled.")
        case .notFound:
            String(localized: "No video was found on that page.")
        }
    }
}

/// Turns an episode's page into a URL mpv can play, by loading the page in a
/// headless browser and watching what it reaches for.
///
/// A rule can say where a work's episodes are listed, and that is as far as
/// selectors go: the stream itself is assembled by the site's own
/// JavaScript, usually in a nested player iframe, usually from a signed or
/// rewritten URL that is nowhere in the HTML.
///
/// That is not a theory about these sites, it is measured. One episode page
/// here publishes a complete media URL in its own `player_aaaa` JSON —
/// `https://play.xfvod.pro:8088/…/01.mp4`, which answers **401** to any
/// request, with or without a referer. The URL its player JavaScript
/// actually plays is the same path on the same host *without the port*, and
/// that one answers `206 video/mp4`. So a parser that reads the page and
/// skips the browser would look like it worked, hand over a URL, and fail at
/// playback — the worst shape a failure can take. The browser is
/// load-bearing.
///
/// Two scripts do the watching, which is Kazumi's approach and for the same
/// reasons:
///
/// - At document start, `Response.prototype.text` and
///   `XMLHttpRequest.open` are wrapped so any response whose body begins
///   `#EXTM3U` reports its own URL. An HLS playlist is fetched by the player
///   before it plays anything, so this catches the stream even when it never
///   reaches a `<video>` tag that has a `src`.
/// - At document end, a `MutationObserver` watches for a `<video>` element
///   gaining a `src`, which is how a plain MP4 arrives.
///
/// Both are injected into every frame, because the player is two iframes
/// deep: measured on one episode, the page loaded
/// `player.moedot.net/player/index.php`, which loaded `ec.php`, which is
/// where the video appeared.
@MainActor
final class OnlineStreamResolver: NSObject {
    /// Why this is generous: a real resolution on a working site took **9.96
    /// seconds** — three nested frames, each loading its own scripts, before
    /// the video element appeared. A tight timeout would report "no video"
    /// for a site that was about to answer.
    static let defaultTimeout: TimeInterval = 25

    private var webView: WKWebView?
    /// One resolution at a time: there is one browser, and loading a second
    /// page would cancel the first one's frames out from under it.
    private var pending: CheckedContinuation<ResolvedStream, Error>?
    private var rule: OnlineSourceRule?
    private var timeoutTask: Task<Void, Never>?
    private var isResolving = false
    /// A URL an iframe offered, kept in case nothing better arrives. See
    /// `accept(_:method:)` for why it is not taken straight away.
    private var fallback: ResolvedStream?

    /// The log this resolution produced, which is what the rule editor shows
    /// when a source stops working.
    private(set) var log: [String] = []

    func resolve(
        episodePageURL: String,
        rule: OnlineSourceRule,
        timeout: TimeInterval = OnlineStreamResolver.defaultTimeout
    ) async throws -> ResolvedStream {
        guard let url = URL(string: episodePageURL), url.scheme != nil else {
            throw OnlineStreamError.notFound
        }
        if isResolving { finish(.failure(OnlineStreamError.cancelled)) }
        isResolving = true
        self.rule = rule
        fallback = nil
        log = []

        let webView = prepareWebView(for: rule)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(timeout))
                    guard !Task.isCancelled else { return }
                    await self?.finishOnTimeout(after: timeout)
                }
                var request = URLRequest(url: url)
                // A site that checks the referer on its pages checks it here
                // too, before any stream is involved.
                for (name, value) in rule.playbackHeaders where name == "Referer" {
                    request.setValue(value, forHTTPHeaderField: name)
                }
                webView.load(request)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func cancel() {
        guard isResolving else { return }
        finish(.failure(OnlineStreamError.cancelled))
    }

    /// Leaves the browser alive but on a blank page.
    ///
    /// The page that was just resolved holds a player that would otherwise
    /// go on buffering video nobody is watching; the browser itself is kept
    /// because building one per episode is what makes switching episodes
    /// slow.
    func unload() {
        webView?.load(URLRequest(url: URL(string: "about:blank")!))
    }

    func dispose() {
        cancel()
        webView?.stopLoading()
        webView?.configuration.userContentController.removeAllUserScripts()
        for name in [Bridge.log, Bridge.video, Bridge.iframe] {
            webView?.configuration.userContentController.removeScriptMessageHandler(forName: name)
        }
        webView = nil
    }

    // MARK: - The browser

    private enum Bridge {
        static let log = "AGLogBridge"
        static let video = "AGVideoBridge"
        static let iframe = "AGIframeBridge"
    }

    private func prepareWebView(for rule: OnlineSourceRule) -> WKWebView {
        if let webView {
            webView.customUserAgent = rule.userAgent.isEmpty
                ? OnlineSourceUserAgent.desktopSafari
                : rule.userAgent
            return webView
        }

        let configuration = WKWebViewConfiguration()
        // Nothing is kept: a resolution should not leave a login, a consent
        // cookie or a cache behind in the app's own web storage.
        configuration.websiteDataStore = .nonPersistent()
        // The page may autoplay; this stops it fetching the video itself,
        // since all that is wanted is the URL.
        configuration.mediaTypesRequiringUserActionForPlayback = .all

        let controller = configuration.userContentController
        controller.add(self, name: Bridge.log)
        controller.add(self, name: Bridge.video)
        controller.add(self, name: Bridge.iframe)
        controller.addUserScript(
            WKUserScript(source: Self.playlistHookScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )
        controller.addUserScript(
            WKUserScript(source: Self.videoElementScript, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
        )
        // An iframe-based rule needs the frame's own URL reported instead:
        // the media URL is sitting in its query string.
        controller.addUserScript(
            WKUserScript(source: Self.iframeScript, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
        )

        // The player pages carry ad frames that open their own windows and
        // load their own video. Blocking them is not tidiness: an ad's
        // `<video>` is indistinguishable from the episode's to the observer
        // above, and whichever appears first would be played.
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 700), configuration: configuration)
        Self.installAdBlocking(on: webView)
        webView.customUserAgent = rule.userAgent.isEmpty
            ? OnlineSourceUserAgent.desktopSafari
            : rule.userAgent
        webView.navigationDelegate = self
        self.webView = webView
        return webView
    }

    private static func installAdBlocking(on webView: WKWebView) {
        let rules = """
        [
          {"trigger": {"url-filter": ".*", "resource-type": ["image"]},
           "action": {"type": "block"}},
          {"trigger": {"url-filter": "googleads|googlesyndication|doubleclick|adtrafficquality|prestrain"},
           "action": {"type": "block"}},
          {"trigger": {"url-filter": "devtools-detector"},
           "action": {"type": "block"}}
        ]
        """
        WKContentRuleListStore.default()?.compileContentRuleList(
            forIdentifier: "AnimeGodOnlineSources", encodedContentRuleList: rules
        ) { list, _ in
            guard let list else { return }
            MainActor.assumeIsolated { webView.configuration.userContentController.add(list) }
        }
    }

    // MARK: - Finishing

    /// The page never played anything. An iframe's own offer is used here
    /// rather than nowhere — it is a guess, and a guess beats refusing to
    /// play a page the user asked for.
    private func finishOnTimeout(after timeout: TimeInterval) {
        if let fallback {
            note("nothing played within \(Int(timeout))s; using the URL the iframe offered")
            finish(.success(fallback))
        } else {
            finish(.failure(OnlineStreamError.timedOut(seconds: Int(timeout))))
        }
    }

    private func finish(_ result: Result<ResolvedStream, Error>) {
        guard let continuation = pending else { return }
        pending = nil
        fallback = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        isResolving = false
        webView?.stopLoading()
        unload()
        continuation.resume(with: result)
    }

    /// Takes a candidate, but only settles for one the page has actually
    /// played.
    ///
    /// The three ways a URL turns up are not equally trustworthy, and the
    /// difference is the whole reason this is not first-past-the-post:
    ///
    /// - A `<video>` element's `src`, or a playlist the page fetched, is the
    ///   URL the page is playing. That is the answer.
    /// - A player iframe's query parameter is only what the page *handed to*
    ///   a player, and the player may rewrite it before playing.
    ///
    /// Measured on one episode of one site: the iframe's query carried
    /// `https://play.xfvod.pro:8088/…/01.mp4` after **2.21 seconds**, and
    /// that URL answers **401** to every request. The `<video>` element put
    /// up the same path on the same host *without the port* after **9.96
    /// seconds**, and that one answers `206 video/mp4`. Taking the first
    /// candidate is therefore a resolution that looks instant, looks right,
    /// and does not play.
    ///
    /// So an iframe candidate is remembered and waited past; it is only used
    /// if the timeout arrives with nothing better, where it beats failing.
    private func accept(_ candidate: String, method: ResolvedStream.Method) {
        guard isResolving, let rule else { return }
        guard let url = Self.mediaURL(from: candidate, method: method) else {
            // Logged rather than dropped: a page whose every candidate is
            // rejected is the hard case to diagnose, and the rejects are
            // what say whether the player was ever reached.
            if method == .iframeQuery, !candidate.contains("about:blank") {
                note("iframe carried no media URL: \(candidate.prefix(160))")
            }
            return
        }
        guard method == .iframeQuery else {
            note("video found by \(method.rawValue): \(url.absoluteString)")
            finish(.success(ResolvedStream(url: url, headers: rule.playbackHeaders, method: method)))
            return
        }
        guard fallback == nil else { return }
        note("iframe offers \(url.absoluteString) — waiting for the player's own URL")
        fallback = ResolvedStream(url: url, headers: rule.playbackHeaders, method: method)
    }

    private func note(_ message: String) {
        guard log.count < 400 else { return }
        log.append(message)
    }

    /// Reads a playable URL out of what a page reported.
    ///
    /// For an iframe the URL is not the frame's — it is a parameter *of* the
    /// frame's, because these players are given the media URL in their query
    /// string (`…/player/ec.php?url=https://cdn/…/01.mp4`). A frame whose
    /// query holds no media URL is an ad or a wrapper and is passed over,
    /// which is what stops a resolution settling on the first iframe a page
    /// happens to contain.
    static func mediaURL(from candidate: String, method: ResolvedStream.Method) -> URL? {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("blob:"), !trimmed.hasPrefix("data:") else { return nil }
        guard method == .iframeQuery else {
            return URL(string: trimmed).flatMap { $0.scheme?.hasPrefix("http") == true ? $0 : nil }
        }
        guard let components = URLComponents(string: trimmed) else { return nil }
        for item in components.queryItems ?? [] {
            guard let value = item.value?.removingPercentEncoding ?? item.value else { continue }
            guard value.range(of: #"^https?://.+\.(m3u8|mp4|flv|mkv)"#, options: [.regularExpression, .caseInsensitive]) != nil
            else { continue }
            if let url = URL(string: value) { return url }
        }
        return nil
    }

    // MARK: - Injected scripts

    /// Reports any response that turns out to be an HLS playlist.
    ///
    /// Both `fetch` and `XMLHttpRequest` are wrapped because the players in
    /// use here are split between the two, and the playlist is fetched
    /// before anything is rendered — so this usually answers before a
    /// `<video>` element exists at all.
    private static let playlistHookScript = """
    (function () {
      const report = (url) => {
        try { window.webkit.messageHandlers.\(Bridge.video).postMessage(String(url)); } catch (e) {}
      };
      const text = window.Response.prototype.text;
      window.Response.prototype.text = function () {
        return new Promise((resolve, reject) => {
          text.call(this).then((body) => {
            resolve(body);
            if (body.trim().startsWith("#EXTM3U")) report(this.url);
          }).catch(reject);
        });
      };
      const open = window.XMLHttpRequest.prototype.open;
      window.XMLHttpRequest.prototype.open = function (...args) {
        this.addEventListener("load", () => {
          try {
            if (this.responseText.trim().startsWith("#EXTM3U")) report(args[1]);
          } catch (e) {}
        });
        return open.apply(this, args);
      };
      try {
        window.webkit.messageHandlers.\(Bridge.log).postMessage("playlist hook installed: " + location.href);
      } catch (e) {}
    })();
    """

    /// Reports a `<video>` element's source, now or whenever it gains one.
    private static let videoElementScript = """
    (function () {
      const report = (url) => {
        try { window.webkit.messageHandlers.\(Bridge.video).postMessage(String(url)); } catch (e) {}
      };
      function inspect(video) {
        let source = video.getAttribute("src");
        if (source && source.trim() !== "" && !source.startsWith("blob:")) { report(source); return true; }
        for (const child of video.getElementsByTagName("source")) {
          source = child.getAttribute("src");
          if (source && source.trim() !== "" && !source.startsWith("blob:")) { report(source); return true; }
        }
        return false;
      }
      for (const video of document.querySelectorAll("video")) { if (inspect(video)) return; }
      new MutationObserver((mutations) => {
        for (const mutation of mutations) {
          if (mutation.type === "attributes" && mutation.target.nodeName === "VIDEO") inspect(mutation.target);
          for (const node of mutation.addedNodes) {
            if (node.nodeName === "VIDEO") inspect(node);
            if (node.querySelectorAll) { for (const video of node.querySelectorAll("video")) inspect(video); }
          }
        }
      }).observe(document.documentElement, {
        childList: true, subtree: true, attributes: true, attributeFilter: ["src"]
      });
    })();
    """

    /// Reports every iframe source, for the rules whose sites hand the media
    /// URL to a player frame rather than ever creating a `<video>` tag.
    private static let iframeScript = """
    (function () {
      const report = (url) => {
        try { window.webkit.messageHandlers.\(Bridge.iframe).postMessage(String(url)); } catch (e) {}
      };
      const scan = () => {
        for (const frame of document.querySelectorAll("iframe")) {
          const source = frame.getAttribute("src");
          if (source) report(source);
        }
      };
      scan();
      new MutationObserver(scan).observe(document.documentElement, {
        childList: true, subtree: true, attributes: true, attributeFilter: ["src"]
      });
    })();
    """
}

extension OnlineStreamResolver: WKScriptMessageHandler {
    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        let body = "\(message.body)"
        switch message.name {
        case Bridge.log:
            note(body)
        case Bridge.video:
            // A playlist URL and a video element's src are both complete
            // media URLs; which one arrived says how it was found.
            accept(body, method: body.lowercased().contains(".m3u8") ? .playlistRequest : .videoElement)
        case Bridge.iframe:
            accept(body, method: .iframeQuery)
        default:
            break
        }
    }
}

extension OnlineStreamResolver: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url?.absoluteString, url != "about:blank" else { return }
        note("loaded \(url)")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        note("failed: \(error.localizedDescription)")
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // A player page tries to open its ad in a new window and, failing
        // that, navigates the frame it is in — which throws away the player
        // that was about to produce the stream. Only the frames the page
        // itself needs are allowed.
        guard let url = navigationAction.request.url?.absoluteString.lowercased() else {
            decisionHandler(.allow)
            return
        }
        let advertising = ["googleads", "googlesyndication", "doubleclick", "adtrafficquality", "prestrain"]
        decisionHandler(advertising.contains(where: url.contains) ? .cancel : .allow)
    }
}
