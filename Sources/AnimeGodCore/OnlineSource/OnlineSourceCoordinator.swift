import Foundation

/// How one source answered a search.
///
/// Each case is a different thing to put on screen. "Searching" and "nothing
/// found" and "broken" look the same in a list that only shows results, and
/// telling them apart is what makes a page of twelve sources readable: a
/// source that has never carried this show is not a source the user should
/// go and fix.
public enum OnlineSourceStatus: Sendable, Equatable {
    case searching
    case found(Int)
    case noResults
    case failed(String)
    case needsNewerClient
}

/// Runs a search across every installed rule at once, and reads an episode
/// list from one.
///
/// Concurrent because the sources are unrelated and most of a search is
/// waiting: one slow site must not hold up the eleven that already answered.
/// Results are published per source as they land rather than gathered at the
/// end, for the same reason.
public actor OnlineSourceCoordinator {
    private let engine = OnlineSourceEngine()
    private let session: URLSession
    private let timeout: TimeInterval

    public init(session: URLSession? = nil, timeout: TimeInterval = 20) {
        self.timeout = timeout
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = timeout
            configuration.httpCookieAcceptPolicy = .always
            // A redirect to the page that was asked for is ordinary here;
            // these sites redirect search to a canonical path constantly.
            configuration.httpShouldSetCookies = true
            self.session = URLSession(configuration: configuration)
        }
    }

    /// What one source produced, as it is produced.
    public struct Answer: Sendable {
        public let ruleName: String
        public let status: OnlineSourceStatus
        public let items: [OnlineSearchItem]

        init(ruleName: String, status: OnlineSourceStatus, items: [OnlineSearchItem] = []) {
            self.ruleName = ruleName
            self.status = status
            self.items = items
        }
    }

    /// Searches every rule, handing each answer back the moment it arrives.
    public func search(
        keyword: String,
        rules: [OnlineSourceRule],
        onAnswer: @Sendable @escaping (Answer) -> Void
    ) async {
        await withTaskGroup(of: Void.self) { group in
            for rule in rules {
                group.addTask { [weak self] in
                    guard let self else { return }
                    let answer = await self.search(keyword: keyword, rule: rule)
                    onAnswer(answer)
                }
            }
        }
    }

    /// Searches every rule and returns the answers together, for callers
    /// that have nothing to show until the search is over.
    public func search(keyword: String, rules: [OnlineSourceRule]) async -> [Answer] {
        await withTaskGroup(of: Answer.self) { group in
            for rule in rules {
                group.addTask { [weak self] in
                    await self?.search(keyword: keyword, rule: rule)
                        ?? Answer(ruleName: rule.name, status: .searching)
                }
            }
            var answers: [Answer] = []
            for await answer in group { answers.append(answer) }
            // Back into the order the rules are listed in, which is the
            // user's own ordering and not the order the sites replied in.
            let position = Dictionary(
                uniqueKeysWithValues: rules.enumerated().map { ($1.id, $0) }
            )
            return answers.sorted {
                (position[OnlineSourceRule.identityKey($0.ruleName)] ?? 0)
                    < (position[OnlineSourceRule.identityKey($1.ruleName)] ?? 0)
            }
        }
    }

    public func search(keyword: String, rule: OnlineSourceRule) async -> Answer {
        do {
            let request = try engine.searchRequest(rule, keyword: keyword)
            let data = try await send(request)
            let result = try engine.parseSearch(data, rule: rule)
            return Answer(ruleName: rule.name, status: .found(result.items.count), items: result.items)
        } catch OnlineSourceError.noResults {
            return Answer(ruleName: rule.name, status: .noResults)
        } catch OnlineSourceError.requiresNewerClient {
            return Answer(ruleName: rule.name, status: .needsNewerClient)
        } catch is CancellationError {
            return Answer(ruleName: rule.name, status: .searching)
        } catch {
            return Answer(ruleName: rule.name, status: .failed(Self.describe(error)))
        }
    }

    /// The playback lines of one work.
    public func chapters(pageURL: String, rule: OnlineSourceRule) async throws -> OnlineChapterResult {
        let request = try engine.chapterRequest(rule, pageURL: pageURL)
        return try engine.parseChapters(try await send(request), rule: rule)
    }

    // MARK: - Sending

    private func send(_ request: OnlineSourceRequest) async throws -> Data {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: timeout)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw OnlineSourceError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { return data }
        // An anti-bot interstitial arrives as a page, often with a 2xx, and
        // parsing it would report "no results" for a site that is simply
        // refusing this request — a different thing to tell the user and a
        // different thing to do about it.
        if TorrentHTTPClient.isChallenge(http, data: data) { throw OnlineSourceError.blocked }
        guard (200..<300).contains(http.statusCode) else { throw OnlineSourceError.http(http.statusCode) }
        return data
    }

    /// An error as a sentence to show. Public because the view layer
    /// and the smoke test both report these.
    public static func describe(_ error: Error) -> String {
        switch error {
        case let error as OnlineSourceError:
            switch error {
            case .blocked:
                return String(localized: "The site answered with a verification page.", bundle: .module)
            case let .http(code):
                return String(localized: "The site answered \(code).", bundle: .module)
            case let .network(message):
                return message
            case let .ruleIncomplete(field):
                return String(localized: "The rule has no \(field).", bundle: .module)
            case .invalidURL:
                return String(localized: "The rule builds an address that is not valid.", bundle: .module)
            case .unreadableResponse:
                return String(localized: "The site's answer could not be read.", bundle: .module)
            case .noResults:
                return String(localized: "Nothing found.", bundle: .module)
            case .requiresNewerClient:
                return String(localized: "This rule needs a newer version of AnimeGod.", bundle: .module)
            }
        default:
            return error.localizedDescription
        }
    }
}
