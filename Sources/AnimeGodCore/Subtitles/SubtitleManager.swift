import Foundation

/// How one provider fared in a search.
public enum SubtitleProviderOutcome: Hashable, Sendable {
    case succeeded(count: Int)
    case skipped(reason: String)
    case failed(message: String)
}

public struct SubtitleSearchReport: Sendable {
    /// Every result, best first.
    public var ranked: [ScoredSubtitle]
    public var outcomes: [SubtitleProviderID: SubtitleProviderOutcome]
    /// The result confident enough to load without asking, if any.
    public var automaticChoice: ScoredSubtitle?

    public init(ranked: [ScoredSubtitle], outcomes: [SubtitleProviderID: SubtitleProviderOutcome], automaticChoice: ScoredSubtitle?) {
        self.ranked = ranked
        self.outcomes = outcomes
        self.automaticChoice = automaticChoice
    }
}

/// Runs every provider in parallel, merges and deduplicates their results,
/// and ranks them with one scorer. One provider failing — bad key, rate
/// limit, outage — only marks that provider's outcome; the others' results
/// are unaffected.
public struct SubtitleManager: Sendable {
    public var providers: [any SubtitleProvider]
    public var scorer: SubtitleMatchScorer
    public var providerTimeout: Duration

    public init(
        providers: [any SubtitleProvider],
        preferences: SubtitleRankingPreferences = .default,
        providerTimeout: Duration = .seconds(25)
    ) {
        self.providers = providers
        self.scorer = SubtitleMatchScorer(preferences: preferences)
        self.providerTimeout = providerTimeout
    }

    public func search(_ query: SubtitleQuery) async -> SubtitleSearchReport {
        let wanted = Set(query.languages)
        var outcomes: [SubtitleProviderID: SubtitleProviderOutcome] = [:]
        var active: [any SubtitleProvider] = []
        for provider in providers {
            // A provider that cannot serve any wanted language is not asked
            // (Jimaku holds Japanese only), which saves its quota.
            if !wanted.isEmpty, provider.id.servedLanguages.isDisjoint(with: wanted) {
                outcomes[provider.id] = .skipped(reason: String(localized: "No subtitles in the preferred languages", bundle: .module))
            } else {
                active.append(provider)
            }
        }

        let timeout = providerTimeout
        let collected = await withTaskGroup(of: (SubtitleProviderID, Result<[SubtitleResult], Error>).self) { group in
            for provider in active {
                group.addTask {
                    do {
                        let results = try await Self.withTimeout(timeout) { try await provider.search(query) }
                        return (provider.id, .success(results))
                    } catch {
                        return (provider.id, .failure(error))
                    }
                }
            }
            var all: [(SubtitleProviderID, Result<[SubtitleResult], Error>)] = []
            for await item in group { all.append(item) }
            return all
        }

        var results: [SubtitleResult] = []
        for (providerID, outcome) in collected {
            switch outcome {
            case let .success(found):
                outcomes[providerID] = .succeeded(count: found.count)
                results += found
            case let .failure(error):
                outcomes[providerID] = .failed(message: Self.message(for: error))
            }
        }
        let ranked = deduplicated(scorer.rank(results, for: query.identity))
        return SubtitleSearchReport(ranked: ranked, outcomes: outcomes, automaticChoice: scorer.automaticChoice(from: ranked))
    }

    /// Downloads, unpacks, decodes and validates one result, returning the
    /// subtitle for this episode ready to cache.
    public func download(_ result: SubtitleResult, for video: SubtitleVideoIdentity) async throws -> PreparedSubtitle {
        guard let provider = providers.first(where: { $0.id == result.provider }) else {
            throw SubtitleProviderError.notConfigured
        }
        let files = try await Self.withTimeout(.seconds(60)) { try await provider.download(result, for: video) }
        return try SubtitleFileSelector(preferences: scorer.preferences)
            .prepare(files, for: video, claimedLanguages: result.languages)
    }

    /// Keeps the best-scored copy of results that are the same subtitle:
    /// the same provider item, or the same file offered by two providers.
    func deduplicated(_ ranked: [ScoredSubtitle]) -> [ScoredSubtitle] {
        var seenIDs: Set<String> = []
        // Content key → the provider that first offered it. Two uploads with
        // the same name on one provider are distinct; the same name on two
        // providers is almost always one mirrored file.
        var seenContent: [String: SubtitleProviderID] = [:]
        return ranked.filter { scored in
            let result = scored.result
            guard seenIDs.insert(result.id).inserted else { return false }
            guard let name = result.fileName ?? result.releaseName else { return true }
            let key = [
                SubtitleReleaseParsing.tokens(name).sorted().joined(separator: " "),
                result.languages.map(\.rawValue).sorted().joined(separator: ","),
                result.format?.rawValue ?? "?"
            ].joined(separator: "|")
            if let owner = seenContent[key] { return owner == result.provider }
            seenContent[key] = result.provider
            return true
        }
    }

    /// A short, user-facing explanation of a provider or network error.
    public static func message(for error: Error) -> String {
        if let error = error as? SubtitleProviderError { return error.localizedDescription }
        if error is CancellationError { return String(localized: "Timed out.", bundle: .module) }
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost: return String(localized: "No network connection.", bundle: .module)
            case .timedOut: return String(localized: "Timed out.", bundle: .module)
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return String(localized: "The service is unreachable from this network.", bundle: .module)
            default: return error.localizedDescription
            }
        }
        return error.localizedDescription
    }

    static func withTimeout<Value: Sendable>(_ timeout: Duration, _ operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw CancellationError()
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else { throw CancellationError() }
            return value
        }
    }
}
