import SwiftUI
import LocalAuthentication
import Store
import Design

/// Settings › Sign-in & security › On this phone: unlock with Face ID or Touch ID (or the passcode), and lock again
/// after some time in the background. The app covers its content in the app switcher while locked or inactive.
@MainActor @Observable
public final class AppLock {
    public private(set) var locked = false
    private let kosha: Kosha

    public init(kosha: Kosha) {
        self.kosha = kosha
        // At launch: locked whenever the lock is on.
        locked = kosha.local.lock && kosha.signedIn
    }

    public func backgrounded() { kosha.local.backgroundedAt = Date() }

    public func foregrounded() {
        guard kosha.local.lock, kosha.signedIn else { return }
        let away = Date().timeIntervalSince(kosha.local.backgroundedAt ?? .distantPast)
        if away >= Double(kosha.local.lockAfter * 60) { locked = true }
    }

    public func unlock() async {
        let context = LAContext()
        var error: NSError?
        // .deviceOwnerAuthentication offers the passcode after Face ID or Touch ID.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            locked = false
            return
        }
        if (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: L.app_lock_prompt())) == true {
            locked = false
        }
    }

    /// Whether the phone can lock the app at all, and which kind of biometrics it has, for Settings.
    public static var biometry: LABiometryType {
        let c = LAContext()
        _ = c.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return c.biometryType
    }
}

/// "Kosha is locked. Locked after a minute away." with Unlock. The prompt opens by itself.
public struct LockScreen: View {
    let lock: AppLock
    @Environment(Kosha.self) private var kosha
    @Environment(\.kosha) private var theme

    public init(lock: AppLock) { self.lock = lock }

    public var body: some View {
        let c = theme.colors
        let minutes = kosha.local.lockAfter
        VStack(spacing: 12) {
            Spacer()
            PhIcon("lock-simple", size: 28, color: c.ink2)
                .frame(width: 64, height: 64)
                .background(c.soft, in: .circle)
            Text(L.app_lock_title()).kFont(.title).accessibilityAddTraits(.isHeader)
            Text(minutes == 0 ? L.app_lock_left() : L.app_lock_after(count: minutes))
                .kFont(.body).foregroundStyle(c.ink2).multilineTextAlignment(.center)
            Spacer()
            KButton(L.app_lock_unlock(), icon: unlockIcon) { Task { await lock.unlock() } }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(c.bg)
        .task { await lock.unlock() }
    }

    private var unlockIcon: String {
        switch AppLock.biometry {
        case .faceID: "scan-smiley"
        case .touchID: "fingerprint"
        default: "lock-simple-open"
        }
    }
}

/// What the app switcher shows while the app isn't active: the brand ground, so no amounts show.
public struct PrivacyCover: View {
    public init() {}
    public var body: some View { LaunchScreen() }
}
