import AnimeGodCore
import Foundation
import Network

/// One client socket.
///
/// Owns its parser and its own serial queue. Requests are answered in order —
/// HTTP/1.1 keep-alive with no pipelining is what every client here actually
/// does, and serialising avoids interleaving two responses on one socket.
final class LinkConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.uhmmu.AnimeGod.link.connection")
    private var parser = LinkHTTPParser()
    private let handler: @Sendable (LinkHTTPRequest) async -> LinkRouteResult
    private let onClose: @Sendable (ObjectIdentifier) -> Void
    private var isClosed = false

    /// 256 KB: big enough that a 1080p stream is a handful of writes a second,
    /// small enough that a seek does not sit behind a large read.
    private static let chunkSize = 256 * 1024

    init(
        connection: NWConnection,
        handler: @escaping @Sendable (LinkHTTPRequest) async -> LinkRouteResult,
        onClose: @escaping @Sendable (ObjectIdentifier) -> Void
    ) {
        self.connection = connection
        self.handler = handler
        self.onClose = onClose
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    func close() {
        queue.async { [weak self] in
            guard let self, !self.isClosed else { return }
            self.isClosed = true
            self.connection.cancel()
            self.onClose(ObjectIdentifier(self))
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.parser.append(data)
                self.drain()
            }
            if isComplete || error != nil {
                self.close()
            } else {
                self.receive()
            }
        }
    }

    /// Pulls every complete request out of the buffer and answers them in
    /// turn. `next()` returning nil means "more bytes needed", not "done".
    private func drain() {
        guard !parser.isOverflowed else {
            send(.response(.error(.badRequest, "Request too large.", status: 400)), then: { self.close() })
            return
        }
        guard let request = parser.next() else { return }
        Task { [weak self] in
            guard let self else { return }
            let result = await self.handler(request)
            self.send(result) { self.drain() }
        }
    }

    private func send(_ result: LinkRouteResult, then next: @escaping @Sendable () -> Void) {
        switch result {
        case .response(let response):
            var head = response
            head.headers["Accept-Ranges"] = "bytes"
            var data = head.headData(contentLength: Int64(response.body.count))
            data.append(response.body)
            connection.send(content: data, completion: .contentProcessed { _ in next() })
        case .file(let file):
            sendFile(file, then: next)
        }
    }

    private func sendFile(_ file: LinkFileBody, then next: @escaping @Sendable () -> Void) {
        let resolved = file.range?.resolve(totalSize: file.size)
        if file.range != nil && resolved == nil {
            // A range that starts past the end is a 416, and the header has to
            // say how long the file actually is or the client cannot recover.
            var response = LinkHTTPResponse.error(.badRequest, "Range not satisfiable.", status: 416)
            response.headers["Content-Range"] = "bytes */\(file.size)"
            send(.response(response), then: next)
            return
        }
        let offset = resolved?.offset ?? 0
        let length = resolved?.length ?? file.size

        guard let handle = try? FileHandle(forReadingFrom: file.url) else {
            file.access?.stop()
            send(.response(.error(.notFound, "The file could not be opened.", status: 404)), then: next)
            return
        }

        var headers = [
            "Content-Type": file.contentType,
            "Accept-Ranges": "bytes"
        ]
        if resolved != nil {
            headers["Content-Range"] = "bytes \(offset)-\(offset + length - 1)/\(file.size)"
        }
        let response = LinkHTTPResponse(status: resolved == nil ? 200 : 206, headers: headers)
        connection.send(content: response.headData(contentLength: length), completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else {
                try? handle.close()
                file.access?.stop()
                next()
                return
            }
            try? handle.seek(toOffset: UInt64(offset))
            self.pump(handle: handle, file: file, remaining: length, then: next)
        })
    }

    /// Writes the body a chunk at a time, each one only after the last has
    /// been handed to the kernel. Reading the whole span up front would mean
    /// holding a 1.4 GB episode in memory to answer one seek.
    private func pump(handle: FileHandle, file: LinkFileBody, remaining: Int64, then next: @escaping @Sendable () -> Void) {
        guard remaining > 0 else {
            try? handle.close()
            file.access?.stop()
            next()
            return
        }
        let want = Int(min(remaining, Int64(Self.chunkSize)))
        let chunk = (try? handle.read(upToCount: want)) ?? Data()
        guard !chunk.isEmpty else {
            try? handle.close()
            file.access?.stop()
            next()
            return
        }
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else {
                try? handle.close()
                file.access?.stop()
                next()
                return
            }
            self.pump(handle: handle, file: file, remaining: remaining - Int64(chunk.count), then: next)
        })
    }
}
