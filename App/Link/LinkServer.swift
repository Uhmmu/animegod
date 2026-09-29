import AnimeGodCore
import AppKit
import Foundation
import Network

/// The Mac half of the link: an HTTP server the phone talks to.
///
/// Design: `docs/IOS_COMPANION_PLAN.md`. Written directly on `NWListener`
/// rather than pulled in as a dependency — the surface is a dozen routes, and
/// the one interesting part (byte ranges for the media stream) is exactly what
/// a general-purpose server would bury.
///
/// Access control is a bearer token on **every** request, `/health` excepted
/// and deliberately empty. The listener binds to every interface so the phone
/// can reach it, so "the request arrived" says nothing about who sent it —
/// including from localhost.
@MainActor
final class LinkServer: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?
    @Published private(set) var pairedDevices: [LinkPairedDevice] = []
    /// Non-nil while a pairing code is live and typeable.
    @Published private(set) var pairingCode: String?
    @Published private(set) var pairingExpiresAt: Date?
    /// Addresses this Mac can currently be reached on, for the Settings panel.
    @Published private(set) var endpoints: [String] = []
    @Published private(set) var lastSeenDeviceName: String?

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: LinkConnection] = [:]
    private var pairingAttempts = 0
    /// Who is playing what, so two devices cannot both drive one episode.
    /// The rules and the lease live in the core, where they are tested.
    private var claims = LinkClaimRegistry()
    private weak var model: AppModel?
    private var activity: NSObjectProtocol?

    private static let credentialService = "com.uhmmu.AnimeGod.link"
    private static let devicesAccount = "pairedDevices"

    var port: UInt16 = LinkProtocol.defaultPort

    init() {
        pairedDevices = Self.loadDevices()
    }

    func attach(model: AppModel) {
        self.model = model
    }

    // MARK: - Lifecycle

    func start() {
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            // Also advertise over peer-to-peer Wi-Fi, so a phone can find
            // this Mac with no router between them at all. AWDL shares the
            // radio with the infrastructure connection, so this costs
            // something when it is actually used — but advertising alone is
            // cheap, and it is the only route that survives a network which
            // isolates every client from every other.
            parameters.includePeerToPeer = true
            // The phone finds the Mac by name on the LAN; every other
            // transport in the ladder needs no advertisement.
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
            listener.service = NWListener.Service(name: Host.current().localizedName ?? "AnimeGod", type: LinkProtocol.bonjourType)
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.listenerDidChange(state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.start(queue: .global(qos: .userInitiated))
            self.listener = listener
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.close() }
        connections.removeAll()
        isRunning = false
        endpoints = []
        releaseActivity()
    }

    private func listenerDidChange(_ state: NWListener.State) {
        switch state {
        case .ready:
            isRunning = true
            lastError = nil
            endpoints = Self.localAddresses(port: port)
        case .failed(let error):
            isRunning = false
            lastError = error.localizedDescription
            listener?.cancel()
            listener = nil
        case .cancelled:
            isRunning = false
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        let wrapper = LinkConnection(connection: connection) { [weak self] request in
            guard let self else {
                return .response(.error(.unavailable, "Server stopped.", status: 503))
            }
            return await self.route(request)
        } onClose: { [weak self] id in
            Task { @MainActor in self?.connections.removeValue(forKey: id) }
        }
        connections[ObjectIdentifier(wrapper)] = wrapper
        wrapper.start()
    }

    // MARK: - Sleep

    /// mpv on the phone is pulling bytes off this machine; nothing else tells
    /// macOS that. Held only while a stream is actually running, the way
    /// `PlaybackActivity` holds it only while playback runs.
    func beginStreaming() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .suddenTerminationDisabled],
            reason: "Streaming to a paired device"
        )
    }

    func releaseActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    // MARK: - Pairing

    func beginPairing() {
        pairingCode = LinkAuth.makePairingCode()
        pairingExpiresAt = Date.now.addingTimeInterval(LinkAuth.pairingLifetime)
        pairingAttempts = 0
    }

    func cancelPairing() {
        pairingCode = nil
        pairingExpiresAt = nil
        pairingAttempts = 0
    }

    func revoke(_ device: LinkPairedDevice) {
        pairedDevices.removeAll { $0.id == device.id }
        Self.saveDevices(pairedDevices)
    }

    private var isPairingOpen: Bool {
        guard pairingCode != nil, let expiry = pairingExpiresAt else { return false }
        return expiry > .now
    }

    private func device(forToken token: String) -> LinkPairedDevice? {
        pairedDevices.first { LinkAuth.constantTimeEquals($0.token, token) }
    }

    private static func loadDevices() -> [LinkPairedDevice] {
        guard let raw = CredentialStore.load(account: devicesAccount, service: credentialService),
              let data = raw.data(using: .utf8),
              let devices = try? JSONDecoder().decode([LinkPairedDevice].self, from: data)
        else { return [] }
        return devices
    }

    private static func saveDevices(_ devices: [LinkPairedDevice]) {
        let data = (try? JSONEncoder().encode(devices)) ?? Data()
        CredentialStore.save(String(data: data, encoding: .utf8) ?? "", account: devicesAccount, service: credentialService)
    }

    // MARK: - Routing

    func route(_ request: LinkHTTPRequest) async -> LinkRouteResult {
        // `/health` is the only unauthenticated route, and it exists so the
        // resolver can race endpoints — so it must leak nothing beyond "an
        // AnimeGod is here and this is its protocol version".
        if request.path == LinkProtocol.Route.health {
            let health = LinkHealth(
                name: Host.current().localizedName ?? "Mac",
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0",
                isPairing: isPairingOpen
            )
            return .response(.json(health))
        }

        if request.path == LinkProtocol.Route.pair, request.method == "POST" {
            return .response(handlePair(request))
        }

        guard let token = LinkAuth.bearerToken(from: request.header(LinkProtocol.authorizationHeader)),
              var device = device(forToken: token)
        else {
            return .response(.error(.unauthorized, "Pair this device with AnimeGod on the Mac.", status: 401))
        }
        device.lastSeenAt = .now
        if let index = pairedDevices.firstIndex(where: { $0.id == device.id }) {
            pairedDevices[index] = device
        }
        lastSeenDeviceName = device.name

        guard let model else {
            return .response(.error(.unavailable, "The library is not open.", status: 503))
        }

        switch request.path {
        case LinkProtocol.Route.library:
            return .response(.json(await LinkPayloads.library(model: model)))
        case LinkProtocol.Route.continueWatching:
            return .response(.json(await LinkPayloads.continueWatching(model: model)))
        case LinkProtocol.Route.diary:
            return .response(.json(await LinkMorePayloads.diary(model: model)))
        case LinkProtocol.Route.rankings:
            return .response(.json(await LinkMorePayloads.rankings(model: model)))
        case LinkProtocol.Route.downloads where request.method == "GET":
            return .response(.json(await LinkMorePayloads.downloads(model: model)))
        case LinkProtocol.Route.subscriptions where request.method == "GET":
            return .response(.json(await LinkMorePayloads.subscriptions(model: model)))
        case LinkProtocol.Route.statistics:
            let year = request.query["year"].flatMap(Int.init)
            guard let report = await LinkMorePayloads.statistics(model: model, year: year) else {
                return .response(.error(.unavailable, "Statistics are not ready.", status: 503))
            }
            return .response(.json(report))
        case LinkProtocol.Route.charts:
            return .response(await handleCharts(request, model: model))
        default:
            break
        }

        // Remote control: pause, resume, enable. Deliberately the only writes
        // the phone may make to the engine — it has no torrent engine of its
        // own and no business holding a rule.
        if let hash = request.identifier(after: LinkProtocol.Route.downloads + "/"), request.method == "POST" {
            return .response(await handleDownloadAction(infoHash: hash, path: request.path, model: model))
        }
        if let id = request.identifier(after: LinkProtocol.Route.subscriptions + "/"),
           let uuid = UUID(uuidString: id), request.method == "POST" {
            let enabled = (try? LinkCoding.decoder.decode([String: Bool].self, from: request.body))?["isEnabled"] ?? true
            guard let rule = model.subscriptions.subscriptions.first(where: { $0.id == uuid }) else {
                return .response(.error(.notFound, "No such subscription.", status: 404))
            }
            await model.subscriptions.setEnabled(enabled, for: rule)
            return .response(LinkHTTPResponse(status: 204))
        }

        if let id = request.identifier(after: LinkProtocol.Route.animePrefix), let uuid = UUID(uuidString: id) {
            guard let detail = await LinkPayloads.detail(animeID: uuid, model: model) else {
                return .response(.error(.notFound, "No such work.", status: 404))
            }
            return .response(.json(detail))
        }

        if request.path == LinkProtocol.Route.handoffClaim, request.method == "POST" {
            return .response(await handleClaim(request, device: device, model: model))
        }

        if request.path == LinkProtocol.Route.handoffRelease, request.method == "POST" {
            return .response(await handleRelease(request, device: device, model: model))
        }

        if let id = request.identifier(after: LinkProtocol.Route.progressPrefix),
           let uuid = UUID(uuidString: id), request.method == "PUT" {
            // Writing progress is the holder saying it is still there, so the
            // lease renews itself and needs no heartbeat of its own.
            renewClaim(episodeID: uuid, device: device)
            return .response(await handleProgress(episodeID: uuid, body: request.body, model: model))
        }

        if let id = request.identifier(after: LinkProtocol.Route.episodesPrefix),
           let uuid = UUID(uuidString: id), request.path.hasSuffix("/watched"), request.method == "POST" {
            let watched = (try? LinkCoding.decoder.decode([String: Bool].self, from: request.body))?["isWatched"] ?? true
            await model.setWatched(watched, forEpisodeID: uuid)
            return .response(LinkHTTPResponse(status: 204))
        }

        if let id = request.identifier(after: LinkProtocol.Route.mediaPrefix), let uuid = UUID(uuidString: id) {
            return await handleMedia(mediaFileID: uuid, range: request.rangeHeader, model: model)
        }

        if let id = request.identifier(after: LinkProtocol.Route.posterPrefix), let uuid = UUID(uuidString: id) {
            return await handlePoster(animeID: uuid, model: model)
        }

        if request.path.hasPrefix(LinkProtocol.Route.subtitlesPrefix),
           let id = request.identifier(after: LinkProtocol.Route.subtitlesPrefix),
           let uuid = UUID(uuidString: id) {
            return await handleSubtitles(mediaFileID: uuid, path: request.path, model: model)
        }

        if let id = request.identifier(after: LinkProtocol.Route.danmakuPrefix), let uuid = UUID(uuidString: id) {
            guard let pool = await LinkDanmaku.pool(mediaFileID: uuid, model: model) else {
                return .response(.error(.notFound, "No danmaku for that file.", status: 404))
            }
            return .response(.json(pool))
        }

        return .response(.error(.notFound, "No such route.", status: 404))
    }

    private func handlePair(_ request: LinkHTTPRequest) -> LinkHTTPResponse {
        guard isPairingOpen, let code = pairingCode else {
            return .error(.pairingClosed, "Open pairing in AnimeGod on the Mac first.", status: 403)
        }
        guard let body = try? LinkCoding.decoder.decode(LinkPairRequest.self, from: request.body) else {
            return .error(.badRequest, "Malformed pairing request.", status: 400)
        }
        guard LinkAuth.constantTimeEquals(body.code, code) else {
            pairingAttempts += 1
            // Five guesses at a six-digit code is the whole budget; after that
            // the code is burned rather than left to be ground down.
            if pairingAttempts >= LinkAuth.pairingAttemptLimit { cancelPairing() }
            return .error(.pairingRejected, "That code does not match.", status: 403)
        }
        let device = LinkPairedDevice(name: body.deviceName, token: LinkAuth.makeToken())
        pairedDevices.append(device)
        Self.saveDevices(pairedDevices)
        cancelPairing()
        return .json(LinkPairResponse(token: device.token, macName: Host.current().localizedName ?? "Mac"))
    }

    /// The list for a video, or one subtitle's text.
    ///
    /// `/subtitles/{mediaFileID}` lists; `/subtitles/{mediaFileID}/{id}` sends
    /// the file. Served as text rather than a download so the phone can write
    /// it straight into its container and hand mpv a path.
    private func handleSubtitles(mediaFileID: UUID, path: String, model: AppModel) async -> LinkRouteResult {
        guard let database = model.libraryDatabase,
              let file = try? await database.mediaFile(id: mediaFileID)
        else { return .response(.error(.notFound, "No such file.", status: 404)) }

        let key = SubtitleCacheStore.videoKey(
            mediaFileID: mediaFileID,
            fileName: (file.relativePath as NSString).lastPathComponent
        )
        let records = (try? await database.subtitleDownloads(videoKey: key)) ?? []

        // A trailing component means "give me this one".
        let tail = path
            .dropFirst(LinkProtocol.Route.subtitlesPrefix.count)
            .split(separator: "/")
            .dropFirst()
            .first
            .map(String.init)
        guard let tail else {
            return .response(.json(LinkSubtitleList(mediaFileID: mediaFileID, subtitles: records)))
        }
        guard let wanted = UUID(uuidString: tail),
              let record = records.first(where: { $0.id == wanted }),
              let text = try? String(contentsOf: model.subtitlePreferences.cache.url(for: record), encoding: .utf8)
        else { return .response(.error(.notFound, "No such subtitle.", status: 404)) }

        return .response(LinkHTTPResponse(
            status: 200,
            headers: ["Content-Type": "text/plain; charset=utf-8"],
            body: Data(text.utf8)
        ))
    }

    // MARK: - The More tab

    private func handleCharts(_ request: LinkHTTPRequest, model: AppModel) async -> LinkHTTPResponse {
        let channel = BangumiChartChannel(rawValue: request.query["channel"] ?? "anime") ?? .anime
        let page = request.query["page"].flatMap(Int.init) ?? 1
        do {
            let result = try await BangumiChartsProvider().chart(channel: channel, page: page)
            return .json(LinkCharts(
                channel: channel.rawValue,
                page: result.page,
                totalPages: result.totalPages,
                entries: result.entries
            ))
        } catch {
            // Charts are the one screen that depends on a third party being
            // up; the phone is told so rather than shown an empty list.
            return .error(.unavailable, error.localizedDescription, status: 503)
        }
    }

    private func handleDownloadAction(infoHash: String, path: String, model: AppModel) async -> LinkHTTPResponse {
        guard let item = model.downloads.items.first(where: { $0.record.infoHash == infoHash.lowercased() }) else {
            return .error(.notFound, "No such download.", status: 404)
        }
        if path.hasSuffix("/pause") {
            model.downloads.pause(item)
        } else if path.hasSuffix("/resume") {
            model.downloads.resume(item)
        } else {
            return .error(.badRequest, "Unknown download action.", status: 400)
        }
        return LinkHTTPResponse(status: 204)
    }

    // MARK: - Handoff

    private func handleClaim(_ request: LinkHTTPRequest, device: LinkPairedDevice, model: AppModel) async -> LinkHTTPResponse {
        guard let claim = try? LinkCoding.decoder.decode(LinkHandoffClaim.self, from: request.body) else {
            return .error(.badRequest, "Malformed handoff request.", status: 400)
        }
        switch claims.claim(
            episodeID: claim.episodeID,
            deviceID: device.id,
            deviceName: claim.deviceName,
            force: claim.force
        ) {
        case .heldBy(let holder):
            return .json(LinkHandoffConflict(holder: holder), status: 409)
        case .granted:
            break
        }
        guard let state = await model.handOff(episodeID: claim.episodeID) else {
            _ = claims.release(episodeID: claim.episodeID, deviceID: device.id)
            return .error(.notFound, "No such episode.", status: 404)
        }
        return .json(state)
    }

    private func handleRelease(_ request: LinkHTTPRequest, device: LinkPairedDevice, model: AppModel) async -> LinkHTTPResponse {
        guard let release = try? LinkCoding.decoder.decode(LinkHandoffRelease.self, from: request.body) else {
            return .error(.badRequest, "Malformed handoff request.", status: 400)
        }
        // Only the holder may release, or a stale phone coming back could
        // reopen the player under whoever is watching now.
        guard claims.release(episodeID: release.episodeID, deviceID: device.id) else {
            return .error(.claimHeldElsewhere, "Another device is playing this episode.", status: 409)
        }
        await model.acceptHandoffBack(release)
        return LinkHTTPResponse(status: 204)
    }

    private func renewClaim(episodeID: UUID, device: LinkPairedDevice) {
        claims.renew(episodeID: episodeID, deviceID: device.id)
    }

    private func handleProgress(episodeID: UUID, body: Data, model: AppModel) async -> LinkHTTPResponse {
        guard let update = try? LinkCoding.decoder.decode(LinkProgressUpdate.self, from: body) else {
            return .error(.badRequest, "Malformed progress update.", status: 400)
        }
        // Goes through the same call the Mac player uses, so the `MAX(old,
        // new)` rule and the tail rule apply identically to a phone write.
        await model.saveProgress(
            forEpisodeID: episodeID,
            position: update.position,
            duration: update.duration,
            isWatched: update.isWatched,
            overridesWatched: update.overridesWatched
        )
        return LinkHTTPResponse(status: 204)
    }

    private func handleMedia(mediaFileID: UUID, range: LinkByteRange?, model: AppModel) async -> LinkRouteResult {
        guard let located = await model.locateMedia(mediaFileID: mediaFileID) else {
            return .response(.error(.notFound, "That episode is not in an available library folder.", status: 404))
        }
        beginStreaming()
        return .file(LinkFileBody(
            url: located.url,
            access: located.access,
            size: located.size,
            contentType: Self.contentType(for: located.url),
            range: range
        ))
    }

    /// Posters are proxied rather than linked: the phone never talks to
    /// Bangumi's or AniList's CDN, which is one less thing to be slow or
    /// blocked, and it reuses artwork this Mac has already fetched.
    private func handlePoster(animeID: UUID, model: AppModel) async -> LinkRouteResult {
        guard let url = model.posterCandidates(for: animeID).first else {
            return .response(.error(.notFound, "No poster for this work.", status: 404))
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            let type = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? "image/jpeg"
            return .response(LinkHTTPResponse(
                status: 200,
                headers: ["Content-Type": type, "Cache-Control": "max-age=604800"],
                body: data
            ))
        } catch {
            return .response(.error(.unavailable, "Could not fetch the poster.", status: 503))
        }
    }

    private static func contentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mkv": "video/x-matroska"
        case "mp4", "m4v": "video/mp4"
        case "avi": "video/x-msvideo"
        case "mov": "video/quicktime"
        case "ts": "video/mp2t"
        case "webm": "video/webm"
        case "iso": "application/octet-stream"
        default: "application/octet-stream"
        }
    }

    /// Every IPv4 address this Mac holds, so Settings can show what to type
    /// on the phone when Bonjour is filtered.
    private static func localAddresses(port: UInt16) -> [String] {
        var results: [String] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            guard let addr = current.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: current.pointee.ifa_name)
            guard name != "lo0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            let text = String(cString: host)
            guard !text.isEmpty else { continue }
            results.append("\(text):\(port)")
        }
        return results
    }
}

/// What a route produced: either a complete response, or a file to stream.
enum LinkRouteResult: Sendable {
    case response(LinkHTTPResponse)
    case file(LinkFileBody)
}

/// A media file to send, with the security scope that lets it be opened.
///
/// The scope is carried rather than re-derived: a download's save path cannot
/// be rebuilt from a stored path string, and the same is true of a library
/// file — writing or reading through the bare path lands in the container.
struct LinkFileBody: @unchecked Sendable {
    let url: URL
    let access: ScopedLibraryAccess?
    let size: Int64
    let contentType: String
    let range: LinkByteRange?
}
