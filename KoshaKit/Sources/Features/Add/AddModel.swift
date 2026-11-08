import SwiftUI
import Model
import API
import Store
import Design

enum AddSheet: String, Identifiable {
    case account, to, date, note, category, fee, describe, repeating
    var id: String { rawValue }
}

/// Where AI filled the form from.
enum Filled { case text, receipt }

/// A file to attach once the entry is saved.
struct Staged: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let type: String
    let data: Data
}

/// The largest file Kosha stores (core.ts ATTACHMENT_LIMIT).
let attachmentLimit = 10 * 1024 * 1024

// MARK: Request and reply shapes beyond Model (api-contract.ts), with only the fields Add needs.

private struct DeleteIds: Encodable { let ids: [String] }

private struct NewTransfer: Encodable {
    let fromAccountId, toAccountId: String
    let sent, received, fee: Int64
    let provider, day: String
    let time: String?
    let note: String
}

private struct NewTransfers: Encodable { let transfers: [NewTransfer] }
struct SavedTransfer: Decodable, Sendable { let id, day, fromAccountId: String }
private struct SavedTransfers: Decodable { let transfers: [SavedTransfer] }

private struct CategoryAsk: Encodable { let payee, kind: String }
private struct CategoryGuess: Decodable { let categoryId: String? }

private struct ReadAsk: Encodable {
    struct Photo: Encodable { let data: String; let mimeType: String }
    var text: String?
    var photo: Photo?
    var accountId: String?
    var save = false
}

/// What AI read. Amounts are signed minor units in the account's currency; fields it couldn't read are nil.
struct ReadEntry: Decodable, Sendable {
    @D var payee: String
    var amount: Int64?
    var accountId: String?
    var categoryId: String?
    var day: String?
    var time: String?
    @D var note: String
    @D var tags: [String]
}

private struct ReadReply: Decodable { let entry: ReadEntry }
private struct NewEvent: Encodable { let name: String; let startDay: String? }
private struct SavedEvent: Decodable { let id: String }
private struct IdReply: Decodable { let id: String }
private struct PaymentReply: Decodable {
    struct P: Decodable { let transactionId: String? }
    let payment: P?
}

/// A payee known only by name, as this phone saved it offline.
private func payeeNamed(_ name: String) -> Payee? {
    try? KoshaJSON.decode(Payee.self, KoshaJSON.encode(JSONValue.object(["payee": .string(name)])))
}

/// Auto-categorise answers per kind and payee, for as long as the app runs (ai.tsx guesses).
@MainActor private var aiGuesses: [String: String?] = [:]

/// Everything the Add screen holds, as on the web's phone add (phone-add.tsx) and the Android app's AddModel: the
/// amount as keypad input, the kind, account, category (picked, or guessed from history, rules or AI), day and time,
/// repeat, note, tags, event, files, and the transfer's other account and fee.
@MainActor @Observable
final class AddModel {
    let kosha: Kosha
    let toasts: Toasts
    let nav: Navigator

    var kind: EntryKind
    var input = ""
    private(set) var payee = ""
    /// Payees matching what's typed, most used first.
    private(set) var suggestions: [Payee] = []
    private var picked: Payee?

    /// The category picked (always a top-level one) and its subcategory. Nil until the person picks.
    private(set) var categoryId: String?
    private(set) var subcategoryId: String?
    /// The category AI read from a sentence or receipt: a guess until confirmed.
    private var aiCategoryId: String?

    private(set) var accountId: String?
    /// The account came from the payee's history or AI, not from the person.
    private(set) var accountGuessed = false
    private var accountPicked = false
    var toAccountId: String?

    var day: Day
    /// Nil until changed: then today's entries get the moment they're saved, as on the web.
    var time: String?
    /// Set from the Repeat tile: the entry becomes a bill, subscription, recurring income or recurring transfer.
    var repeating: Repeat?
    var note = ""
    var tags: [String] = []
    /// Until an event is picked, the entry joins the event its day falls in.
    private(set) var eventPicked = false
    private var eventChoice: String?
    /// An event made here, until meta brings it back.
    private(set) var newEvent: Event?
    var files: [Staged] = []
    var fee = FeeInput()

    var sheet: AddSheet?
    /// The category sheet was opened by Next: picking a tile saves.
    var viaNext = false
    private(set) var filled: Filled?
    private(set) var receipt: Data?
    private(set) var reading: Filled?
    private(set) var payeeByAi = false
    private(set) var savedOnce = false
    var camera = false
    var described = ""
    private(set) var saving = false
    /// Bumped after each save, for the success haptic.
    private(set) var saves = 0

    private var searchTask: Task<Void, Never>?
    private var aiTask: Task<Void, Never>?

    init(request: AddRequest, kosha: Kosha, toasts: Toasts, nav: Navigator) {
        self.kosha = kosha
        self.toasts = toasts
        self.nav = nav
        let meta = kosha.meta
        let pref = meta?.pref("add_kind", "expense") ?? "expense"
        kind = request.kind ?? (pref == "income" ? .income : .expense)
        day = kosha.today
        accountId = startAccount(meta?.pref("default_wallet", "last") ?? "last", active: kosha.activeWallets, last: kosha.local.lastAccount)
        // A card's Pay and other prefills: the accounts and the amount.
        if let from = request.fromAccount, kosha.activeWallets.contains(where: { $0.id == from }) {
            accountId = from
            accountPicked = true
        }
        if let to = request.toAccount {
            kind = .transfer
            toAccountId = to
            if request.fromAccount == nil, accountId == to {
                accountId = kosha.activeWallets.first { $0.id != to && $0.kind != .credit }?.id
            }
        }
        if let amount = request.amount, amount != 0 { input = keypadInput(abs(amount), decimals: Money.decimals(currency)) }
        let ai = meta?.aiFlags ?? AiFlags()
        camera = request.scan && ai.receipts
        if request.describe && ai.quickAdd { sheet = .describe }
        if let id = request.duplicateOf { Task { await duplicate(id) } }
    }

    // MARK: What the form shows

    var meta: Meta? { kosha.meta }
    var today: Day { kosha.today }
    var active: [Wallet] { kosha.activeWallets }
    var account: Wallet? { active.first { $0.id == accountId } ?? active.first }
    var toAccount: Wallet? { active.first { $0.id == toAccountId && $0.id != account?.id } }
    var primary: String { kosha.primary }
    var currency: String { account?.currency ?? primary }
    var decimals: Int { Money.decimals(currency) }
    /// The amount to save, positive minor units, or nil while it isn't above zero.
    var minor: Int64? { Keypad.minorUnits(input, decimals: decimals) }
    var transfer: Bool { kind == .transfer }

    /// Categories the kind can take: not archived, not Kosha's own, income or spending to match.
    var candidates: [MetaCategory] { kosha.pickable(income: kind == .income) }
    var tops: [MetaCategory] {
        let all = candidates
        return all.filter { c in c.parentId == nil || !all.contains { $0.id == c.parentId } }
    }

    /// The payee as Kosha knows it: the suggestion picked, or one whose name is exactly what's typed.
    var match: Payee? {
        picked ?? suggestions.first { $0.payee.caseInsensitiveCompare(payee.trimmingCharacters(in: .whitespaces)) == .orderedSame }
    }

    private var guessing: Bool { meta?.pref("suggest_category", "1") == "1" }
    private func fits(_ id: String?) -> Bool { id != nil && tops.contains { $0.id == id } }

    /// The category history gives: the payee's last one, else the payee rules (phone-add.tsx fromHistory).
    var fromHistory: String? {
        guard guessing else { return nil }
        if let c = match?.categoryId, fits(c) { return c }
        let rule = guessCategory(payee, meta?.payeeMatches ?? [])
        return fits(rule) ? rule : nil
    }

    /// AI's guess: what it read from a sentence or receipt, or auto-categorise for a payee Kosha hasn't seen.
    private var aiGuess: String? {
        guard guessing else { return nil }
        return [aiCategoryId, aiGuesses[aiKey(payee)] ?? nil].first { fits($0) } ?? nil
    }

    /// The category this entry gets: picked, else guessed.
    var chosen: String? { fits(categoryId) ? categoryId : fromHistory ?? aiGuess }
    var chosenIsAi: Bool { categoryId == nil && fromHistory == nil && chosen != nil }
    /// What the category tile names: the subcategory when one is picked.
    var chosenCategory: MetaCategory? { kosha.category(categoryId != nil ? subcategoryId ?? chosen : chosen) }

    var needsCategory: Bool { !transfer && chosen == nil }
    var ready: Bool { minor != nil && !needsCategory }

    var eventId: String? { eventPicked ? eventChoice : eventFor(day.text, meta?.events ?? []) }
    var event: Event? {
        guard let id = eventId else { return nil }
        return meta?.events.first { $0.id == id } ?? (newEvent?.id == id ? newEvent : nil)
    }

    var sides: TransferSides {
        transferSides(sent: minor ?? 0, fee, from: currency, to: toAccount?.currency, fromDecimals: decimals,
                      toDecimals: Money.decimals(toAccount?.currency ?? currency), perUsd: meta?.rates ?? [:])
    }

    /// The amount in the main currency, for the hint under it, when the account's currency differs.
    var converted: Int64? {
        guard let m = minor, !transfer, currency != primary else { return nil }
        return convert(m, from: currency, to: primary, perUsd: meta?.rates ?? [:])
    }

    // MARK: Changes

    func pickKind(_ k: EntryKind) {
        guard k != kind else { return }
        kind = k
        // A category only fits one kind, so switching starts the pick again.
        categoryId = nil
        subcategoryId = nil
        askAi()
    }

    func typePayee(_ text: String) {
        payee = text
        payeeByAi = false
        if picked?.payee != text { picked = nil }
        // A category read with an earlier payee doesn't speak for the new one.
        aiCategoryId = nil
        searchTask?.cancel()
        let q = text.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            suggestions = []
        } else {
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                do {
                    let found: Payees = try await kosha.api.get("/api/v1/payees", query: ["query": q, "limit": "5"])
                    if !Task.isCancelled { suggestions = found.payees }
                } catch KoshaError.offline {
                    // Offline: the payee names this phone saved, without their history.
                    suggestions = (meta?.titles ?? []).filter { $0.localizedCaseInsensitiveContains(q) }.prefix(5)
                        .compactMap(payeeNamed)
                } catch {
                    if !Task.isCancelled { suggestions = [] }
                }
            }
        }
        askAi()
    }

    /// Picking a suggestion fills the guesses: its category and its account, in ink2 until confirmed.
    func pickPayee(_ p: Payee) {
        payee = p.payee
        picked = p
        payeeByAi = false
        aiCategoryId = nil
        suggestions = []
        if let usual = active.first(where: { $0.id == p.accountId }), !accountPicked, usual.id != account?.id {
            accountId = usual.id
            accountGuessed = true
        }
        askAi()
    }

    func pickAccount(_ id: String, to: Bool) {
        if to {
            toAccountId = id
        } else {
            if toAccountId == id { toAccountId = account?.id }
            accountId = id
            accountPicked = true
            accountGuessed = false
        }
        sheet = nil
    }

    func swap() {
        guard let from = account, let to = toAccount else { return }
        accountId = to.id
        toAccountId = from.id
        accountPicked = true
        fee = FeeInput(provider: fee.provider)
    }

    func pickCategory(_ top: String, _ sub: String?) {
        categoryId = top
        subcategoryId = sub
        sheet = nil
    }

    func pickEvent(_ id: String?) {
        eventPicked = true
        eventChoice = id
    }

    /// Auto-categorise, asked once per payee and kind, only for a payee history and rules can't place, after typing
    /// pauses (ai.tsx useAiCategory). AI spends the person's tokens, so nothing is asked speculatively per keystroke.
    private func askAi() {
        aiTask?.cancel()
        aiTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            let name = payee.trimmingCharacters(in: .whitespaces)
            let key = aiKey(name)
            guard meta?.aiFlags.categorise == true, !transfer, name.count >= 3, categoryId == nil, aiCategoryId == nil,
                  fromHistory == nil, aiGuesses[key] == nil else { return }
            // A failure (offline, a bad key) isn't remembered, so the same payee can ask again later.
            if let guess: CategoryGuess = try? await kosha.api.post(
                "/api/app/ai/category", CategoryAsk(payee: name, kind: kind == .income ? "income" : "expense")
            ) {
                aiGuesses[key] = .some(guess.categoryId)
            }
        }
    }

    private func aiKey(_ name: String) -> String {
        "\(kind == .income ? "income" : "expense"):\(name.trimmingCharacters(in: .whitespaces).lowercased())"
    }

    // MARK: Saving

    /// The primary button's words: Next when Kosha can't guess a category, Add bill or subscription (or recurring
    /// income or transfer) with Repeat on, else Add expense, income or transfer. Never the amount.
    var primaryLabel: String {
        if needsCategory { return L.app_next() }
        if let r = repeating {
            switch kind {
            case .income: return L.app_ios_add_recurring_income()
            case .transfer: return L.app_ios_add_recurring_transfer()
            case .expense: return r.kind == "subscription" ? L.subs_add_subscription() : L.subs_add_bill()
            }
        }
        switch kind {
        case .income: return L.add_add_income()
        case .transfer: return L.add_add_transfer()
        case .expense: return L.add_add_expense()
        }
    }

    /// A refused save or read: the warning haptic and the message.
    private func error(_ message: String) { toasts.show(message, warning: true) }

    private func message(_ e: Error, fallback: String) -> String {
        if case KoshaError.api(_, let err) = e, !err.message.isEmpty { return err.message }
        if case KoshaError.offline = e { return L.auth_error_offline() }
        return fallback
    }

    private func close() { nav.add = nil }

    /// The primary button: Next opens the category sheet when Kosha can't guess one; otherwise it adds and closes.
    func tapPrimary() {
        guard minor != nil else { return }
        if needsCategory {
            viaNext = true
            sheet = .category
            return
        }
        save(again: false)
    }

    /// Saves the entry. `again` keeps Add open with the account and date (Add another); otherwise Add closes. A category
    /// picked after Next comes in `top` and `sub`.
    func save(again: Bool, top: String? = nil, sub: String? = nil) {
        guard !saving else { return }
        guard let amount = minor else { return error(L.add_error_amount()) }
        guard let from = account else { return error(L.add_error_no_account()) }
        if kosha.demo { return error(L.common_demo_read_only()) }
        if transfer {
            if let r = repeating { return saveRecurring(again: again, amount: amount, from: from, r: r, cat: nil, sub: nil) }
            return saveTransfer(again: again, sent: amount, from: from)
        }
        guard let cat = top ?? chosen else { return error(L.add_error_category()) }
        let subId = top != nil ? sub : (categoryId == cat ? subcategoryId : nil)
        if let r = repeating { return saveRecurring(again: again, amount: amount, from: from, r: r, cat: cat, sub: subId) }
        let signed = kind == .income ? amount : -amount
        let catName = kosha.category(subId ?? cat)?.name ?? ""
        let entry = NewTransaction(
            accountId: from.id, payee: payee.trimmingCharacters(in: .whitespaces), amount: signed, categoryId: cat,
            subcategoryId: subId, day: day.text, time: time ?? (day != today ? Dates.time(kosha.tz) : nil),
            note: note.trimmingCharacters(in: .whitespacesAndNewlines), tags: tags, eventId: eventId
        )
        let staged = files
        let noEvent = eventPicked && eventChoice == nil
        saving = true
        sheet = nil
        Task {
            var queued = false
            do {
                try await kosha.api.send("POST", "/api/v1/transactions", body: createTransactions(entry, noEvent: noEvent))
            } catch let e as KoshaError where e.retryable {
                // Offline, or the server busy or failing: only new entries queue, each with its id, so a retry is
                // saved once.
                await kosha.outbox.add(Queued(entry: entry, currency: from.currency, accountName: from.name,
                                              categoryName: catName, noEvent: noEvent))
                kosha.sendOutbox()
                queued = true
            } catch {
                saving = false
                return self.error(message(error, fallback: L.add_error_add()))
            }
            saving = false
            saves += 1
            kosha.local.lastAccount = from.id
            let shown = Money.format(signed, from.currency, Money.locale(L.language), sign: .always)
            let name = entry.payee.isEmpty ? catName : entry.payee
            let text = queued
                ? L.add_toast_saved_offline(amount: shown, name: name) + (staged.isEmpty ? "" : " " + L.add_toast_offline_files())
                : L.add_toast_added(amount: shown, name: name)
            let kosha = self.kosha
            let toasts = self.toasts
            toasts.show(text) {
                Task {
                    if queued {
                        await kosha.outbox.remove(entry.id)
                    } else {
                        do { try await kosha.api.send("POST", "/api/v1/transactions/delete", body: DeleteIds(ids: [entry.id])) } catch {
                            toasts.show(L.tx_delete_failed(), warning: true)
                        }
                    }
                    kosha.changed()
                }
            }
            if !queued {
                kosha.changed()
                if !staged.isEmpty && meta?.attachments == true { upload(entry.id, staged) }
            }
            if again { next() } else { close() }
        }
    }

    /// Files go up after the entry is saved, and keep going once Add has closed.
    private func upload(_ id: String, _ staged: [Staged]) {
        let kosha = self.kosha
        let toasts = self.toasts
        Task {
            for f in staged {
                do {
                    try await kosha.api.upload("/api/app/transactions/\(id)/attachments", name: f.name, type: f.type, data: f.data)
                } catch {
                    let m = if case KoshaError.api(_, let e) = error { e.message } else { L.tx_attach_failed() }
                    toasts.show("\(f.name): \(m)", warning: true)
                }
            }
            kosha.changed()
        }
    }

    /// Transfers need a connection: they're two linked rows the server writes together.
    private func saveTransfer(again: Bool, sent: Int64, from: Wallet) {
        guard let to = toAccount else {
            sheet = .to
            return error(L.add_error_to_account())
        }
        let s = sides
        if s.converted <= 0 { return error(L.add_error_fee()) }
        if s.received <= 0 { return error(L.add_error_received()) }
        let body = NewTransfers(transfers: [NewTransfer(
            fromAccountId: from.id, toAccountId: to.id, sent: sent, received: s.received, fee: s.fee,
            provider: fee.provider.trimmingCharacters(in: .whitespaces), day: day.text, time: time,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines)
        )])
        saving = true
        sheet = nil
        Task {
            let saved: SavedTransfer
            do {
                let reply: SavedTransfers = try await kosha.api.post("/api/v1/transfers", body)
                guard let first = reply.transfers.first else { throw KoshaError.offline }
                saved = first
            } catch {
                saving = false
                return self.error(message(error, fallback: L.add_error_add()))
            }
            saving = false
            saves += 1
            kosha.local.lastAccount = from.id
            kosha.changed()
            let kosha = self.kosha
            let toasts = self.toasts
            toasts.show(L.add_toast_moved(amount: Money.format(sent, from.currency, Money.locale(L.language), sign: .none),
                                          from: from.name, to: to.name)) {
                Task { await AddModel.undoTransfer(kosha, toasts, saved) }
            }
            if again { next() } else { close() }
        }
    }

    /// Saves a repeating entry as a schedule (create_recurring), the way the Recurring form does. When its day is today
    /// or past, that payment is recorded at once (update_recurring_payment → paid), so the entry shows up now whatever
    /// "Record payments automatically" says; later ones follow the schedule. Schedules need a connection.
    private func saveRecurring(again: Bool, amount: Int64, from: Wallet, r: Repeat, cat: String?, sub: String?) {
        var to: Wallet?
        if transfer {
            guard let t = toAccount else {
                sheet = .to
                return error(L.add_error_to_account())
            }
            to = t
        }
        let catName = kosha.category(sub ?? cat)?.name ?? ""
        let typed = payee.trimmingCharacters(in: .whitespaces)
        let name = !typed.isEmpty ? typed : to.map { "\(from.name) → \($0.name)" } ?? catName
        let signed = kind == .income ? amount : -amount
        var body: [String: JSONValue] = [
            "name": .string(name), "accountId": .string(from.id), "amount": .number(Double(signed)),
            "every": .number(Double(r.every)), "unit": .string(r.unit), "startDay": .string(day.text),
            "endDay": r.endDay.map { .string($0.text) } ?? .null, "autoPay": .bool(r.autoPay),
            "kind": .string(kind == .expense ? r.kind : "repetitive"),
            "note": .string(note.trimmingCharacters(in: .whitespacesAndNewlines)),
        ]
        if let to {
            body["toAccountId"] = .string(to.id)
            // Between currencies, what arrives each time.
            if to.currency != from.currency { body["toAmount"] = .number(Double(sides.received)) }
        } else if let c = sub ?? cat {
            body["categoryId"] = .string(c)
        }
        let staged = files
        let first = day
        let tags = self.tags
        let eventPicked = self.eventPicked
        let eventChoice = self.eventChoice
        saving = true
        sheet = nil
        Task {
            let id: String
            var paid: String?
            do {
                id = (try await kosha.api.post("/api/v1/recurring", JSONValue.object(body)) as IdReply).id
                if first <= today {
                    let p: PaymentReply = try await kosha.api.patch("/api/v1/recurring/\(id)/payments/\(first.text)",
                                                                    JSONValue.object(["status": .string("paid")]))
                    paid = p.payment?.transactionId
                }
            } catch KoshaError.offline {
                saving = false
                return error(L.app_add_repeat_offline())
            } catch {
                saving = false
                return self.error(message(error, fallback: L.add_error_add()))
            }
            saving = false
            saves += 1
            kosha.local.lastAccount = from.id
            kosha.changed()
            // Tags, the event and files belong to the payment's entry, not the schedule.
            if let paid, to == nil, !tags.isEmpty || eventPicked {
                var tx: [String: JSONValue] = ["id": .string(paid), "tags": .array(tags.map(JSONValue.string))]
                if eventPicked { tx["eventId"] = eventChoice.map(JSONValue.string) ?? .null }
                try? await kosha.api.send("PATCH", "/api/v1/transactions", body: JSONValue.object(["transactions": .array([.object(tx)])]))
            }
            if let paid, !staged.isEmpty, meta?.attachments == true { upload(paid, staged) }
            let shown = Money.format(signed, from.currency, Money.locale(L.language), sign: to != nil ? .none : .always)
            let kosha = self.kosha
            let toasts = self.toasts
            toasts.show(L.app_ios_add_toast_repeats(amount: shown, name: name, frequency: everyText(r))) {
                Task {
                    // The schedule first: deleting a schedule's payment on its own would only mark it skipped.
                    do {
                        try await kosha.api.send("DELETE", "/api/v1/recurring/\(id)")
                        if let paid { try await kosha.api.send("POST", "/api/v1/transactions/delete", body: DeleteIds(ids: [paid])) }
                    } catch {
                        toasts.show(L.tx_delete_failed(), warning: true)
                    }
                    kosha.changed()
                }
            }
            if again { next() } else { close() }
        }
    }

    /// delete_transactions takes a half's id, so Undo finds the outgoing half by the transfer's id.
    private static func undoTransfer(_ kosha: Kosha, _ toasts: Toasts, _ t: SavedTransfer) async {
        do {
            let list: TransactionList = try await kosha.api.get("/api/v1/transactions", query: [
                "accountId": t.fromAccountId, "from": t.day, "to": t.day, "type": "transfer", "limit": "100",
            ])
            guard let half = list.transactions.first(where: { $0.transfer?.id == t.id }) else { return }
            try await kosha.api.send("POST", "/api/v1/transactions/delete", body: DeleteIds(ids: [half.id]))
        } catch {
            toasts.show(L.tx_delete_failed(), warning: true)
        }
        kosha.changed()
    }

    /// Ready for the next entry: account and date stay; Repeat goes back to off (AddSaved).
    private func next() {
        input = ""
        payee = ""
        repeating = nil
        picked = nil
        suggestions = []
        categoryId = nil
        subcategoryId = nil
        aiCategoryId = nil
        filled = nil
        receipt = nil
        described = ""
        note = ""
        tags = []
        files = []
        eventPicked = false
        eventChoice = nil
        time = nil
        fee = FeeInput()
        payeeByAi = false
        accountGuessed = false
        viaNext = false
        savedOnce = true
    }

    // MARK: Events

    /// New event from the note sheet: it starts on the entry's day and runs until ended.
    func createEvent(_ name: String, done: @escaping () -> Void) {
        let n = name.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { return error(L.tx_event_name_required()) }
        if kosha.demo { return error(L.common_demo_read_only()) }
        Task {
            do {
                let saved: SavedEvent = try await kosha.api.post("/api/v1/events", NewEvent(name: n, startDay: day.text))
                newEvent = try? KoshaJSON.decode(Event.self, KoshaJSON.encode(
                    JSONValue.object(["id": .string(saved.id), "name": .string(n), "start_day": .string(day.text)])
                ))
                pickEvent(saved.id)
                kosha.changed()
                done()
            } catch {
                self.error(message(error, fallback: L.tx_event_save_failed()))
            }
        }
    }

    // MARK: AI

    /// Describe it: one sentence read into the form, not saved.
    func describe() {
        let text = described.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, reading == nil else { return }
        sheet = nil
        read(.text, ReadAsk(text: text, accountId: account?.id), photo: nil)
    }

    /// A receipt photo (JPEG, at most 1600px): read into the form, and attached once the entry is saved.
    func scan(_ jpeg: Data) {
        guard reading == nil else { return }
        read(.receipt, ReadAsk(photo: .init(data: jpeg.base64EncodedString(), mimeType: "image/jpeg"), accountId: account?.id),
             photo: jpeg)
    }

    private func read(_ from: Filled, _ ask: ReadAsk, photo: Data?) {
        reading = from
        Task {
            defer { reading = nil }
            do {
                let reply: ReadReply = try await kosha.api.post("/api/v1/ai/read-transaction", ask)
                fill(reply.entry, from)
                if let photo {
                    camera = false
                    receipt = photo
                    if meta?.attachments == true && photo.count <= attachmentLimit {
                        files.append(Staged(name: "receipt.jpg", type: "image/jpeg", data: photo))
                    }
                }
            } catch {
                self.error(message(error, fallback: from == .receipt ? L.add_error_receipt() : L.add_error_read()))
            }
        }
    }

    /// What AI read goes into the form; fields it couldn't read keep what they had (phone-add.tsx fill).
    func fill(_ e: ReadEntry, _ from: Filled) {
        if let w = active.first(where: { $0.id == e.accountId }) {
            if w.id != account?.id { accountGuessed = true }
            accountId = w.id
        }
        let category = kosha.category(e.categoryId)
        let amount = e.amount ?? 0
        if amount > 0 { kind = .income } else if amount < 0 { kind = .expense } else if let category {
            kind = category.isIncome ? .income : .expense
        } else if transfer { kind = .expense }
        if amount != 0 { input = keypadInput(abs(amount), decimals: decimals) }
        if !e.payee.trimmingCharacters(in: .whitespaces).isEmpty {
            payee = e.payee
            picked = nil
            payeeByAi = true
        }
        categoryId = nil
        subcategoryId = nil
        aiCategoryId = category.map { $0.parentId ?? $0.id }
        if let d = e.day.flatMap(Day.init) { day = d }
        if let t = e.time, t.count == 5 { time = t }
        if !e.note.trimmingCharacters(in: .whitespaces).isEmpty { note = e.note }
        if !e.tags.isEmpty { tags = (tags + e.tags).reduce(into: []) { if !$0.contains($1) { $0.append($1) } } }
        filled = from
    }

    // MARK: Duplicate

    /// Starts from an existing entry (GET /api/app/transactions/{id}) with today's date.
    private func duplicate(_ id: String) async {
        guard let tx: Model.Transaction = try? await kosha.api.get("/api/app/transactions/\(id)") else { return }
        if let link = tx.transfer {
            kind = .transfer
            if active.contains(where: { $0.id == tx.accountId }) { accountId = tx.accountId; accountPicked = true }
            // A transfer is listed as its outgoing half; what was sent includes the fee.
            toAccountId = link.counterAccountId
            let d = Money.decimals(tx.currency)
            input = keypadInput(abs(tx.amount) + link.fee, decimals: d)
            let toCurrency = active.first { $0.id == link.counterAccountId }?.currency ?? tx.currency
            fee = FeeInput(
                fee: keypadInput(link.fee, decimals: d),
                received: link.counterAmount.map { keypadInput(abs($0), decimals: Money.decimals(toCurrency)) } ?? "",
                typed: link.counterAmount != nil && toCurrency != tx.currency ? .received : nil,
                provider: link.provider
            )
        } else {
            kind = tx.amount > 0 ? .income : .expense
            if active.contains(where: { $0.id == tx.accountId }) { accountId = tx.accountId; accountPicked = true }
            input = keypadInput(abs(tx.amount), decimals: Money.decimals(tx.currency))
            payee = tx.payee
            if !Categories.isSystem(tx.categoryId) {
                categoryId = tx.categoryId
                subcategoryId = tx.subcategoryId
            }
            tags = tx.tags
        }
        note = tx.note
        day = today
    }
}
