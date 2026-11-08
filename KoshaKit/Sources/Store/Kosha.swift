import Foundation
import Network
import Observation
import Model
import API

/// A read for a screen: what this phone saved, then what the server says.
public struct Loaded<T: Sendable>: Sendable {
    public var value: T?
    /// Still checking with the server.
    public var refreshing: Bool
    /// The server couldn't be reached, so `value` is what this phone saved.
    public var offline = false
    /// The server's message when it refused the read.
    public var error: String?

    public init(value: T? = nil, refreshing: Bool = true, offline: Bool = false, error: String? = nil) {
        self.value = value
        self.refreshing = refreshing
        self.offline = offline
        self.error = error
    }
}

/// The app's one session and shared state: the API client, the cache, the outbox, the signed-in account's meta and
/// settings, and the month and display currency that Overview, Activity and Recurring share. Screens read it from the
/// environment. Ported from the Android app's Kosha.kt.
@MainActor @Observable
public final class Kosha {
    public let tokens: TokenStore
    public let auth: Auth
    public let api: KoshaAPI
    public let cache: Cache
    public let local: LocalPrefs
    @ObservationIgnored public private(set) var outbox: Outbox!

    public private(set) var signedIn: Bool
    public private(set) var online = true
    /// Accounts, categories, rules, events, tags, rates, preferences and which AI features are live.
    public private(set) var meta: Meta?
    public private(set) var settings: Settings?
    /// New entries waiting for a connection.
    public private(set) var waiting: [Queued] = []
    /// The month Overview, Activity and Recurring show.
    public var month: Month
    /// The currency totals show in; nil means the main currency.
    public var currency: String?
    /// Bumped after every change, so screens that read through `load` fetch again.
    public private(set) var version = 0
    /// Messages for entries the server refused when the outbox was sent; the shell shows them as toasts.
    public var rejected: [String] = []

    /// Called when the outbox has entries and the connection is back or the app goes to the background; the app
    /// schedules a background task there.
    @ObservationIgnored public var scheduleSend: (() -> Void)?
    /// Called after the widget's snapshot changes; the app reloads the widget's timelines there.
    @ObservationIgnored public var widgetChanged: (() -> Void)?
    @ObservationIgnored private let monitor = NWPathMonitor()

    /// The language for requests: the `language` setting, else the phone's. Set by the app.
    nonisolated(unsafe) public static var requestLanguage = "en"

    public init(accessGroup: String? = nil) {
        let tokens = TokenStore(accessGroup: accessGroup)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 90 // AI replies and statement reads take a while
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)
        // One Auth for sign-in and the API, so refreshes are serialised in one place.
        let auth = Auth(store: tokens, session: session)
        self.tokens = tokens
        self.auth = auth
        api = KoshaAPI(store: tokens, auth: auth, session: session) { Kosha.requestLanguage }
        cache = Cache()
        local = LocalPrefs()
        signedIn = tokens.read() != nil
        let saved: Meta? = cache.read("meta")
        meta = saved
        settings = cache.read("settings")
        month = Dates.month(saved?.timeZone ?? TimeZone.current.identifier)
        outbox = Outbox(api: api) { items in Task { @MainActor [weak self] in self?.waiting = items } }
        Task { self.waiting = await self.outbox.items }
        monitor.pathUpdateHandler = { path in
            let up = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                let was = self.online
                self.online = up
                if up && !was { self.sendOutbox() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "app.getkosha.network"))
    }

    public var tz: String { meta?.timeZone ?? "UTC" }
    public var demo: Bool { meta?.demo ?? false }
    public var primary: String { meta?.primaryCurrency ?? "eur" }
    /// The currency totals show in.
    public var display: String { currency ?? primary }
    public var today: Day { Dates.today(tz) }
    public var server: String? { tokens.read()?.server }

    /// After a sign-in: remember the session and load the account.
    public func didSignIn() {
        signedIn = true
        Task { await refresh() }
    }

    /// Fetches meta and settings again. Called on launch, on resume and after changes.
    public func refresh() async {
        guard signedIn else { return }
        do {
            let m: Meta = try await api.get("/api/app/meta")
            cache.write("meta", m)
            if meta == nil { month = Dates.month(m.timeZone) }
            meta = m
            let s: Settings = try await api.get("/api/v1/settings")
            cache.write("settings", s)
            settings = s
        } catch KoshaError.signedOut {
            signedOutLocally()
        } catch {
            // Offline or refused: keep what this phone saved.
        }
        sendOutbox()
    }

    /// Call after a write: screens read again, and meta (balances, tags, rules) refreshes.
    public func changed() {
        version += 1
        Task { await refresh() }
    }

    /// A read that shows what this phone saved first, then the server's answer, cached under `key`. Offline, it stays
    /// on the saved answer and says so.
    public func load<T: Codable & Sendable>(
        _ key: String, into update: @MainActor (Loaded<T>) -> Void, fetch: @Sendable (KoshaAPI) async throws -> T
    ) async {
        let saved: T? = cache.read(key)
        update(Loaded(value: saved, refreshing: true))
        do {
            let fresh = try await fetch(api)
            cache.write(key, fresh)
            update(Loaded(value: fresh, refreshing: false))
        } catch KoshaError.signedOut {
            signedOutLocally()
            update(Loaded(value: saved, refreshing: false))
        } catch let e as KoshaError {
            if case .api = e {
                update(Loaded(value: saved, refreshing: false, error: e.errorDescription))
            } else {
                update(Loaded(value: saved, refreshing: false, offline: true))
            }
        } catch is CancellationError {
            update(Loaded(value: saved, refreshing: false))
        } catch {
            // An answer this version can't read (a newer or older server): keep what was saved, and say so.
            update(Loaded(value: saved, refreshing: false, error: String(describing: error).prefix(200).description))
        }
    }

    /// Saves a synced preference (PATCH /api/app/preferences) and applies it at once.
    public func setPreference(_ key: String, _ value: String?) {
        guard var m = meta else { return }
        m.prefs[key] = value.map(JSONValue.string) ?? .null
        meta = m
        Task {
            try? await api.send("PATCH", "/api/app/preferences", body: JSONValue.object([key: value.map(JSONValue.string) ?? .null]))
            changed()
        }
    }

    /// Sends the outbox now if there is a connection; otherwise asks the app to schedule a background send.
    public func sendOutbox() {
        guard !waiting.isEmpty || signedIn else { return }
        Task {
            guard await !outbox.items.isEmpty else { return }
            if !online {
                scheduleSend?()
                return
            }
            let (sent, refused) = await outbox.send()
            if !refused.isEmpty { rejected += refused }
            if sent > 0 { changed() }
            if await !outbox.items.isEmpty { scheduleSend?() }
        }
    }

    /// Signs out: revokes the refresh token, then clears what this phone saved and the outbox.
    public func signOut() async {
        await auth.signOut()
        signedOutLocally()
    }

    private func signedOutLocally() {
        tokens.clear()
        cache.clear()
        local.clear()
        Task { await outbox.clear() }
        meta = nil
        settings = nil
        currency = nil
        signedIn = false
    }
}
