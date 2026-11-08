import Foundation

/// Settings that belong to this phone only: the app lock, the account Add used last, and when the app went to the
/// background. Everything else is a synced preference in `meta.prefs`.
public final class LocalPrefs: @unchecked Sendable {
    private let d: UserDefaults

    public init(defaults: UserDefaults = UserDefaults(suiteName: "group.app.getkosha") ?? .standard) { d = defaults }

    /// Settings › Sign-in & security › Unlock with Face ID.
    public var lock: Bool {
        get { d.bool(forKey: "lock") }
        set { d.set(newValue, forKey: "lock") }
    }

    /// Minutes in the background before the lock comes back: 0 (instantly), 1, 5, 15 or 60.
    public var lockAfter: Int {
        get { d.object(forKey: "lock_after") as? Int ?? 1 }
        set { d.set(newValue, forKey: "lock_after") }
    }

    /// The account Add used last on this phone, for "Default account: Last used".
    public var lastAccount: String? {
        get { d.string(forKey: "last_account") }
        set { d.set(newValue, forKey: "last_account") }
    }

    /// When the app last went to the background, for the lock.
    public var backgroundedAt: Date? {
        get { d.object(forKey: "backgrounded_at") as? Date }
        set { d.set(newValue, forKey: "backgrounded_at") }
    }

    public func clear() {
        for k in ["last_account", "backgrounded_at"] { d.removeObject(forKey: k) }
    }
}
