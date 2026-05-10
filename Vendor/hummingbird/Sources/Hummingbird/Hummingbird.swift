import Darwin
import Foundation
import NIOCore

/// Minimal HTTP header name compatible with the Hummingbird API used here.
public struct HTTPFieldName: Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawName: String

    public init(_ rawName: String) {
        self.rawName = rawName.lowercased()
    }

    public init(stringLiteral value: StringLiteralType) {
        self.init(value)
    }

    public static let authorization = HTTPFieldName("authorization")
    public static let cacheControl = HTTPFieldName("cache-control")
    public static let connection = HTTPFieldName("connection")
    public static let contentLength = HTTPFieldName("content-length")
    public static let contentType = HTTPFieldName("content-type")
}

/// Minimal HTTP header collection compatible with the Hummingbird API used here.
public struct HTTPFields: Sendable, ExpressibleByDictionaryLiteral {
    private var storage: [HTTPFieldName: String]

    public init() {
        self.storage = [:]
    }

    public init(dictionaryLiteral elements: (HTTPFieldName, String)...) {
        self.storage = Dictionary(uniqueKeysWithValues: elements)
    }

    public subscript(name: HTTPFieldName) -> String? {
        get { storage[name] }
        set { storage[name] = newValue }
    }

    fileprivate var headerLines: [String] {
        storage.map { "\($0.key.rawName): \($0.value)\r\n" }
    }
}

/// Minimal HTTP request passed to route handlers.
public struct Request: Sendable {
    public let method: String
    public let path: String
    public let headers: HTTPFields
    public let body: Data

    public init(method: String, path: String, headers: HTTPFields, body: Data = Data()) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }
}

/// Minimal request context placeholder for route handlers.
public struct BasicRequestContext: Sendable {
    public init() {}
}

/// Minimal HTTP response status value.
public struct HTTPResponseStatus: Sendable, Equatable {
    public let code: Int
    public let reasonPhrase: String

    public init(code: Int, reasonPhrase: String) {
        self.code = code
        self.reasonPhrase = reasonPhrase
    }

    public static let ok = HTTPResponseStatus(code: 200, reasonPhrase: "OK")
    public static let notFound = HTTPResponseStatus(code: 404, reasonPhrase: "Not Found")
    public static let internalServerError = HTTPResponseStatus(code: 500, reasonPhrase: "Internal Server Error")
    public static let unauthorized = HTTPResponseStatus(code: 401, reasonPhrase: "Unauthorized")
    public static let badRequest = HTTPResponseStatus(code: 400, reasonPhrase: "Bad Request")
    public static let payloadTooLarge = HTTPResponseStatus(code: 413, reasonPhrase: "Payload Too Large")
    public static let unsupportedMediaType = HTTPResponseStatus(code: 415, reasonPhrase: "Unsupported Media Type")
    public static let conflict = HTTPResponseStatus(code: 409, reasonPhrase: "Conflict")
    public static let methodNotAllowed = HTTPResponseStatus(code: 405, reasonPhrase: "Method Not Allowed")
    public static let created = HTTPResponseStatus(code: 201, reasonPhrase: "Created")
    public static let noContent = HTTPResponseStatus(code: 204, reasonPhrase: "No Content")
}

/// Writes streaming response body chunks.
public struct ResponseBodyWriter: Sendable {
    private let writeBuffer: @Sendable (ByteBuffer) async throws -> Void

    public init(writeBuffer: @escaping @Sendable (ByteBuffer) async throws -> Void) {
        self.writeBuffer = writeBuffer
    }

    public func write(_ buffer: ByteBuffer) async throws {
        try await writeBuffer(buffer)
    }
}

/// Represents fixed or streaming HTTP response bodies.
public struct ResponseBody: Sendable {
    fileprivate enum Storage: Sendable {
        case fixed(ByteBuffer)
        case stream(@Sendable (ResponseBodyWriter) async throws -> Void)
    }

    fileprivate let storage: Storage

    public init(byteBuffer: ByteBuffer) {
        self.storage = .fixed(byteBuffer)
    }

    public init(_ stream: @escaping @Sendable (ResponseBodyWriter) async throws -> Void) {
        self.storage = .stream(stream)
    }
}

/// Minimal HTTP response returned by route handlers.
public struct Response: Sendable {
    public let status: HTTPResponseStatus
    public var headers: HTTPFields
    public let body: ResponseBody

    public init(status: HTTPResponseStatus = .ok, headers: HTTPFields = HTTPFields(), body: ResponseBody) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

/// Minimal router compatible with the Hummingbird API used here. Supports
/// exact-match routes (registered via `get`/`post`/`delete`) and dynamic
/// path-prefix routes (`prefix`) for endpoints like
/// `/runners/<id>/frames/<idx>.png` whose full path is only known at
/// request time.
public final class Router: @unchecked Sendable {
    public typealias Handler = @Sendable (Request, BasicRequestContext) async throws -> Response

    private var routes: [String: Handler] = [:]
    private var prefixRoutes: [(method: String, prefix: String, handler: Handler)] = []

    public init() {}

    public func get(_ path: String..., use handler: @escaping Handler) {
        routes["GET /\(path.joined(separator: "/"))"] = handler
    }

    public func post(_ path: String..., use handler: @escaping Handler) {
        routes["POST /\(path.joined(separator: "/"))"] = handler
    }

    public func delete(_ path: String..., use handler: @escaping Handler) {
        routes["DELETE /\(path.joined(separator: "/"))"] = handler
    }

    /// Register a prefix-matched handler. Matched after exact routes miss.
    /// `prefix` should include leading slash and trailing slash where the
    /// dynamic suffix begins, e.g. `"/runners/"`.
    public func prefix(_ method: String, _ prefix: String, use handler: @escaping Handler) {
        prefixRoutes.append((method.uppercased(), prefix, handler))
    }

    fileprivate func handler(method: String, path: String) -> Handler? {
        if let exact = routes["\(method) \(path)"] { return exact }
        for entry in prefixRoutes
            where entry.method == method && path.hasPrefix(entry.prefix) && path.count > entry.prefix.count
        {
            return entry.handler
        }
        return nil
    }
}

/// Minimal application configuration.
public struct ApplicationConfiguration: Sendable {
    /// Minimal listen address.
    public enum Address: Sendable {
        case hostname(String, port: Int)
    }

    public let address: Address

    public init(address: Address = .hostname("127.0.0.1", port: 8080)) {
        self.address = address
    }
}

/// Minimal Hummingbird-compatible application runner.
public final class Application: @unchecked Sendable {
    private let server: SocketServer

    public init(router: Router, configuration: ApplicationConfiguration = ApplicationConfiguration()) {
        let host: String
        let port: Int
        switch configuration.address {
        case let .hostname(value, configuredPort):
            host = value
            port = configuredPort
        }
        self.server = SocketServer(host: host, port: port, router: router)
    }

    /// Runs the server until `stop()` is called or the surrounding task is
    /// cancelled. SIGPIPE is ignored process-wide so a peer disconnecting
    /// mid-write doesn't take the daemon down.
    public func runService() async throws {
        signal(SIGPIPE, SIG_IGN)
        try await server.run()
    }

    /// Stops accepting new connections and asks the accept loop to unwind.
    /// In-flight request tasks complete on their own (they're tracked in a
    /// `withThrowingDiscardingTaskGroup` inside `run()`).
    public func stop() {
        server.stop()
    }
}

private final class SocketServer: @unchecked Sendable {
    let host: String
    let port: Int
    let router: Router
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var stopping = false

    init(host: String, port: Int, router: Router) {
        self.host = host
        self.port = port
        self.router = router
    }

    func stop() {
        let fd: Int32 = lock.withLockSync {
            stopping = true
            let prev = listenFD
            listenFD = -1
            return prev
        }
        if fd >= 0 {
            _ = Darwin.shutdown(fd, Int32(SHUT_RDWR))
            _ = Darwin.close(fd)
        }
    }

    private var shouldStop: Bool {
        lock.withLockSync { stopping }
    }

    func run() async throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.operation("socket", errno) }
        lock.withLockSync { listenFD = fd }
        // If we exit through a thrown error, still close the listening
        // socket so the OS port is released. `stop()` is idempotent.
        defer { stop() }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
            throw SocketError.operation("inet_pton", errno)
        }

        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw SocketError.operation("bind", errno) }
        guard listen(fd, 128) == 0 else { throw SocketError.operation("listen", errno) }

        // Track every accepted client task in a structured group. Without
        // this, request tasks are detached and a graceful shutdown can't
        // wait for them to finish — they'd be torn down mid-write.
        let routerRef = self.router
        try await withThrowingDiscardingTaskGroup { group in
            while !Task.isCancelled && !shouldStop {
                // Poll instead of blocking accept so cancellation /
                // `stop()` can break us out within ~250 ms instead of
                // waiting for the next connection.
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = Darwin.poll(&pfd, 1, 250)
                if ready == 0 { continue }
                if ready < 0 {
                    let code = errno
                    if code == EINTR { continue }
                    if shouldStop || Task.isCancelled { break }
                    throw SocketError.operation("poll", code)
                }
                let client = accept(fd, nil, nil)
                if client < 0 {
                    let code = errno
                    if shouldStop || Task.isCancelled { break }
                    if code == EBADF || code == EINVAL { break }
                    if code == EINTR { continue }
                    throw SocketError.operation("accept", code)
                }
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
                // Bound blocking read/write so a misbehaving (or stuck) peer
                // can't pin a request task forever and hang graceful
                // shutdown — the task group inside `run()` waits for every
                // child, and `Darwin.read` / `Darwin.write` ignore Swift
                // task cancellation. 30 s is generous for a header read and
                // for the kernel send buffer to drain on a normal client;
                // for a stuck client it surfaces as a thrown `SocketError`
                // and lets the response handler exit.
                var rcv = timeval(tv_sec: 30, tv_usec: 0)
                var snd = timeval(tv_sec: 30, tv_usec: 0)
                setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &rcv, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &snd, socklen_t(MemoryLayout<timeval>.size))
                group.addTask {
                    await handle(client: client, router: routerRef)
                }
            }
        }
    }
}

private extension NSLock {
    /// Synchronous lock helper that keeps the call site small. Named with
    /// `Sync` to avoid colliding with the async-only `withLock` future
    /// versions of Foundation may add.
    func withLockSync<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

private func handle(client fd: Int32, router: Router) async {
    defer { close(fd) }
    do {
        let request = try readRequest(fd: fd)
        let response: Response
        if let handler = router.handler(method: request.method, path: request.path) {
            response = try await handler(request, BasicRequestContext())
        } else {
            response = Response(
                status: .notFound,
                headers: [.contentType: "text/plain; charset=utf-8"],
                body: .init(byteBuffer: ByteBuffer(string: "not found")))
        }
        try await write(response: response, fd: fd)
    } catch {
        let body = ByteBuffer(string: "internal server error")
        let response = Response(
            status: .internalServerError,
            headers: [.contentType: "text/plain; charset=utf-8"],
            body: .init(byteBuffer: body))
        try? await write(response: response, fd: fd)
    }
}

/// Hard cap on request body size we are willing to accept. Sized for the
/// runner upload route — 16 PNG frames × 1 MB raw, base64 encodes to ~22 MB,
/// plus JSON wrapper overhead. 32 MB gives headroom and still bounds memory.
private let maxRequestBodyBytes = 32 * 1024 * 1024

private func readRequest(fd: Int32) throws -> Request {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    // Phase 1: read until we have full headers (\r\n\r\n).
    var headerEnd: Int? = nil
    while headerEnd == nil {
        let count = Darwin.read(fd, &buffer, buffer.count)
        guard count > 0 else { throw SocketError.operation("read", errno) }
        data.append(buffer, count: count)
        if let range = data.range(of: Data("\r\n\r\n".utf8)) {
            headerEnd = range.upperBound
        } else if data.count > 64 * 1024 {
            throw SocketError.operation("headers_too_large", 0)
        }
    }
    let headerData = data.subdata(in: 0..<headerEnd!)
    var bodyData = data.subdata(in: headerEnd!..<data.count)

    guard let headerText = String(data: headerData, encoding: .utf8) else {
        throw SocketError.operation("utf8", errno)
    }
    let lines = headerText.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else {
        throw SocketError.operation("requestLine", errno)
    }
    let parts = requestLine.split(separator: " ")
    guard parts.count >= 2 else {
        throw SocketError.operation("requestParts", errno)
    }
    var headers = HTTPFields()
    for line in lines.dropFirst() {
        guard let separator = line.firstIndex(of: ":") else { continue }
        let name = String(line[..<separator])
        let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        headers[HTTPFieldName(name)] = value
    }

    // Phase 2: drain body up to Content-Length. Protect against silently
    // ballooning into a multi-GB allocation if a client lies in the header.
    if let lengthText = headers[.contentLength], let length = Int(lengthText), length > 0 {
        if length > maxRequestBodyBytes {
            throw SocketError.operation("body_too_large", 0)
        }
        while bodyData.count < length {
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count > 0 else { throw SocketError.operation("read_body", errno) }
            let needed = length - bodyData.count
            bodyData.append(buffer, count: min(count, needed))
        }
    }

    let rawPath = String(parts[1])
    let path = rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawPath
    return Request(method: String(parts[0]), path: path, headers: headers, body: bodyData)
}

private func write(response: Response, fd: Int32) async throws {
    var headers = response.headers
    let head = "HTTP/1.1 \(response.status.code) \(response.status.reasonPhrase)\r\n"
    try writeAll(fd: fd, data: Data(head.utf8))
    switch response.body.storage {
    case let .fixed(buffer):
        headers[.contentLength] = "\(buffer.data.count)"
        for line in headers.headerLines {
            try writeAll(fd: fd, data: Data(line.utf8))
        }
        try writeAll(fd: fd, data: Data("\r\n".utf8))
        try writeAll(fd: fd, data: buffer.data)
    case let .stream(stream):
        for line in headers.headerLines {
            try writeAll(fd: fd, data: Data(line.utf8))
        }
        try writeAll(fd: fd, data: Data("\r\n".utf8))
        let writer = ResponseBodyWriter { buffer in
            try writeAll(fd: fd, data: buffer.data)
        }
        try await stream(writer)
    }
}

private func writeAll(fd: Int32, data: Data) throws {
    try data.withUnsafeBytes { rawBuffer in
        guard let base = rawBuffer.baseAddress else { return }
        var offset = 0
        while offset < rawBuffer.count {
            let written = Darwin.write(fd, base.advanced(by: offset), rawBuffer.count - offset)
            if written <= 0 {
                throw SocketError.operation("write", errno)
            }
            offset += written
        }
    }
}

private enum SocketError: Error {
    case operation(String, Int32)
}
