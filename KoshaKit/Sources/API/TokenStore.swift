import Foundation
import Security
import Model

/// A signed-in session: which server, and the tokens for it.
public struct Tokens: Codable, Sendable, Equatable {
    /// The server's origin, such as https://getkosha.app.
    public var server: String
    public var clientId: String
    public var access: String
    public var refresh: String
    /// Unix seconds when `access` expires.
    public var expiresAt: Int64

    public init(server: String, clientId: String, access: String, refresh: String, expiresAt: Int64) {
        self.server = server
        self.clientId = clientId
        self.access = access
        self.refresh = refresh
        self.expiresAt = expiresAt
    }
}

/// Keeps the session in the Keychain, readable after the first unlock and never leaving this device (not in backups),
/// so a restored phone signs in again. The access group lets the widget read it.
public final class TokenStore: @unchecked Sendable {
    private let service: String
    private let account = "tokens"
    private let accessGroup: String?
    private let lock = NSLock()
    private var cached: Tokens?
    private var loaded = false
    private var generation = UUID()

    var sessionID: UUID { lock.withLock { generation } }

    /// `accessGroup` is "<team>.app.getkosha", shared by the app and its widget; nil uses the app's default group.
    public init(accessGroup: String? = nil) {
        self.service = "app.getkosha.session"
        self.accessGroup = accessGroup
    }

    init(service: String) {
        self.service = service
        self.accessGroup = nil
    }

    private var query: [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup { q[kSecAttrAccessGroup as String] = accessGroup }
        return q
    }

    public func read() -> Tokens? {
        lock.lock()
        defer { lock.unlock() }
        if loaded { return cached }
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecSuccess, let data = out as? Data {
            cached = try? KoshaJSON.decode(Tokens.self, data)
        }
        // A locked Keychain is temporary; try reading again after the device unlocks.
        loaded = status == errSecSuccess || status == errSecItemNotFound
        return cached
    }

    /// Stores the new tokens before anyone uses them, so a rotated refresh token is never lost.
    public func write(_ tokens: Tokens) {
        try? save(tokens)
    }

    func save(_ tokens: Tokens, rotating: Bool = false) throws {
        lock.lock()
        defer { lock.unlock() }
        let data = try KoshaJSON.encode(tokens)
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attrs) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        if !rotating { generation = UUID() }
        cached = tokens
        loaded = true
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        SecItemDelete(query as CFDictionary)
        generation = UUID()
        cached = nil
        loaded = true
    }
}
