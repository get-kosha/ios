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
    /// Welcome's Skip: an account may stay without accounts and still reach the tabs.
    @AppStorage(welcomeDoneKey) private var welcomeDone = false
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
            .preferredColorScheme(scheme)
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
                    Task {
                        await kosha.refresh()
                        await kosha.updateWidget(language: L.language)
                    }
                default: break
                }
            }
            .onChange(of: kosha.signedIn) { _, signedIn in
                if !signedIn { welcomeDone = false }
            }
            .onChange(of: kosha.rejected) { _, r in
                if let first = r.first {
                    toasts.show(first, warning: true)
                    kosha.rejected.removeAll()
                }
            }
            .onOpenURL { open($0) }
            .onChange(of: AppActions.shared.pending) { _, url in
                if let url {
                    AppActions.shared.pending = nil
                    open(url)
                }
            }
            .task {
                #if DEBUG
                if let server = Tour.server { await Tour.signIn(server, kosha: kosha) }
                #endif
                await kosha.refresh()
                launching = false
                #if DEBUG
                if let screen = Tour.screen {
                    try? await Task.sleep(for: .milliseconds(300))
                    Tour.open(screen, kosha: kosha, nav: nav)
                }
                #endif
                await kosha.updateWidget(language: L.language)
            }
    }

    /// Deep links from the widget, Home Screen quick actions and App Shortcuts: app.getkosha://add?kind=income&scan=1.
    /// The sign-in fallback (app.getkosha:/oauth/callback) is handled by its web authentication session, not here.
    private func open(_ url: URL) {
        // A statement shared to Kosha ("Open in Kosha"): CSV, OFX, QFX or PDF goes to Import.
        if url.isFileURL {
            guard kosha.signedIn else { return }
            ImportInbox.shared.put([url])
            nav.tab = .accounts
            nav.push(.importStatements)
            return
        }
        guard url.scheme == "app.getkosha", url.host == "add", kosha.signedIn else { return }
        let q = Dictionary(
            (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { a, _ in a }
        )
        nav.openAdd(AddRequest(kind: q["kind"].flatMap(EntryKind.init(rawValue:)), scan: q["scan"] == "1"))
    }

    private var scheme: ColorScheme? {
        #if DEBUG
        if let dark = Tour.dark { return dark ? .dark : .light }
        #endif
        return preferredScheme(kosha)
    }

    @ViewBuilder
    private var content: some View {
        if !kosha.signedIn {
            SignInScreen()
        } else if kosha.meta == nil && launching {
            LaunchScreen()
        } else if lock.locked {
            LockScreen(lock: lock)
        } else if let m = kosha.meta, m.wallets.isEmpty, !m.demo, !welcomeDone {
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
    @Environment(\.horizontalSizeClass) private var width
    @State private var visited: Set<MainTab> = [.overview]

    var body: some View {
        @Bindable var nav = nav
        Group {
            if width == .regular {
                // iPad: a sidebar with the four tabs and Add, like the web's desktop layout; the tab is the detail.
                NavigationSplitView {
                    Sidebar()
                } detail: {
                    stacks
                }
                .navigationSplitViewStyle(.balanced)
            } else {
                RootTabs(tab: $nav.tab, showBar: (nav.paths[nav.tab] ?? []).isEmpty, onAdd: { nav.openAdd() }) { _ in stacks }
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

    private var stacks: some View {
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
        .background(theme.colors.bg)
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

/// The iPad sidebar: the wordmark, Add, and the four tabs with their icons (fill in the selection colour when picked).
struct Sidebar: View {
    @Environment(Navigator.self) private var nav
    @Environment(\.kosha) private var theme

    var body: some View {
        let c = theme.colors
        VStack(alignment: .leading, spacing: 4) {
            Wordmark(size: 28, color: c.ink)
                .padding(.horizontal, 12).padding(.bottom, 16)
            KButton(L.shell_add_transaction(), size: .medium, icon: "plus") { nav.openAdd() }
                .padding(.bottom, 12)
            ForEach(MainTab.allCases, id: \.self) { tab in
                let on = tab == nav.tab
                Button { nav.tab = tab } label: {
                    HStack(spacing: 12) {
                        PhIcon(tab.icon, size: 22, fill: on, color: on ? c.selection : c.ink2)
                        Text(tab.label).kFont(on ? .head : .body).foregroundStyle(on ? c.ink : c.ink2)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .background(on ? c.sel : .clear, in: .rect(cornerRadius: 10))
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
            }
            Spacer()
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(c.surface)
        .hideNavigationBar()
    }
}
