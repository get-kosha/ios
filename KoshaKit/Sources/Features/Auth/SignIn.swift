import SwiftUI
import AuthenticationServices
import Model
import API
import Store
import Design

/// Where a sign-in is.
public enum SignInStep: Equatable, Sendable {
    case idle
    /// The browser is open on the server's sign-in page.
    case browsing(host: String)
    /// Back from the browser: exchanging the code, then loading the account. `done` counts the finished lines.
    case finishing(host: String, done: Int)
    /// The browser closed without an answer, or the server refused. Nothing was changed.
    case failed(host: String, message: String?)
}

/// Sign-in through ASWebAuthenticationSession, sharing Safari's cookies (not ephemeral), so the "opens getkosha.app"
/// settings pages find the same web session. On getkosha.app the session finishes on the server's HTTPS callback, which
/// the app claims through apple-app-site-association (webcredentials). Elsewhere (a self-hosted or local server) it
/// waits for app.getkosha:/oauth/callback from the callback page's Open Kosha button. Ported from SignInFlow.kt.
@MainActor @Observable
public final class SignInFlow {
    public private(set) var step: SignInStep = .idle
    private let kosha: Kosha

    public init(kosha: Kosha) { self.kosha = kosha }

    public enum Check: Sendable {
        case found(PendingSignIn)
        case notFound
        case tooOld
    }

    static func host(_ server: String) -> String { URL(string: server)?.host ?? server }

    /// Checks a server: it must answer OAuth discovery and have the app endpoints (Kosha from November 2026 on).
    public func check(_ server: String) async -> Check {
        do {
            let found = try await kosha.auth.discover(server)
            // The app endpoints answer 401 without a token; a server from before them answers 404.
            guard let url = URL(string: "\(server)/api/app/meta") else { return .notFound }
            let (_, res) = try await URLSession.shared.data(from: url)
            return (res as? HTTPURLResponse)?.statusCode == 401 ? .found(found) : .tooOld
        } catch {
            return .notFound
        }
    }

    /// Opens the server's sign-in page and finishes when it hands back. `demo` signs in to the demo account.
    public func begin(_ server: String, demo: Bool = false, session: WebAuthenticationSession) async {
        let host = Self.host(server)
        guard case .found(let found) = await check(server) else {
            step = .failed(host: host, message: nil)
            return
        }
        let pending = kosha.auth.start(found, demo: demo)
        guard let url = URL(string: pending.url) else { return }
        step = .browsing(host: host)
        do {
            let answer: URL
            if pending.httpsCallback {
                do {
                    answer = try await session.authenticate(
                        using: url, callback: .https(host: host, path: callbackPath), preferredBrowserSession: .shared,
                        additionalHeaderFields: [:]
                    )
                } catch let e as ASWebAuthenticationSessionError where e.code != .canceledLogin {
                    // The association isn't verified (yet): finish through the page's Open Kosha button instead.
                    answer = try await session.authenticate(
                        using: url, callback: .customScheme(fallbackScheme), preferredBrowserSession: .shared,
                        additionalHeaderFields: [:]
                    )
                }
            } else {
                answer = try await session.authenticate(
                    using: url, callback: .customScheme(fallbackScheme), preferredBrowserSession: .shared,
                    additionalHeaderFields: [:]
                )
            }
            await finish(pending, answer)
        } catch {
            step = .failed(host: host, message: nil)
        }
    }

    private func finish(_ pending: PendingSignIn, _ answer: URL) async {
        let host = Self.host(pending.server)
        step = .finishing(host: host, done: 0)
        do {
            _ = try await kosha.auth.finish(pending, redirect: answer)
            step = .finishing(host: host, done: 1)
            await kosha.refresh()
            step = .finishing(host: host, done: 2)
            try? await Task.sleep(for: .milliseconds(400))
            step = .finishing(host: host, done: 3)
            try? await Task.sleep(for: .milliseconds(300))
            kosha.didSignIn()
            step = .idle
        } catch {
            let message = (error as? KoshaError)?.errorDescription
            step = .failed(host: host, message: message.flatMap { $0.count < 200 ? $0 : nil })
        }
    }

    public func cancel() { step = .idle }
}

/// The brand panel on the sign-in screens: peacock ground, the K-coin symbol, the wordmark and the tagline.
struct BrandPanel: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            brandImage("SymbolReversed").resizable().scaledToFit().frame(height: 56)
                .accessibilityHidden(true)
            brandImage("WordmarkReversed").resizable().scaledToFit().frame(height: 46)
                .padding(.top, 22)
                .accessibilityLabel("Kosha")
            Text(L.auth_headline_default())
                .font(.custom("Geist-Regular", size: 18, relativeTo: .title3))
                .foregroundStyle(Brand.paper.opacity(0.85))
                .padding(.top, 20)
        }
        .padding(.horizontal, 29)
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.peacock, in: UnevenRoundedRectangle(bottomLeadingRadius: 28, bottomTrailingRadius: 28))
        .ignoresSafeArea(edges: .top)
    }
}

/// SignIn and SignInError: the brand panel, Continue to sign in (or Try again), Try the demo, and own server.
public struct SignInScreen: View {
    @Environment(Kosha.self) private var kosha
    @Environment(\.webAuthenticationSession) private var session
    @Environment(\.kosha) private var theme
    @State private var flow: SignInFlow?
    @State private var ownServer = false

    public init() {}

    public var body: some View {
        let c = theme.colors
        let flow = flow ?? SignInFlow(kosha: kosha)
        Group {
            if case .finishing(let host, let done) = flow.step {
                FinishingScreen(host: host, done: done) { flow.cancel() }
            } else {
                VStack(spacing: 0) {
                    BrandPanel().frame(maxHeight: .infinity)
                    VStack(spacing: 10) {
                        if case .failed(let host, let message) = flow.step {
                            HStack(alignment: .top, spacing: 12) {
                                PhIcon("warning-circle", size: 22, color: c.bad)
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(L.app_signin_error_title()).kFont(.sans(17, .medium))
                                    Text(message ?? L.app_signin_error_body(host: host)).kFont(.body).foregroundStyle(c.ink2)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(16)
                            .background(c.surface, in: .rect(cornerRadius: 16))
                            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(c.bad.opacity(0.45)))
                            .padding(.bottom, 0)
                        }
                        let failed = if case .failed = flow.step { true } else { false }
                        KButton(failed ? L.common_try_again() : L.app_signin_continue(), icon: "arrow-square-out") {
                            Task { await flow.begin(defaultServer, session: session) }
                        }
                        .environment(\.layoutDirection, .rightToLeft)
                        KButton(L.app_signin_demo(), style: .secondary) {
                            Task { await flow.begin(defaultServer, demo: true, session: session) }
                        }
                        Text(L.app_signin_note(host: SignInFlow.host(defaultServer)))
                            .kFont(.sans(14, .regular)).foregroundStyle(c.ink3).multilineTextAlignment(.center)
                            .padding(.top, 6)
                        Button(L.app_signin_own_server()) { ownServer = true }
                            .kFont(.sans(15, .regular)).foregroundStyle(c.ink2).frame(minHeight: 44)
                            .buttonStyle(PressStyle())
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 24)
                    .padding(.bottom, 8)
                }
                .disabled(flow.step != .idle && !isFailed(flow.step))
            }
        }
        .background(c.bg)
        .onAppear { if self.flow == nil { self.flow = flow } }
        .sheet(isPresented: $ownServer) {
            OwnServerScreen(flow: flow) { ownServer = false }
                .koshaTheme(ThemeSettings(language: L.language))
        }
    }

    private func isFailed(_ s: SignInStep) -> Bool { if case .failed = s { true } else { false } }
}

/// "Your own server": the address with a live check, Continue to sign in, and "Use getkosha.app instead".
struct OwnServerScreen: View {
    let flow: SignInFlow
    let close: () -> Void
    @Environment(\.webAuthenticationSession) private var session
    @Environment(\.kosha) private var theme
    @State private var address = "https://"
    @State private var status: Status = .idle

    enum Status: Equatable { case idle, checking, found(String), invalid, notFound(String), tooOld(String) }

    var body: some View {
        let c = theme.colors
        VStack(alignment: .leading, spacing: 16) {
            ZStack {
                Text(L.app_own_title()).kFont(.sans(17, .semibold))
                HStack {
                    Button(L.common_cancel(), action: close).kFont(.sans(17, .regular)).foregroundStyle(c.ink2)
                        .frame(minHeight: 44).buttonStyle(PressStyle())
                    Spacer()
                }
            }
            Text(L.app_own_lead()).kFont(.body).foregroundStyle(c.ink2)
            VStack(alignment: .leading, spacing: 6) {
                Text(L.app_own_label()).kFont(.small).foregroundStyle(c.ink3)
                KField("https://kosha.example.com", text: $address, error: errorText)
                    .keyboard(.url)
                if case .found(let host) = status {
                    Label { Text(L.app_own_found(host: host)) } icon: { PhIcon("check-circle", size: 18, color: c.pos) }
                        .kFont(.body).foregroundStyle(c.pos)
                }
            }
            KButton(L.app_signin_continue(), icon: "arrow-square-out") {
                guard let server = Auth.normalise(address) else { return }
                close()
                Task { await flow.begin(server, session: session) }
            }
            .environment(\.layoutDirection, .rightToLeft)
            .disabled(!isFound)
            Button(L.app_own_use_default(), action: close).kFont(.sans(15, .regular)).foregroundStyle(c.ink2)
                .frame(maxWidth: .infinity, minHeight: 44).buttonStyle(PressStyle())
            Spacer()
        }
        .padding(16)
        .background(c.bg)
        .task(id: address) {
            // A live check, after a short pause in typing.
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            let raw = address.trimmingCharacters(in: .whitespaces)
            if raw.isEmpty || raw == "https://" { status = .idle; return }
            guard let server = Auth.normalise(raw), server.contains(".") || server.contains("localhost") || server.contains("127.0.0.1")
            else { status = .invalid; return }
            status = .checking
            let host = SignInFlow.host(server)
            switch await flow.check(server) {
            case .found: status = .found(host)
            case .notFound: status = .notFound(host)
            case .tooOld: status = .tooOld(host)
            }
        }
    }

    private var isFound: Bool { if case .found = status { true } else { false } }

    private var errorText: String? {
        switch status {
        case .invalid: L.app_own_invalid()
        case .notFound(let h): L.app_own_not_found(host: h)
        case .tooOld(let h): L.app_own_too_old(host: h)
        default: nil
        }
    }
}

/// "Signing you in": signed in, loading your accounts, keeping a copy for offline, and Cancel.
struct FinishingScreen: View {
    let host: String
    let done: Int
    let cancel: () -> Void
    @Environment(\.kosha) private var theme

    var body: some View {
        let c = theme.colors
        let lines = [L.app_finishing_signed_in(host: host), L.app_finishing_accounts(), L.app_finishing_offline()]
        VStack(spacing: 0) {
            Spacer()
            brandImage("Symbol").resizable().scaledToFit().frame(height: 56).accessibilityHidden(true)
            Text(L.app_finishing_title()).kFont(.title).padding(.top, 24).accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 14) {
                ForEach(lines.indices, id: \.self) { i in
                    HStack(spacing: 12) {
                        Group {
                            if i < done {
                                PhIcon("check-circle", size: 18, color: c.pos)
                            } else if i == done {
                                ProgressView().controlSize(.small).tint(c.brand)
                            } else {
                                Circle().strokeBorder(c.line, lineWidth: 1.5).frame(width: 16, height: 16)
                            }
                        }
                        .frame(width: 20)
                        Text(lines[i]).kFont(.body).foregroundStyle(i == done ? c.ink : c.ink2)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(16)
            .background(c.surface, in: .rect(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(c.line))
            .padding(.horizontal, 30)
            .padding(.top, 20)
            Spacer()
            KButton(L.common_cancel(), style: .secondary, action: cancel).padding(16)
        }
        .background(c.bg)
    }
}

/// Launch: peacock ground, the K-coin symbol in the middle and the wordmark below, while the session and cache load.
public struct LaunchScreen: View {
    public init() {}
    public var body: some View {
        ZStack {
            Brand.peacock.ignoresSafeArea()
            brandImage("SymbolReversed").resizable().scaledToFit().frame(height: 84)
            VStack {
                Spacer()
                brandImage("WordmarkReversed").resizable().scaledToFit().frame(height: 20).opacity(0.7)
                    .padding(.bottom, 56)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Kosha")
    }
}
