import SwiftUI
import AuthenticationServices
import Model
import Store
import Design

/// The screen each route shows. Each feature folder defines its screens; this only maps routes to them.
@MainActor @ViewBuilder
func destination(_ route: Route) -> some View {
    switch route {
    case .tagView(let tag, let eventId): TagViewScreen(tag: tag, eventId: eventId)
    case .txDetail(let id): TxDetailScreen(id: id)
    case .transferDetail(let id): TransferDetailScreen(id: id)
    case .recurringDetail(let id): RecurringDetailScreen(id: id)
    case .recurringForm(let id, let payee, let tx): RecurringFormScreen(id: id, fromPayee: payee, fromTransaction: tx)
    case .accountDetail(let id): AccountDetailScreen(id: id)
    case .investmentDetail(let id): InvestmentDetailScreen(id: id)
    case .accountForm(let id): AccountFormScreen(id: id)
    case .fixBalance(let id): FixBalanceScreen(id: id)
    case .exchanges: ExchangesScreen()
    case .reconcile(let accountId): ReconcileScreen(accountId: accountId)
    case .importStatements: ImportScreen()
    case .ask(let q): AskScreen(question: q)
    case .settings(let page, let id): SettingsScreen(page: page, id: id)
    case .welcome: WelcomeFlow()
    }
}

/// The app: Launch while a signed-in session has nothing saved yet, SignIn when signed out, the lock, Welcome for an
/// account without accounts, then the tabs. It owns the session, navigation and toasts, applies the account's
/// appearance, and covers the content in the app switcher.
public struct KoshaRoot: View {
    @State private var kosha: Kosha
    @State private var nav = Navigator()
    @State private var toasts = Toasts()
    @State private var lock: AppLock
    @State private var launching = true
    @Environment(\.scenePhase) private var phase

    public init(kosha: Kosha) {
        _kosha = State(initialValue: kosha)
        _lock = State(initialValue: AppLock(kosha: kosha))
    }

    public var body: some View {
        let settings = themeSettings(kosha)
        let _ = L.use(language: settings.language)
        let _ = { Kosha.requestLanguage = settings.language }()
        content
            .koshaTheme(settings)
            .preferredColorScheme(preferredScheme(kosha))
            .environment(kosha)
            .environment(nav)
            .environment(toasts)
            .toasts(toasts)
            .overlay {
                // The app switcher shows the brand ground while the app isn't active and the lock is on.
                if phase != .active && kosha.local.lock && kosha.signedIn { PrivacyCover().koshaTheme(settings) }
            }
            .onChange(of: phase) { _, p in
                switch p {
                case .background:
                    lock.backgrounded()
                    kosha.sendOutbox()
                case .active:
                    lock.foregrounded()
                    Task { await kosha.refresh() }
                default: break
                }
            }
            .onChange(of: kosha.rejected) { _, r in
                if let first = r.first {
                    toasts.show(first, warning: true)
                    kosha.rejected.removeAll()
                }
            }
            .task {
                await kosha.refresh()
                launching = false
            }
    }

    @ViewBuilder
    private var content: some View {
        if !kosha.signedIn {
            SignInScreen()
        } else if kosha.meta == nil && launching {
            LaunchScreen()
        } else if lock.locked {
            LockScreen(lock: lock)
        } else if let m = kosha.meta, m.wallets.isEmpty, !m.demo {
            NavigationStack { WelcomeFlow() }
        } else {
            MainTabs()
        }
    }
}

/// The four tabs, each with its own navigation stack, under Kosha's tab bar, with Add over them. A tab's screen is
/// made the first time it's opened and kept, so each tab keeps its place.
struct MainTabs: View {
    @Environment(Navigator.self) private var nav
    @Environment(\.kosha) private var theme
    @Environment(\.webAuthenticationSession) private var web
    @State private var visited: Set<MainTab> = [.overview]

    var body: some View {
        @Bindable var nav = nav
        RootTabs(tab: $nav.tab, onAdd: { nav.openAdd() }) { _ in
            ZStack {
                ForEach(MainTab.allCases, id: \.self) { tab in
                    if visited.contains(tab) {
                        NavigationStack(path: nav.path(tab)) {
                            screen(tab).navigationDestination(for: Route.self) { destination($0) }
                        }
                        .opacity(tab == nav.tab ? 1 : 0)
                        .allowsHitTesting(tab == nav.tab)
                        .accessibilityHidden(tab != nav.tab)
                    }
                }
            }
        }
        .onChange(of: nav.tab) { _, t in visited.insert(t) }
        .fullScreen(item: $nav.add) { request in
            AddScreen(request: request)
        }
        .onAppear {
            // Pages on the user's server that the app hands off ("Opens getkosha.app and brings you back"). The shared
            // browser session keeps the user signed in there.
            nav.openWeb = { url in
                Task {
                    _ = try? await web.authenticate(
                        using: url, callback: .customScheme("app.getkosha"), preferredBrowserSession: .shared,
                        additionalHeaderFields: [:]
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func screen(_ tab: MainTab) -> some View {
        switch tab {
        case .overview: OverviewScreen()
        case .activity: ActivityScreen()
        case .recurring: RecurringScreen()
        case .accounts: AccountsScreen()
        }
    }
}
