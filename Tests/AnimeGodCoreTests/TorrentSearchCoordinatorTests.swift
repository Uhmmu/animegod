import Foundation
import Testing
@testable import AnimeGodCore

private struct FakeProvider: TorrentSearchProvider {
    enum Behavior: Sendable {
        case results([String])
        case fail(TorrentSearchError)
        case hang
    }

    let id: TorrentSourceID
    let behavior: @Sendable (String) -> Behavior
    let delay: Duration
    let tracker: ConcurrencyTracker?

    init(_ id: TorrentSourceID, delay: Duration = .zero, tracker: ConcurrencyTracker? = nil, behavior: @escaping @Sendable (String) -> Behavior) {
        self.id = id
        self.delay = delay
        self.tracker = tracker
        self.behavior = behavior
    }

    func search(query: String, limit: Int) async throws -> [TorrentObservation] {
        tracker?.enter()
        defer { tracker?.leave() }
        if delay > .zero { try await Task.sleep(for: delay) }
        switch behavior(query) {
        case .results(let hashes):
            return hashes.map { TorrentObservation(source: id, title: "\(query) - 01", infoHash: TorrentInfoHash($0)!) }
        case .fail(let error):
            throw error
        case .hang:
            try await Task.sleep(for: .seconds(3600))
            return []
        }
    }
}

private final class ConcurrencyTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private var maximum = 0

    func enter() { lock.withLock { current += 1; maximum = max(maximum, current) } }
    func leave() { lock.withLock { current -= 1 } }
    var peak: Int { lock.withLock { maximum } }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int { lock.withLock { value += 1; return value } }
    var count: Int { lock.withLock { value } }
}

private let hashA = "6e54509de959fbe569c135b4f46b35789d53aaa6"
private let hashB = "938762a9ee0278dfcbd269badd8c064b5e18a90d"

private func finalSnapshot(_ stream: AsyncStream<TorrentSearchSnapshot>) async -> (TorrentSearchSnapshot?, Int) {
    var last: TorrentSearchSnapshot?
    var count = 0
    for await snapshot in stream {
        last = snapshot
        count += 1
    }
    return (last, count)
}

struct TorrentSearchCoordinatorTests {
    @Test func splitsAndDeduplicatesQueries() {
        #expect(TorrentSearchCoordinator.splitQueries("Ave Mujica, 颂乐人偶，ave mujica\n BanG Dream ") == ["Ave Mujica", "颂乐人偶", "BanG Dream"])
        #expect(TorrentSearchCoordinator.splitQueries(" , ，").isEmpty)
        let many = (1...30).map { "q\($0)" }.joined(separator: ",")
        #expect(TorrentSearchCoordinator.splitQueries(many).count == TorrentSearchCoordinator.maximumQueries)
    }

    @Test func oneFailingSourceLeavesOthersWorking() async throws {
        let coordinator = TorrentSearchCoordinator(providers: [
            .nyaa: FakeProvider(.nyaa) { _ in .results([hashA]) },
            .dmhy: FakeProvider(.dmhy) { _ in .results([hashA, hashB]) },
            .mikan: FakeProvider(.mikan) { _ in .fail(.blocked) },
            .subsPlease: FakeProvider(.subsPlease) { _ in .results([]) }
        ])
        let (final, count) = await finalSnapshot(coordinator.search(queries: ["Ave Mujica"], sources: [.nyaa, .dmhy, .mikan, .subsPlease]))
        let snapshot = try #require(final)
        #expect(count >= 3, "results stream in as pairs finish")
        #expect(snapshot.isFinished)
        #expect(!snapshot.hitDeadline)
        #expect(snapshot.results.count == 2)
        #expect(snapshot.results.first { $0.infoHash.hex == hashA }?.sources == [.dmhy, .nyaa])
        let statuses = Dictionary(uniqueKeysWithValues: snapshot.pairs.map { ($0.source, $0.status) })
        #expect(statuses[.nyaa] == .succeeded(count: 1))
        #expect(statuses[.dmhy] == .succeeded(count: 2))
        #expect(statuses[.mikan] == .failed(.blocked))
        #expect(statuses[.subsPlease] == .empty)
        #expect(snapshot.canRetry)
    }

    @Test func pairTimeoutAndOverallDeadlineStopSlowSources() async throws {
        var coordinator = TorrentSearchCoordinator(providers: [
            .nyaa: FakeProvider(.nyaa) { _ in .results([hashA]) },
            .dmhy: FakeProvider(.dmhy) { _ in .hang }
        ])
        coordinator.pairTimeout = .milliseconds(150)
        let (timedOut, _) = await finalSnapshot(coordinator.search(queries: ["x"], sources: [.nyaa, .dmhy]))
        #expect(timedOut?.pairs.first { $0.source == .dmhy }?.status == .timedOut)
        #expect(timedOut?.results.count == 1)
        #expect(timedOut?.hitDeadline == false)

        coordinator.pairTimeout = .seconds(60)
        coordinator.singleQueryDeadline = .milliseconds(150)
        let clock = ContinuousClock()
        let began = clock.now
        let (deadline, _) = await finalSnapshot(coordinator.search(queries: ["x"], sources: [.nyaa, .dmhy]))
        #expect(began.duration(to: clock.now) < .seconds(5))
        #expect(deadline?.hitDeadline == true)
        #expect(deadline?.pairs.first { $0.source == .dmhy }?.status == .timedOut)
        #expect(deadline?.pairs.first { $0.source == .nyaa }?.status == .succeeded(count: 1))
    }

    @Test func capsConcurrencyPerSource() async throws {
        let tracker = ConcurrencyTracker()
        var coordinator = TorrentSearchCoordinator(providers: [
            .nyaa: FakeProvider(.nyaa, delay: .milliseconds(40), tracker: tracker) { _ in .results([]) }
        ])
        coordinator.maximumConcurrentPairsPerSource = 2
        let queries = (1...8).map { "q\($0)" }
        let (final, _) = await finalSnapshot(coordinator.search(queries: queries, sources: [.nyaa]))
        #expect(final?.pairs.allSatisfy { $0.status == .empty } == true)
        #expect(tracker.peak == 2)
    }

    @Test func retryRerunsOnlyFailedPairsAndKeepsResults() async throws {
        let attempts = Counter()
        let coordinator = TorrentSearchCoordinator(providers: [
            .nyaa: FakeProvider(.nyaa) { _ in .results([hashA]) },
            .dmhy: FakeProvider(.dmhy) { _ in
                return attempts.increment() == 1 ? .fail(.http(502)) : .results([hashB])
            }
        ])
        let (first, _) = await finalSnapshot(coordinator.search(queries: ["x"], sources: [.nyaa, .dmhy]))
        let failed = try #require(first)
        #expect(failed.results.count == 1)

        let (second, _) = await finalSnapshot(coordinator.retry(failed))
        let retried = try #require(second)
        #expect(retried.results.count == 2)
        #expect(retried.pairs.allSatisfy { !$0.status.isRetryable })
        #expect(attempts.count == 2)
        #expect(!retried.canRetry)
    }

    @Test func cancellingTheConsumerCancelsTheSearch() async throws {
        let coordinator = TorrentSearchCoordinator(providers: [
            .dmhy: FakeProvider(.dmhy) { _ in .hang }
        ])
        let clock = ContinuousClock()
        let began = clock.now
        let task = Task {
            var last: TorrentSearchSnapshot?
            for await snapshot in coordinator.search(queries: ["x"], sources: [.dmhy]) { last = snapshot }
            return last
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        _ = await task.value
        #expect(began.duration(to: clock.now) < .seconds(5))
    }
}
