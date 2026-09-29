import AnimeGodCore
import Foundation
import Libmpv

/// `AnimeGod -smokeLink` — the link's test, standing in for a test target the
/// app does not have.
///
/// It exercises the whole server from outside: pairing, every JSON route, a
/// byte range compared against the file on disk, and — the one that decides an
/// architectural question — whether **libmpv can carry a bearer token**. The
/// plan puts the token in `http-header-fields` rather than the URL, because a
/// URL lands in logs and history. If mpv cannot do that, the auth design has
/// to become signed URLs instead, and it is much cheaper to learn that here
/// than after the phone is built on top of it.
@MainActor
enum LinkSmokeTest {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-smokeLink") }

    /// `AnimeGod -smokeLinkServe` — start the server, open pairing, and stay
    /// up. The development counterpart to `-smokeLink`: something has to be
    /// listening while the phone app is driven against it.
    static var servesOnly: Bool { ProcessInfo.processInfo.arguments.contains("-smokeLinkServe") }

    static func serve(model: AppModel) {
        model.link.start()
        model.link.beginPairing()
        say("serving; pairing code \(model.link.pairingCode ?? "none")")
        say("endpoints \(model.link.endpoints.joined(separator: ", "))")
    }

    /// Flushed explicitly: stdout is block-buffered when it is not a
    /// terminal, so a long-running serve mode would print nothing at all
    /// until it exited.
    private static func say(_ text: String) {
        print("SMOKE link: \(text)")
        fflush(stdout)
    }

    static func run(model: AppModel) async {
        say("starting server on port \(model.link.port)")
        model.link.start()

        for _ in 0..<40 where !model.link.isRunning {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard model.link.isRunning else {
            say("FAIL server did not start: \(model.link.lastError ?? "unknown")")
            exit(1)
        }
        say("listening on \(model.link.endpoints.joined(separator: ", "))")

        let base = URL(string: "http://127.0.0.1:\(model.link.port)")!
        var passed = 0, failed = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok { passed += 1; say("ok   \(name)") }
            else { failed += 1; say("FAIL \(name) \(detail)") }
        }

        // /health must answer without a token and must leak nothing else.
        do {
            let (data, response) = try await URLSession.shared.data(from: base.appending(path: "health"))
            let health = try LinkCoding.decoder.decode(LinkHealth.self, from: data)
            check("health answers unauthenticated", (response as? HTTPURLResponse)?.statusCode == 200)
            check("health carries the protocol version", health.protocolVersion == LinkProtocol.version)
        } catch {
            check("health", false, "\(error)")
        }

        // Everything else must refuse without a token.
        do {
            let (_, response) = try await URLSession.shared.data(from: base.appending(path: "library"))
            check("library refuses without a token", (response as? HTTPURLResponse)?.statusCode == 401)
        } catch {
            check("library refuses without a token", false, "\(error)")
        }

        // Pairing: a wrong code is refused, the right one issues a token.
        model.link.beginPairing()
        guard let code = model.link.pairingCode else {
            say("FAIL no pairing code")
            exit(1)
        }
        let wrong = code == "000000" ? "111111" : "000000"
        check("a wrong code is refused", await pair(base: base, code: wrong) == nil)
        guard let token = await pair(base: base, code: code) else {
            say("FAIL pairing with the right code did not return a token")
            exit(1)
        }
        check("pairing issues a token", token.count >= 40)

        func authorized(_ path: String, range: String? = nil) async throws -> (Data, HTTPURLResponse) {
            var request = URLRequest(url: base.appending(path: path))
            request.setValue("Bearer \(token)", forHTTPHeaderField: LinkProtocol.authorizationHeader)
            if let range { request.setValue(range, forHTTPHeaderField: "Range") }
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, response as! HTTPURLResponse)
        }

        var firstEpisode: LinkEpisode?
        do {
            let (data, response) = try await authorized("library")
            let library = try LinkCoding.decoder.decode(LinkLibrary.self, from: data)
            check("library answers with a token", response.statusCode == 200)
            check("library is not empty", !library.works.isEmpty, "\(library.works.count) works")
            say("library has \(library.works.count) works")

            if let work = library.works.first(where: { $0.episodeCount > 0 }) {
                let (detailData, detailResponse) = try await authorized("anime/\(work.id.uuidString)")
                let detail = try LinkCoding.decoder.decode(LinkAnimeDetail.self, from: detailData)
                check("detail answers", detailResponse.statusCode == 200)
                check("detail carries episodes", !detail.episodes.isEmpty)
                check("detail carries the displayed title", !detail.work.displayTitle.isEmpty)
                firstEpisode = detail.episodes.first
                say("first work: \(detail.work.displayTitle) — \(detail.episodes.count) episodes")
            }
        } catch {
            check("library", false, "\(error)")
        }

        do {
            let (data, response) = try await authorized("continue-watching")
            let items = try LinkCoding.decoder.decode([LinkEpisode].self, from: data)
            check("continue-watching answers", response.statusCode == 200)
            say("continue-watching has \(items.count) entries")
        } catch {
            check("continue-watching", false, "\(error)")
        }

        // The media route: the part that has to be right byte for byte.
        guard let episode = firstEpisode else {
            say("no episode to stream; stopping here")
            finish(passed: passed, failed: failed, model: model)
            return
        }
        guard let located = await model.locateMedia(mediaFileID: episode.mediaFileID) else {
            say("FAIL could not locate \(episode.label) on disk")
            finish(passed: passed, failed: failed + 1, model: model)
            return
        }
        defer { located.access.stop() }
        say("streaming \(episode.label) — \(located.size) bytes")

        do {
            let (head, headResponse) = try await authorized("media/\(episode.mediaFileID.uuidString)", range: "bytes=0-65535")
            check("range answers 206", headResponse.statusCode == 206, "got \(headResponse.statusCode)")
            check("range returns the asked-for length", head.count == 65536, "got \(head.count)")
            check(
                "range reports Content-Range",
                headResponse.value(forHTTPHeaderField: "Content-Range") == "bytes 0-65535/\(located.size)"
            )
            // Compared against the file itself: a server that returns the right
            // *number* of bytes from the wrong offset would play as corruption.
            let handle = try FileHandle(forReadingFrom: located.url)
            defer { try? handle.close() }
            let expected = try handle.read(upToCount: 65536) ?? Data()
            check("range bytes match the file", head == expected)

            // A suffix range is what a seek to the end of a Matroska file does.
            let suffix = min(Int64(4096), located.size)
            let (tail, tailResponse) = try await authorized("media/\(episode.mediaFileID.uuidString)", range: "bytes=-\(suffix)")
            check("suffix range answers 206", tailResponse.statusCode == 206)
            try handle.seek(toOffset: UInt64(located.size - suffix))
            let expectedTail = try handle.read(upToCount: Int(suffix)) ?? Data()
            check("suffix range bytes match the file", tail == expectedTail)

            let (_, badResponse) = try await authorized("media/\(episode.mediaFileID.uuidString)", range: "bytes=\(located.size + 10)-")
            check("a range past the end is 416", badResponse.statusCode == 416, "got \(badResponse.statusCode)")
        } catch {
            check("media range", false, "\(error)")
        }

        // The premise: can libmpv carry the token?
        let mediaURL = "http://127.0.0.1:\(model.link.port)/media/\(episode.mediaFileID.uuidString)"
        check("libmpv opens the stream with a bearer header", await mpvCanOpen(url: mediaURL, token: token))
        // And the negative: without the header it must fail, or the check above
        // proves nothing.
        check("libmpv is refused without the header", !(await mpvCanOpen(url: mediaURL, token: nil)))

        finish(passed: passed, failed: failed, model: model)
    }

    private static func pair(base: URL, code: String) async -> String? {
        var request = URLRequest(url: base.appending(path: "pair"))
        request.httpMethod = "POST"
        request.httpBody = try? LinkCoding.encoder.encode(LinkPairRequest(code: code, deviceName: "Smoke Test"))
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let paired = try? LinkCoding.decoder.decode(LinkPairResponse.self, from: data)
        else { return nil }
        return paired.token
    }

    /// A headless libmpv that only has to reach `MPV_EVENT_FILE_LOADED`.
    ///
    /// `vo=null`/`ao=null` keep it off the GPU and the audio device; this is a
    /// question about HTTP headers, not about rendering.
    private static func mpvCanOpen(url: String, token: String?) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let mpv = mpv_create() else { continuation.resume(returning: false); return }
                defer { mpv_terminate_destroy(mpv) }
                mpv_set_option_string(mpv, "vo", "null")
                mpv_set_option_string(mpv, "ao", "null")
                mpv_set_option_string(mpv, "ytdl", "no")
                mpv_set_option_string(mpv, "network-timeout", "5")
                if let token {
                    // The option under test.
                    mpv_set_option_string(mpv, "http-header-fields", "Authorization: Bearer \(token)")
                }
                guard mpv_initialize(mpv) >= 0 else { continuation.resume(returning: false); return }
                "loadfile".withCString { verb in
                    url.withCString { path in
                        var args: [UnsafePointer<CChar>?] = [verb, path, nil]
                        mpv_command(mpv, &args)
                    }
                }
                let deadline = Date.now.addingTimeInterval(20)
                while Date.now < deadline {
                    guard let event = mpv_wait_event(mpv, 0.25) else { break }
                    switch event.pointee.event_id {
                    case MPV_EVENT_FILE_LOADED:
                        continuation.resume(returning: true)
                        return
                    case MPV_EVENT_END_FILE:
                        let reason = event.pointee.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee.reason
                        if reason == MPV_END_FILE_REASON_ERROR {
                            continuation.resume(returning: false)
                            return
                        }
                    case MPV_EVENT_SHUTDOWN:
                        continuation.resume(returning: false)
                        return
                    default:
                        break
                    }
                }
                continuation.resume(returning: false)
            }
        }
    }

    private static func finish(passed: Int, failed: Int, model: AppModel) {
        model.link.stop()
        say("\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
