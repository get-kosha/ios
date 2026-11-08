import SwiftUI
import PhotosUI
import ImageIO
import UniformTypeIdentifiers
import LocalAuthentication
import Model
import API
import Store
import Design

// Profile and Sign-in & security.

/// Profile: the picture (upload, change, remove, or the initial on the accent), the name, the email, Sign out.
struct ProfilePage: View {
    @Environment(Kosha.self) private var kosha
    @Environment(Toasts.self) private var toasts
    @Environment(\.kosha) private var theme
    @State private var name = ""
    @State private var busy = false
    @State private var pick: PhotosPickerItem?

    var body: some View {
        let c = theme.colors
        let m = kosha.meta
        let w = Writer(kosha: kosha, toasts: toasts)
        Page(L.settings_section_profile(), footer: {
            VStack(spacing: 8) {
                Text(L.settings_cat_autosave()).kFont(.xs).foregroundStyle(c.ink3).frame(maxWidth: .infinity)
                if !kosha.waiting.isEmpty {
                    Text(L.app_signout_waiting(count: kosha.waiting.count)).kFont(.small).foregroundStyle(c.warn)
                }
                KButton(L.settings_profile_sign_out(), style: .secondary, icon: "sign-out") { Task { await kosha.signOut() } }
                Text(L.app_signout_clears()).kFont(.xs).foregroundStyle(c.ink3).frame(maxWidth: .infinity)
            }
        }) {
            Card {
                VStack(spacing: 10) {
                    ProfileAvatar(size: 88)
                    if m?.avatars == true {
                        HStack(spacing: 8) {
                            PhotosPicker(selection: $pick, matching: .images) {
                                PickLabel(text: busy ? L.settings_profile_saving()
                                          : m?.user?.image != nil ? L.settings_profile_change() : L.settings_profile_upload())
                            }
                            .disabled(busy || kosha.demo)
                            if m?.user?.image != nil {
                                KButton(L.common_remove(), style: .secondary, size: .small) { w.send("DELETE", "/api/app/avatar") }
                                    .disabled(busy)
                            }
                        }
                    }
                    Text(L.settings_profile_avatar_hint() + (m?.avatars == true ? " " + L.settings_profile_photo_desc() : ""))
                        .kFont(.xs).foregroundStyle(c.ink3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(L.settings_row_name())
                KField("", text: $name).keyboard(.text)
                SettingsHint(L.settings_profile_name_desc())
            }
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(L.settings_row_email())
                HStack {
                    Text(m?.user?.email ?? "").kFont(.sans(16, .regular)).foregroundStyle(c.ink2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    PhIcon("lock-simple", size: 16, color: c.ink2)
                }
                .padding(.horizontal, 14).frame(minHeight: 48)
                .background(c.soft, in: .rect(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(c.line))
                SettingsHint(L.settings_profile_email_desc())
            }
        }
        .onAppear { if name.isEmpty { name = m?.user?.name ?? "" } }
        .task(id: name) {
            // The name saves itself a moment after typing stops; an empty name isn't saved.
            let next = name.trimmingCharacters(in: .whitespaces)
            guard !next.isEmpty, next != kosha.meta?.user?.name else { return }
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            w.send("PATCH", "/api/app/profile", .object(["name": .string(next)]))
        }
        .onChange(of: pick) { _, item in
            guard let item, !w.refused() else { return }
            busy = true
            Task {
                let data = try? await item.loadTransferable(type: Data.self)
                if let jpeg = data.flatMap(squareJpeg) {
                    w.run({ try await kosha.api.putBytes("/api/app/avatar", type: "image/jpeg", data: jpeg) }, always: { busy = false })
                } else {
                    toasts.show(L.settings_profile_unreadable(), warning: true)
                    busy = false
                }
                pick = nil
            }
        }
    }
}

/// The upload button's face: a small secondary button with a camera.
private struct PickLabel: View {
    let text: String
    @Environment(\.kosha) private var theme
    var body: some View {
        let c = theme.colors
        HStack(spacing: 8) {
            PhIcon("camera", size: 18, color: c.ink)
            Text(text).kFont(.sans(14, .medium)).foregroundStyle(c.ink)
        }
        .padding(.horizontal, 14).frame(minHeight: 36)
        .background(c.surface, in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(c.line))
    }
}

/// A photo as Kosha stores profile pictures: the centre square, at most 512px, JPEG of at most 512 KB.
func squareJpeg(_ data: Data) -> Data? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
              kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
              kCGImageSourceThumbnailMaxPixelSize: 1024,
          ] as CFDictionary) else { return nil }
    let side = min(image.width, image.height)
    guard let square = image.cropping(to: CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2, width: side, height: side))
    else { return nil }
    let target = min(512, side)
    guard let ctx = CGContext(data: nil, width: target, height: target, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(square, in: CGRect(x: 0, y: 0, width: target, height: target))
    guard let scaled = ctx.makeImage() else { return nil }
    var quality = 0.9
    while true {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, scaled, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        if out.length <= 512 * 1024 || quality <= 0.4 { return out as Data }
        quality -= 0.1
    }
}

private let lockAfterChoices = [0, 1, 5, 15, 60]

private func lockLabel(_ minutes: Int) -> String {
    switch minutes {
    case 0: L.app_set_lock_instantly()
    case 60: L.app_set_lock_hour()
    default: L.app_set_lock_minutes(n: "\(minutes)")
    }
}

/// Sign-in & security: how many sign-in steps are done, the app lock on this phone, and the sign-in settings that stay
/// on the web (password, passkeys, Google, two-factor, devices), each opening the server's page.
struct SecurityPage: View {
    @Environment(Kosha.self) private var kosha
    @Environment(Navigator.self) private var nav
    @Environment(\.kosha) private var theme
    @State private var account: AccountSummary?
    @State private var lock = false
    @State private var lockAfter = 1

    private var canLock: Bool { LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) }

    /// "Unlock with Face ID", "… Touch ID", or with the passcode on a device without either.
    private var unlockTitle: String {
        switch AppLock.biometry {
        case .faceID: L.app_ios_set_unlock_face_id()
        case .touchID: L.app_ios_set_unlock_touch_id()
        default: L.app_ios_set_unlock_passcode()
        }
    }

    private var unlockIcon: String {
        switch AppLock.biometry {
        case .faceID: "scan-smiley"
        case .touchID: "fingerprint"
        default: "lock-simple"
        }
    }

    private func web(_ anchor: String) {
        if let url = URL(string: (kosha.server ?? defaultServer) + "/settings/security#\(anchor)") { nav.openWeb?(url) }
    }

    var body: some View {
        let c = theme.colors
        let a = account
        Page(L.settings_section_security()) {
            if let a {
                let steps = securitySteps(a, backupCodesSaved: !kosha.meta.prefOf("backup_codes_saved_at").isEmpty)
                let done = steps.filter(\.done).count
                if done < steps.count {
                    Card {
                        HStack(spacing: 14) {
                            ProgressRing(done: done, total: steps.count)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L.settings_steps_left(count: steps.count - done)).kFont(.head)
                                Text(L.settings_sec_checklist_description()).kFont(.xs).foregroundStyle(c.ink3)
                            }
                        }
                    }
                    Rows {
                        ForEach(steps.indices, id: \.self) { i in
                            let (key, ok) = steps[i]
                            if i > 0 { Hairline() }
                            // Backup codes come with two-factor, and two-factor protects a password, so those wait.
                            let can = !ok && (key != "codes" || a.twoFactor) && (key != "two-factor" || a.hasPassword)
                            HStack(spacing: 12) {
                                Group {
                                    if ok {
                                        PhIcon("check-circle", size: 20, color: c.pos)
                                    } else {
                                        Circle().strokeBorder(c.line, lineWidth: 1.5).frame(width: 22, height: 22)
                                    }
                                }
                                .frame(width: 22)
                                Text(stepLabel(key)).frame(maxWidth: .infinity, alignment: .leading)
                                if can {
                                    // The external-link icon follows the words, as on the board.
                                    KButton(stepAction(key), style: .secondary, size: .small, icon: "arrow-square-out") { web("checklist") }
                                        .environment(\.layoutDirection, .rightToLeft)
                                }
                            }
                            .padding(.horizontal, 16).padding(.vertical, 10).frame(minHeight: theme.dims.settingsRow)
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(ok ? .isSelected : [])
                        }
                    }
                }
            }

            GroupCaption(L.app_set_on_phone())
            Rows {
                SettingsSwitchRow(unlockTitle, description: canLock ? L.app_ios_set_unlock_desc() : L.app_ios_set_unlock_unavailable(),
                          isOn: Binding(get: { lock }, set: setLock), enabled: canLock || lock, icon: unlockIcon)
                if lock {
                    Hairline()
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L.app_set_lock_after()).kFont(.head)
                        Segmented(lockAfterChoices.map { ($0, lockLabel($0)) }, selection: Binding(
                            get: { lockAfter },
                            set: { lockAfter = $0; kosha.local.lockAfter = $0 }
                        ), small: true)
                    }
                    .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 14)
                }
            }
            SettingsHint(L.app_set_lock_note())

            SoftNote("globe-simple", L.app_set_opens_web(host: serverHost(kosha.server)))

            GroupCaption(L.settings_sec_signin())
            Rows {
                let hasPassword = a?.hasPassword != false
                NavRow(L.settings_sec_password(),
                       description: hasPassword ? L.settings_sec_password_description() : L.settings_sec_password_description_none(),
                       value: hasPassword ? L.settings_sec_change_password() : L.settings_sec_set_a_password(), external: true) { web("password") }
                Hairline()
                NavRow(L.settings_sec_passkeys() + ((a?.passkeys ?? 0) > 0 ? " · \(a!.passkeys)" : ""),
                       description: L.settings_sec_passkeys_description(), value: L.common_add(), external: true) { web("passkeys") }
                if let google = a?.google {
                    Hairline()
                    NavRow("Google", description: google.accountId == nil ? L.settings_sec_google_description_none()
                           : a?.hasPassword == true ? L.settings_sec_google_description_on() : L.settings_sec_google_description_no_password(),
                           external: true) { web("google") }
                }
                Hairline()
                NavRow(L.settings_sec_two_factor(),
                       description: a?.twoFactor == true ? L.settings_sec_two_factor_on()
                           : a?.hasPassword == false ? L.settings_sec_two_factor_need_password() : L.settings_sec_two_factor_off(),
                       external: true,
                       titleExtra: { if a?.twoFactor == true { Pill(L.settings_appearance_on(), color: c.pos) } }) { web("two-factor") }
            }
            GroupCaption(L.settings_sec_devices())
            Rows {
                NavRow(L.settings_row_devices(), description: L.settings_row_devices_desc(), icon: "device-mobile", external: true) { web("devices") }
            }
        }
        .load("account", into: $account) { try await $0.get("/api/app/account") }
        .onAppear {
            lock = kosha.local.lock
            lockAfter = kosha.local.lockAfter
        }
    }

    /// Turning the lock on asks once, so nobody locks themselves out with Face ID that won't work.
    private func setLock(_ on: Bool) {
        guard on else {
            lock = false
            kosha.local.lock = false
            return
        }
        Task {
            let ok = (try? await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: unlockTitle)) == true
            if ok {
                lock = true
                kosha.local.lock = true
            }
        }
    }

    private func stepLabel(_ key: String) -> String {
        switch key {
        case "password": L.settings_sec_step_password()
        case "passkey": L.settings_sec_step_passkey()
        case "two-factor": L.settings_sec_two_factor()
        default: L.settings_sec_step_codes()
        }
    }

    private func stepAction(_ key: String) -> String {
        switch key {
        case "password": L.settings_sec_action_set()
        case "passkey": L.common_add()
        case "two-factor": L.settings_sec_action_turn_on()
        default: L.settings_sec_action_save_codes()
        }
    }
}

/// "2/4" in a ring that fills in the accent as steps are done.
private struct ProgressRing: View {
    let done: Int
    let total: Int
    @Environment(\.kosha) private var theme

    var body: some View {
        ZStack {
            Circle().stroke(theme.colors.soft, lineWidth: 6)
            Circle().trim(from: 0, to: CGFloat(done) / CGFloat(max(total, 1)))
                .stroke(theme.colors.brand, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(done)/\(total)").kFont(.figure(13, .regular))
        }
        .padding(4)
        .frame(width: 52, height: 52)
        .accessibilityElement()
        .accessibilityLabel(L.settings_sec_ring_label(done: "\(done)", total: "\(total)"))
    }
}
