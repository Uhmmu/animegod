import Foundation

/// One (query × source) unit of work and how it went.
public struct TorrentSearchPair: Hashable, Identifiable, Sendable {
    public enum Status: Hashable, Sendable {
        case queued
        case running
        case succeeded(count: Int)
        case empty
        case timedOut
        /// Never started because the whole search ran out of time.
        case skipped
        case cancelled
        case failed(TorrentSearchError)

        public var isRetryable: Bool {
            switch self {
            case .timedOut, .skipped, .cancelled, .failed: true
            case .queued, .running, .succeeded, .empty: false
            }
        }

        public var isActive: Bool { self == .queued || self == .running }
    }

    public let query: String
    public let source: TorrentSourceID
    public var status: Status
    public var elapsed: TimeInterval

    public var id: String { "\(source.rawValue)|\(query)" }
}

public struct TorrentSearchSnapshot: Sendable {
    public let queries: [String]
    public let sources: [TorrentSourceID]
    public internal(set) var pairs: [TorrentSearchPair]
    public internal(set) var results: [TorrentSearchResult] = []
    public internal(set) var isFinished = false
    /// The overall deadline cut the search short.
    public internal(set) var hitDeadline = false
    var observations: [TorrentObservation] = []

    public var canRetry: Bool { isFinished && pairs.contains { $0.status.isRetryable } }

    /// The snapshot as it stands once its consumer stopped listening: a
    /// cancelled stream delivers no final snapshot of its own.
    public func cancelled() -> TorrentSearchSnapshot {
        var copy = self
        for index in copy.pairs.indices where copy.pairs[index].status.isActive {
            copy.pairs[index].status = .cancelled
        }
        copy.isFinished = true
        return copy
    }

    public var completedPairs: Int { pairs.filter { !$0.status.isActive }.count }
}

/// Runs every query against every selected index concurrently and streams
/// merged results as each pair finishes.
///
/// Ported from magnet-crawler's task manager: a bounded worker pool with a
/// per-source cap (so a batch of aliases doesn't hammer one site), a timeout
/// per pair, an overall deadline (shorter for a single query), per-pair
/// diagnostics, and retrying only what failed while keeping what succeeded.
/// One source failing never affects the others.
public struct TorrentSearchCoordinator: Sendable {
    public var providers: [TorrentSourceID: any TorrentSearchProvider]
    public var maximumConcurrentPairs = 16
    public var maximumConcurrentPairsPerSource = 2
    public var pairTimeout: Duration = .seconds(30)
    public var singleQueryDeadline: Duration = .seconds(45)
    public var batchDeadline: Duration = .seconds(120)
    public var limitPerPair = 80

    public static let maximumQueries = 20

    public init(providers: [TorrentSourceID: any TorrentSearchProvider] = TorrentProviders.all()) {
        self.providers = providers
    }

    /// Splits "title A, title B，title C" into distinct queries, keeping the
    /// first spelling of case-insensitive duplicates.
    public static func splitQueries(_ raw: String) -> [String] {
        var seen: Set<String> = []
        var queries: [String] = []
        for part in raw.split(whereSeparator: { $0 == "," || $0 == "，" || $0.isNewline }) {
            let query = String(part.trimmingCharacters(in: .whitespaces).prefix(200))
            guard !query.isEmpty, seen.insert(query.lowercased()).inserted else { continue }
            queries.append(query)
            if queries.count == maximumQueries { break }
        }
        return queries
    }

    public func search(queries: [String], sources: [TorrentSourceID]) -> AsyncStream<TorrentSearchSnapshot> {
        let sources = TorrentSourceID.allCases.filter { sources.contains($0) && providers[$0] != nil }
        let pairs = queries.flatMap { query in
            sources.map { TorrentSearchPair(query: query, source: $0, status: .queued, elapsed: 0) }
        }
        return run(TorrentSearchSnapshot(queries: queries, sources: sources, pairs: pairs))
    }

    /// Re-runs only the pairs that failed, timed out, or never started.
    public func retry(_ previous: TorrentSearchSnapshot) -> AsyncStream<TorrentSearchSnapshot> {
        var snapshot = previous
        snapshot.isFinished = false
        snapshot.hitDeadline = false
        for index in snapshot.pairs.indices where snapshot.pairs[index].status.isRetryable {
            snapshot.pairs[index].status = .queued
            snapshot.pairs[index].elapsed = 0
        }
        return run(snapshot)
    }

    private enum PairOutcome: Sendable {
        case success([TorrentObservation])
        case failure(TorrentSearchError)
        case timedOut
        case cancelled
    }

    private enum Event: Sendable {
        case finished(index: Int, outcome: PairOutcome, elapsed: TimeInterval)
        case deadline
    }

    private func run(_ initial: TorrentSearchSnapshot) -> AsyncStream<TorrentSearchSnapshot> {
        AsyncStream { continuation in
            let task = Task {
                let final = await execute(initial) { continuation.yield($0) }
                continuation.yield(final)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func execute(
        _ initial: TorrentSearchSnapshot,
        emit: @Sendable (TorrentSearchSnapshot) -> Void
    ) async -> TorrentSearchSnapshot {
        var snapshot = initial
        let deadline = snapshot.queries.count > 1 ? batchDeadline : singleQueryDeadline
        emit(snapshot)

        await withTaskGroup(of: Event.self) { group in
            group.addTask {
                try? await Task.sleep(for: deadline)
                return .deadline
            }
            var runningPerSource: [TorrentSourceID: Int] = [:]
            var runningCount = 0

            func launchQueued() {
                for index in snapshot.pairs.indices where snapshot.pairs[index].status == .queued {
                    guard runningCount < maximumConcurrentPairs else { return }
                    let pair = snapshot.pairs[index]
                    guard runningPerSource[pair.source, default: 0] < maximumConcurrentPairsPerSource,
                          let provider = providers[pair.source] else { continue }
                    snapshot.pairs[index].status = .running
                    runningPerSource[pair.source, default: 0] += 1
                    runningCount += 1
                    let limit = limitPerPair, timeout = pairTimeout
                    group.addTask {
                        let clock = ContinuousClock()
                        let began = clock.now
                        let outcome = await Self.runPair(provider: provider, query: pair.query, limit: limit, timeout: timeout)
                        let elapsed = began.duration(to: clock.now)
                        return .finished(index: index, outcome: outcome, elapsed: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
                    }
                }
            }

            launchQueued()
            emit(snapshot)

            while snapshot.pairs.contains(where: { $0.status.isActive }), let event = await group.next() {
                switch event {
                case .deadline:
                    if Task.isCancelled { break }
                    snapshot.hitDeadline = true
                    for index in snapshot.pairs.indices {
                        switch snapshot.pairs[index].status {
                        case .running: snapshot.pairs[index].status = .timedOut
                        case .queued: snapshot.pairs[index].status = .skipped
                        default: break
                        }
                    }
                case .finished(let index, let outcome, let elapsed):
                    let source = snapshot.pairs[index].source
                    runningPerSource[source, default: 1] -= 1
                    runningCount -= 1
                    guard snapshot.pairs[index].status == .running else { continue }
                    snapshot.pairs[index].elapsed = elapsed
                    switch outcome {
                    case .success(let found):
                        let query = snapshot.pairs[index].query
                        snapshot.pairs[index].status = found.isEmpty ? .empty : .succeeded(count: found.count)
                        snapshot.observations += found.map { observation in
                            var tagged = observation
                            tagged.query = query
                            return tagged
                        }
                        snapshot.results = TorrentResultMerger.merge(snapshot.observations, queries: snapshot.queries)
                    case .failure(let error):
                        snapshot.pairs[index].status = .failed(error)
                    case .timedOut:
                        snapshot.pairs[index].status = .timedOut
                    case .cancelled:
                        snapshot.pairs[index].status = .cancelled
                    }
                    launchQueued()
                }
                if Task.isCancelled {
                    for index in snapshot.pairs.indices where snapshot.pairs[index].status.isActive {
                        snapshot.pairs[index].status = .cancelled
                    }
                }
                emit(snapshot)
            }
            group.cancelAll()
        }

        if Task.isCancelled {
            for index in snapshot.pairs.indices where snapshot.pairs[index].status.isActive {
                snapshot.pairs[index].status = .cancelled
            }
        }
        snapshot.isFinished = true
        return snapshot
    }

    private static func runPair(
        provider: any TorrentSearchProvider,
        query: String,
        limit: Int,
        timeout: Duration
    ) async -> PairOutcome {
        await withTaskGroup(of: PairOutcome?.self) { group in
            group.addTask {
                do {
                    return .success(try await provider.search(query: query, limit: limit))
                } catch is CancellationError {
                    return Task.isCancelled ? nil : .failure(.network("request cancelled"))
                } catch let error as TorrentSearchError {
                    return .failure(error)
                } catch {
                    return .failure(.parse(String(describing: error)))
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return Task.isCancelled ? nil : .timedOut
            }
            for await outcome in group {
                if let outcome {
                    group.cancelAll()
                    return outcome
                }
            }
            return .cancelled
        }
    }
}
