import Foundation
import Model

/// Kosha's API: the public operations under /api/v1 and the app's own endpoints under /api/app. Every request carries
/// the access token; a 401 refreshes it once (one refresh at a time) and retries. Errors arrive as `KoshaError.api`
/// with the server's message; no connection is `KoshaError.offline`. Requests ask for the app's language, so the app
/// endpoints, the API's errors and AI replies answer in it.
public final class KoshaAPI: Sendable {
    public let store: TokenStore
    public let auth: Auth
    let session: URLSession
    let language: @Sendable () -> String

    public init(store: TokenStore, auth: Auth, session: URLSession = .shared, language: @escaping @Sendable () -> String) {
        self.store = store
        self.auth = auth
        self.session = session
        self.language = language
    }

    public var server: String? { store.read()?.server }

    public func get<T: Decodable>(_ path: String, query: [String: String?] = [:]) async throws -> T {
        try decode(await call("GET", path, query: query, body: nil))
    }

    public func post<T: Decodable>(_ path: String, _ body: some Encodable) async throws -> T {
        try decode(await call("POST", path, body: json(body)))
    }

    public func patch<T: Decodable>(_ path: String, _ body: some Encodable) async throws -> T {
        try decode(await call("PATCH", path, body: json(body)))
    }

    public func put<T: Decodable>(_ path: String, _ body: some Encodable) async throws -> T {
        try decode(await call("PUT", path, body: json(body)))
    }

    public func delete<T: Decodable>(_ path: String, query: [String: String?] = [:]) async throws -> T {
        try decode(await call("DELETE", path, query: query, body: nil))
    }

    /// A request whose answer is ignored or empty (204).
    public func send(_ method: String, _ path: String, body: (any Encodable)? = nil, query: [String: String?] = [:]) async throws {
        _ = try await call(method, path, query: query, body: body.map(json))
    }

    /// Uploads one file as the multipart form field `file`; returns the answer's bytes.
    @discardableResult
    public func upload(_ path: String, name: String, type: String, data: Data) async throws -> Data {
        let boundary = "kosha-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(name)\"\r\nContent-Type: \(type)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        return try await call("POST", path, body: (body, "multipart/form-data; boundary=\(boundary)"))
    }

    /// Raw bytes, for attachments, avatars and exports.
    public func bytes(_ path: String, query: [String: String?] = [:]) async throws -> Data {
        try await call("GET", path, query: query, body: nil)
    }

    /// Raw bytes as the body of a PUT, such as a profile picture.
    public func putBytes(_ path: String, type: String, data: Data) async throws {
        _ = try await call("PUT", path, body: (data, type))
    }

    public func decode<T: Decodable>(_ data: Data) throws -> T {
        if T.self == Empty.self { return Empty() as! T }
        return try KoshaJSON.decode(T.self, data)
    }

    private func json(_ value: any Encodable) -> (Data, String) {
        ((try? KoshaJSON.encode(value)) ?? Data("{}".utf8), "application/json")
    }

    public func call(_ method: String, _ path: String, query: [String: String?] = [:], body: (Data, String)?) async throws -> Data {
        guard var tokens = store.read() else { throw KoshaError.signedOut }
        for attempt in 0..<2 {
            guard var c = URLComponents(string: tokens.server + path) else { throw KoshaError.signedOut }
            let items = query.compactMap { k, v in v.map { URLQueryItem(name: k, value: $0) } }
            if !items.isEmpty { c.queryItems = (c.queryItems ?? []) + items.sorted { $0.name < $1.name } }
            var req = URLRequest(url: c.url!)
            req.httpMethod = method
            req.setValue("Bearer \(tokens.access)", forHTTPHeaderField: "Authorization")
            req.setValue(language(), forHTTPHeaderField: "Accept-Language")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            if let (data, type) = body {
                req.httpBody = data
                req.setValue(type, forHTTPHeaderField: "Content-Type")
            } else if method != "GET" && method != "DELETE" {
                req.httpBody = Data()
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let data: Data
            let res: URLResponse
            do { (data, res) = try await session.data(for: req) } catch let e as URLError where e.code != .cancelled {
                throw KoshaError.offline
            }
            let status = (res as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 && attempt == 0 {
                // A refused refresh ends the session (Auth has cleared it): the app shows sign-in.
                do {
                    guard let next = try await auth.refresh(failed: tokens.access) else { throw KoshaError.signedOut }
                    tokens = next
                } catch KoshaError.auth {
                    throw KoshaError.signedOut
                }
                continue
            }
            if status == 401 {
                store.clear()
                throw KoshaError.signedOut
            }
            guard (200..<300).contains(status) else {
                let error = (try? KoshaJSON.decode(ErrorBody.self, data))?.error
                    ?? ApiError(message: String(String(decoding: data, as: UTF8.self).prefix(300)))
                throw KoshaError.api(status: status, error: error)
            }
            return data
        }
        throw KoshaError.signedOut
    }
}

/// An answer with nothing to read.
public struct Empty: Codable, Sendable { public init() {} }
