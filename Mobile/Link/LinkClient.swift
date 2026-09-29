import AnimeGodCore
import Foundation

/// The phone's half of the link.
///
/// Every transport in the ladder produces the same thing — a base URL that
/// reaches the Mac — so this knows nothing about how the address was found.
/// That is what makes adding a transport a discovery strategy rather than a
/// subsystem.
actor LinkClient {
    private var base: URL
    private var token: String

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration)
    }()

    init(host: String, token: String) {
        self.base = URL(string: "http://\(host)") ?? URL(string: "http://127.0.0.1")!
        self.token = token
    }

    func update(host: String) {
        if let url = URL(string: "http://\(host)") { base = url }
    }

    var mediaBaseURL: URL { base }
    var bearer: String { token }

    // MARK: - Routes

    func health() async throws -> LinkHealth {
        try await get(LinkProtocol.Route.health, authenticated: false)
    }

    func library() async throws -> LinkLibrary {
        try await get(LinkProtocol.Route.library)
    }

    func continueWatching() async throws -> [LinkEpisode] {
        try await get(LinkProtocol.Route.continueWatching)
    }

    func detail(animeID: UUID) async throws -> LinkAnimeDetail {
        try await get(LinkProtocol.Route.animePrefix + animeID.uuidString)
    }

    // MARK: - The More tab

    func diary() async throws -> LinkDiary { try await get(LinkProtocol.Route.diary) }
    func rankings() async throws -> [LinkRankedWork] { try await get(LinkProtocol.Route.rankings) }
    func downloads() async throws -> [LinkDownload] { try await get(LinkProtocol.Route.downloads) }
    func subscriptions() async throws -> [LinkSubscription] { try await get(LinkProtocol.Route.subscriptions) }

    func statistics(year: Int?) async throws -> StatisticsReport {
        try await get(LinkProtocol.Route.statistics + (year.map { "?year=\($0)" } ?? ""))
    }

    func charts(channel: String, page: Int) async throws -> LinkCharts {
        try await get(LinkProtocol.Route.charts + "?channel=\(channel)&page=\(page)")
    }

    func downloadAction(infoHash: String, _ action: String) async throws {
        var request = authorized(LinkProtocol.Route.downloads + "/" + infoHash + "/" + action)
        request.httpMethod = "POST"
        _ = try await perform(request)
    }

    func setSubscriptionEnabled(id: UUID, _ isEnabled: Bool) async throws {
        var request = authorized(LinkProtocol.Route.subscriptions + "/" + id.uuidString)
        request.httpMethod = "POST"
        request.httpBody = try LinkCoding.encoder.encode(["isEnabled": isEnabled])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = try await perform(request)
    }

    func subtitles(mediaFileID: UUID) async throws -> LinkSubtitleList {
        try await get(LinkProtocol.Route.subtitlesPrefix + mediaFileID.uuidString)
    }

    func subtitleText(mediaFileID: UUID, id: UUID) async throws -> String {
        let data = try await raw(
            LinkProtocol.Route.subtitlesPrefix + mediaFileID.uuidString + "/" + id.uuidString
        )
        return String(data: data, encoding: .utf8) ?? ""
    }

    func danmaku(mediaFileID: UUID) async throws -> LinkDanmakuPool {
        try await get(LinkProtocol.Route.danmakuPrefix + mediaFileID.uuidString)
    }

    func poster(animeID: UUID) async throws -> Data {
        try await raw(LinkProtocol.Route.posterPrefix + animeID.uuidString)
    }

    func putProgress(episodeID: UUID, _ update: LinkProgressUpdate) async throws {
        var request = authorized(LinkProtocol.Route.progressPrefix + episodeID.uuidString)
        request.httpMethod = "PUT"
        request.httpBody = try LinkCoding.encoder.encode(update)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = try await perform(request)
    }

    /// Takes an episode from the Mac.
    ///
    /// Returns the conflict instead of throwing when another device holds it,
    /// because that is a question for the viewer, not an error.
    func claim(episodeID: UUID, deviceName: String, force: Bool) async throws -> Result<LinkHandoffState, LinkHandoffConflict> {
        var request = authorized(LinkProtocol.Route.handoffClaim)
        request.httpMethod = "POST"
        request.httpBody = try LinkCoding.encoder.encode(
            LinkHandoffClaim(episodeID: episodeID, deviceName: deviceName, force: force)
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 409,
           let conflict = try? LinkCoding.decoder.decode(LinkHandoffConflict.self, from: data) {
            return .failure(conflict)
        }
        try Self.check(response, data)
        return .success(try LinkCoding.decoder.decode(LinkHandoffState.self, from: data))
    }

    func release(_ release: LinkHandoffRelease) async throws {
        var request = authorized(LinkProtocol.Route.handoffRelease)
        request.httpMethod = "POST"
        request.httpBody = try LinkCoding.encoder.encode(release)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = try await perform(request)
    }

    func setWatched(episodeID: UUID, _ isWatched: Bool) async throws {
        var request = authorized(LinkProtocol.Route.episodesPrefix + episodeID.uuidString + "/watched")
        request.httpMethod = "POST"
        request.httpBody = try LinkCoding.encoder.encode(["isWatched": isWatched])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = try await perform(request)
    }

    /// Pairing is the one call made before there is a token.
    static func pair(host: String, code: String, deviceName: String) async throws -> LinkPairResponse {
        guard let url = URL(string: "http://\(host)")?.appending(path: "pair") else {
            throw LinkError(code: .badRequest, message: "That address is not valid.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try LinkCoding.encoder.encode(LinkPairRequest(code: code, deviceName: deviceName))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(response, data)
        return try LinkCoding.decoder.decode(LinkPairResponse.self, from: data)
    }

    /// `/health` with no token, used to test an address before pairing.
    static func probe(host: String) async throws -> LinkHealth {
        guard let url = URL(string: "http://\(host)")?.appending(path: "health") else {
            throw LinkError(code: .badRequest, message: "That address is not valid.")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(response, data)
        return try LinkCoding.decoder.decode(LinkHealth.self, from: data)
    }

    // MARK: - Plumbing

    private func authorized(_ path: String) -> URLRequest {
        var request = URLRequest(url: url(for: path))
        request.setValue("\(LinkProtocol.bearerPrefix)\(token)", forHTTPHeaderField: LinkProtocol.authorizationHeader)
        return request
    }

    private func get<T: Decodable>(_ path: String, authenticated: Bool = true) async throws -> T {
        let request = authenticated ? authorized(path) : URLRequest(url: url(for: path))
        let data = try await perform(request)
        return try LinkCoding.decoder.decode(T.self, from: data)
    }

    /// `appending(path:)` percent-encodes `?` and `&`, which turns a query
    /// string into part of the path. Anything carrying one is resolved against
    /// the base URL instead.
    private func url(for path: String) -> URL {
        if path.contains("?"), let resolved = URL(string: path, relativeTo: base) {
            return resolved
        }
        return base.appending(path: path)
    }

    private func raw(_ path: String) async throws -> Data {
        try await perform(authorized(path))
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        try Self.check(response, data)
        return data
    }

    /// A failure here is shown to someone, so it carries the Mac's own message
    /// where there is one rather than a bare status code.
    private static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard !(200..<300).contains(http.statusCode) else { return }
        if let error = try? LinkCoding.decoder.decode(LinkError.self, from: data) { throw error }
        throw LinkError(code: .unavailable, message: "The Mac answered \(http.statusCode).")
    }
}
