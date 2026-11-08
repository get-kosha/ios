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
    private let service = "app.getkosha.session"
    private let account = "tokens"
    private let accessGroup: String?
    private let lock = NSLock()
    private var cached: Tokens?
    private var loaded = false

    /// `accessGroup` is "<team>.app.getkosha", shared by the app and its widget; nil uses the app's default group.
    public init(accessGroup: String? = nil) { self.accessGroup = accessGroup }

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
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data {
            cached = try? KoshaJSON.decode(Tokens.self, data)
        }
        loaded = true
        return cached
    }

    /// Stores the new tokens before anyone uses them, so a rotated refresh token is never lost.
    public func write(_ tokens: Tokens) {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? KoshaJSON.encode(tokens) else { return }
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        if SecItemUpdate(query as CFDictionary, attrs as CFDictionary) == errSecItemNotFound {
            SecItemAdd(query.merging(attrs) { $1 } as CFDictionary, nil)
        }
        cached = tokens
        loaded = true
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        SecItemDelete(query as CFDictionary)
        cached = nil
        loaded = true
    }
}
