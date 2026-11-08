import Foundation
import Model
import API

/// A new entry waiting for a connection. Lists show it with a "waiting" mark. `noEvent`: "No event" was picked.
public struct Queued: Codable, Sendable, Hashable, Identifiable {
    public var entry: NewTransaction
    public var currency: String
    public var accountName: String
    public var categoryName: String
    public var noEvent: Bool
    public var id: String { entry.id }

    public init(entry: NewTransaction, currency: String, accountName: String, categoryName: String, noEvent: Bool = false) {
        self.entry = entry
        self.currency = currency
        self.accountName = accountName
        self.categoryName = categoryName
        self.noEvent = noEvent
    }
}

/// The body of create_transactions for one new entry. The server tells a retry from a reused id by this body, so the
/// queue stores the entry as first built (its time fixed, or left out for the server) and sends the same body again.
/// "No event" goes as an explicit `eventId: null`; left out, the server picks the event by date.
public func createTransactions(_ entry: NewTransaction, noEvent: Bool) -> JSONValue {
    var tx = (try? KoshaJSON.decode(JSONValue.self, KoshaJSON.encode(entry)))?.object ?? [:]
    if noEvent { tx["eventId"] = .null }
    return .object(["transactions": .array([.object(tx)])])
}

/// New transactions added without a connection, as on the web (src/lib/offline.ts). Only new entries queue; edits,
/// transfers and deletes need a connection. Each carries its own id, so one the server saved before the reply was lost
/// isn't saved twice. Entries go in the order they were added; one the server rejects (say, its account was deleted
/// meanwhile) is dropped and its message returned.
public actor Outbox {
    private let file: URL
    private let api: KoshaAPI
    public private(set) var items: [Queued]
    private let onChange: @Sendable ([Queued]) -> Void

    public init(api: KoshaAPI, file: URL? = nil, onChange: @escaping @Sendable ([Queued]) -> Void) {
        let url = file ?? Cache.container.appendingPathComponent("outbox.json")
        self.file = url
        self.api = api
        self.onChange = onChange
        items = (try? Data(contentsOf: url)).flatMap { try? KoshaJSON.decode([Queued].self, $0) } ?? []
    }

    private func save(_ list: [Queued]) {
        items = list
        if let data = try? KoshaJSON.encode(list) {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        onChange(list)
    }

    public func add(_ item: Queued) { save(items + [item]) }

    /// Undo for an entry that hasn't been sent yet.
    public func remove(_ id: String) { save(items.filter { $0.id != id }) }

    /// Sends what's waiting. Returns how many were sent and the server's message for each one it refused for good;
    /// stops at the first sign of no connection, or when the server is busy or failing.
    public func send() async -> (sent: Int, rejected: [String]) {
        var sent = 0
        var rejected: [String] = []
        for item in items {
            do {
                try await api.send("POST", "/api/v1/transactions", body: createTransactions(item.entry, noEvent: item.noEvent))
                sent += 1
            } catch let e as KoshaError {
                // Offline, busy or failing: keep it for the next try; its id makes a repeat save once.
                if e.retryable { return (sent, rejected) }
                if case .signedOut = e { return (sent, rejected) }
                // 409: the id is taken by other details. Only this phone makes its ids, so an earlier try was saved and
                // its reply lost: if the entry is there, it was sent (the server's version stands).
                if case .api(409, _) = e {
                    do {
                        _ = try await api.bytes("/api/app/transactions/\(item.entry.id)")
                        sent += 1
                    } catch let e2 as KoshaError where e2.retryable {
                        return (sent, rejected)
                    } catch {
                        rejected.append(e.errorDescription ?? "")
                    }
                } else {
                    // Refused for good (400, 404); a 403 means read-only: keep nothing either.
                    rejected.append(e.errorDescription ?? "")
                }
            } catch {
                return (sent, rejected)
            }
            save(items.filter { $0.id != item.id })
        }
        return (sent, rejected)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: file)
        items = []
        onChange([])
    }
}
