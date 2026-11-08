import Foundation
import Testing
@testable import API

struct Reply: Sendable {
    var status = 200
    var body = "{}"
    var headers: [String: String] = [:]
}

final class HTTPStub: URLProtocol, @unchecked Sendable {
    final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var handlers: [String: @Sendable (URLRequest) async throws -> Reply] = [:]
    }
    static let registry = Registry()
    private let lock = NSLock()
    private var work: Task<Void, Never>?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let handler = Self.registry.lock.withLock { Self.registry.handlers[request.url!.host!]! }
        let task = Task {
            do {
                let reply = try await handler(request)
                let response = HTTPURLResponse(url: request.url!, statusCode: reply.status,
                                               httpVersion: nil, headerFields: reply.headers)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
        lock.withLock { work = task }
    }
    override func stopLoading() { lock.withLock { work?.cancel() } }
}

final class HTTPFixture: @unchecked Sendable {
    let host = UUID().uuidString.lowercased() + ".example"
    var server: String { "https://" + host }
    let session: URLSession
    let store: TokenStore
    let keychainService = "app.getkosha.tests." + UUID().uuidString
    var auth: Auth { Auth(store: store, session: session) }
    init(_ handler: @escaping @Sendable (URLRequest) async throws -> Reply) {
        // An isolated Keychain namespace: tests never read or clear the app's real session.
        store = TokenStore(service: keychainService)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPStub.self]
        session = URLSession(configuration: config)
        HTTPStub.registry.lock.withLock { HTTPStub.registry.handlers[host] = handler }
    }
    deinit {
        session.invalidateAndCancel()
        store.clear()
        _ = HTTPStub.registry.lock.withLock { HTTPStub.registry.handlers.removeValue(forKey: host) }
    }
    @discardableResult func signIn() -> Tokens {
        let tokens = Tokens(server: server, clientId: clientId, access: "access-0", refresh: "refresh-0", expiresAt: 0)
        store.write(tokens)
        return tokens
    }
    func api(auth: Auth? = nil) -> KoshaAPI {
        KoshaAPI(store: store, auth: auth ?? self.auth, session: session) { "de" }
    }
}

actor Requests {
    private(set) var all: [URLRequest] = []
    func record(_ request: URLRequest) {
        var copy = request
        copy.httpBody = requestBody(request)
        all.append(copy)
    }
}

actor Gate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        open = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

func requestBody(_ request: URLRequest) -> Data? {
    var data = request.httpBody
    if data == nil, let stream = request.httpBodyStream {
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 1024)
        var bytes = Data()
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            bytes.append(contentsOf: buffer.prefix(n))
        }
        data = bytes
    }
    return data
}

func form(_ request: URLRequest) -> [String: String] {
    let query = String(decoding: requestBody(request) ?? Data(), as: UTF8.self)
    return Dictionary((URLComponents(string: "https://example.test/?" + query)?.queryItems ?? [])
        .map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, b in b })
}
