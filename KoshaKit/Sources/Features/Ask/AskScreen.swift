import SwiftUI
import Model
import API
import Store
import Design

struct AskTurn: Codable, Sendable, Hashable {
    let role: String
    let text: String
}

private struct AskRequest: Encodable {
    let question: String
    let history: [AskTurn]
}

/// ask_kosha's answer: the text, what it looked up, and searches for the entries behind it.
struct AskReply: Codable, Sendable, Hashable {
    var answer: String
    @D var lookups: [String]
    @D var sources: [Source]
    @D var history: [AskTurn]

    struct Source: Codable, Sendable, Hashable {
        var label: String
        var search: JSONValue?
    }
}

/// The conversation outlives a visit to another screen, until New chat, as on the web.
@MainActor @Observable
final class AskConversation {
    enum Said: Hashable {
        case question(String)
        case answer(AskReply)
        case failed(String)
    }

    static let shared = AskConversation()
    var said: [Said] = []
    var history: [AskTurn] = []
    var busy = false
}

private let providers = ["anthropic": "Anthropic", "openai": "OpenAI", "gemini": "Gemini", "openrouter": "OpenRouter",
                         "ollama": "Ollama"]

private func providerName(_ provider: String?) -> String {
    guard let provider else { return "" }
    return provider == "compatible" ? L.ask_your_endpoint() : providers[provider] ?? provider
}

/// Ask Kosha (AI, only when meta.ai.ask): suggested questions, then each question with its answer, the entries behind it
/// (as Activity searches), how Kosha found it, and the model. Follow-ups carry the history. Uses the public ask_kosha
/// operation, without streaming, so the look-ups show once the answer is in. Ported from AskScreen.kt.
struct AskScreen: View {
    let question: String?
    @Environment(Kosha.self) private var kosha
    @Environment(Navigator.self) private var nav
    @Environment(\.kosha) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var chat = AskConversation.shared
    @State private var draft = ""

    var body: some View {
        let c = theme.colors
        Group {
            if kosha.meta?.aiFlags.ask == true {
                VStack(spacing: 0) {
                    ZStack {
                        Text(L.ask_title()).kFont(.sheetTitle).accessibilityAddTraits(.isHeader)
                        HStack {
                            IconButton("caret-left", label: L.common_back()) { dismiss() }
                            Spacer()
                            IconButton("note-pencil", label: L.ask_new_chat()) {
                                guard !chat.busy else { return }
                                chat.said = []
                                chat.history = []
                            }
                            .opacity(chat.said.isEmpty || chat.busy ? 0.4 : 1)
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(minHeight: 52)
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                if chat.said.isEmpty && !chat.busy { Suggestions(send: send) }
                                ForEach(Array(chat.said.enumerated()), id: \.offset) { _, s in
                                    switch s {
                                    case .question(let q):
                                        Text(q).foregroundStyle(c.onInk)
                                            .padding(.horizontal, 14).padding(.vertical, 12)
                                            .background(c.ink, in: UnevenRoundedRectangle(
                                                topLeadingRadius: 18, bottomLeadingRadius: 18, bottomTrailingRadius: 6, topTrailingRadius: 18))
                                            .frame(maxWidth: 290, alignment: .trailing)
                                            .frame(maxWidth: .infinity, alignment: .trailing)
                                    case .answer(let r): Answer(reply: r)
                                    case .failed(let m):
                                        Text(m).kFont(.small).foregroundStyle(c.bad)
                                            .onAppear { AccessibilityNotification.Announcement(m).post() }
                                    }
                                }
                                if chat.busy { Working() }
                                Color.clear.frame(height: 1).id("end")
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                            .padding(.bottom, 16)
                        }
                        .onChange(of: chat.said.count) { _, _ in withAnimation(theme.animation()) { proxy.scrollTo("end") } }
                        .onChange(of: chat.busy) { _, _ in withAnimation(theme.animation()) { proxy.scrollTo("end") } }
                    }
                    composer
                }
                .background(c.bg)
                .task(id: question) {
                    // A question carried in the route (from Search) is asked once.
                    if let q = question?.trimmingCharacters(in: .whitespaces), !q.isEmpty,
                       !chat.said.contains(.question(q)) { send(q) }
                }
            } else {
                Color.clear.onAppear { dismiss() }
            }
        }
        .hideNavigationBar()
    }

    private var composer: some View {
        let c = theme.colors
        let ready = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !chat.busy
        return VStack(spacing: 8) {
            HStack(spacing: 8) {
                TextField("", text: $draft, prompt: Text(chat.said.isEmpty ? L.ask_placeholder() : L.ask_placeholder_follow_up())
                    .foregroundStyle(c.ink3), axis: .vertical)
                    .lineLimit(1...5)
                    .kFont(.sans(16, .regular))
                    .submitLabel(.send)
                    .onSubmit { send(draft) }
                    .onChange(of: draft) { _, d in if d.count > 2000 { draft = String(d.prefix(2000)) } }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(minHeight: 48)
                    .background(c.surface, in: .rect(cornerRadius: 24))
                    .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(c.line))
                Button { send(draft) } label: {
                    PhIcon("arrow-up", color: ready ? c.onInk : c.ink3)
                        .frame(width: 48, height: 48)
                        .background(ready ? c.ink : c.soft, in: .circle)
                }
                .buttonStyle(PressStyle())
                .disabled(!ready)
                .accessibilityLabel(L.ask_submit())
            }
            if chat.said.contains(where: { if case .answer = $0 { true } else { false } }) {
                Text(L.app_ask_check()).kFont(.xs).foregroundStyle(c.ink3).frame(maxWidth: .infinity)
            } else {
                PrivacyLine(provider: kosha.meta?.aiModel?.provider)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(c.glass)
    }

    private func send(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !chat.busy else { return }
        draft = ""
        let chat = chat
        chat.said.append(.question(q))
        chat.busy = true
        Task {
            do {
                let reply: AskReply = try await kosha.api.post(
                    "/api/v1/ai/ask", AskRequest(question: String(q.prefix(2000)), history: Array(chat.history.suffix(22))))
                chat.history = reply.history
                chat.said.append(.answer(reply))
            } catch let e as KoshaError {
                if case .api(_, let err) = e { chat.said.append(.failed(err.message.isEmpty ? L.ask_error() : err.message)) }
                else { chat.said.append(.failed(L.common_offline_title())) }
            } catch {
                chat.said.append(.failed(L.ask_error()))
            }
            chat.busy = false
        }
    }
}

/// "Kosha sends only what you share with Anthropic.", "what you share" opening Settings › AI › What AI can see.
struct PrivacyLine: View {
    let provider: String?
    @Environment(Navigator.self) private var nav
    @Environment(\.kosha) private var theme

    var body: some View {
        var text = AttributedString()
        for s in Msg.segments(key: "app_ask_privacy", ["provider": providerName(provider)]) {
            var part = AttributedString(s.text)
            if s.tag == "link" {
                part.link = URL(string: "kosha-app:ai-privacy")
                part.underlineStyle = .single
            }
            text += part
        }
        return Text(text)
            .kFont(.xs)
            .foregroundStyle(theme.colors.ink3)
            .tint(theme.colors.ink3)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 24)
            .environment(\.openURL, OpenURLAction { _ in
                nav.push(.settings(page: "ai-privacy"))
                return .handled
            })
    }
}

private struct Suggestions: View {
    let send: (String) -> Void
    @Environment(Kosha.self) private var kosha
    @Environment(\.kosha) private var theme

    var body: some View {
        let c = theme.colors
        let m = kosha.meta
        let top = (m?.categories ?? []).filter { !$0.isArchived && !$0.isIncome && $0.parentId == nil && !Categories.isSystem($0.id) }
            .max { $0.uses < $1.uses }
        let event = m?.events.first
        // English lowercases the category mid-sentence; German keeps nouns capitalised (ask.tsx).
        let list: [(String, String)] = [
            (categoryIconName(top?.icon),
             top.map { L.ask_suggest_category(category: L.language == "en" ? $0.name.lowercased() : $0.name) } ?? L.ask_suggest_spent()),
            ("chart-bar", L.ask_suggest_compare()),
            ("arrow-fat-lines-up", L.ask_suggest_biggest()),
            (event != nil ? "calendar-star" : "arrows-clockwise",
             event.map { L.ask_suggest_event(event: $0.name) } ?? L.ask_suggest_subscriptions()),
        ]
        VStack(alignment: .leading, spacing: 10) {
            Sparkle(size: 26).frame(width: 52, height: 52).background(c.brand.opacity(0.12), in: .rect(cornerRadius: 16))
            Text(L.ask_empty_title()).kFont(.title).padding(.top, 6).accessibilityAddTraits(.isHeader)
            Text(L.ask_empty_body()).kFont(.small).foregroundStyle(c.ink2)
            Spacer().frame(height: 16)
            ForEach(list, id: \.1) { icon, text in
                Button { send(text) } label: {
                    HStack(spacing: 10) {
                        PhIcon(icon, size: 18, color: c.ink3)
                        Text(text).kFont(.small).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(minHeight: 48)
                    .background(c.surface, in: .rect(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(c.line))
                    .contentShape(.rect(cornerRadius: 16))
                }
                .buttonStyle(PressStyle())
            }
        }
        .padding(.top, 16)
    }
}

/// The question is with the model: a spinner and placeholder lines until the answer is in.
private struct Working: View {
    @Environment(\.kosha) private var theme
    var body: some View {
        let c = theme.colors
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Sparkle()
                Text(L.app_ask_looking()).kFont(.small).foregroundStyle(c.ink3)
            }
            Card {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small).tint(c.brand)
                    Text(L.ask_thinking() + "…").kFont(.small)
                }
            }
            .frame(maxWidth: 320, alignment: .leading)
            Skeleton(height: 12).frame(maxWidth: 300, alignment: .leading)
            Skeleton(height: 12).frame(maxWidth: 230, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct Answer: View {
    let reply: AskReply
    @Environment(Kosha.self) private var kosha
    @Environment(Navigator.self) private var nav
    @Environment(\.kosha) private var theme
    @State private var open = false

    var body: some View {
        let c = theme.colors
        VStack(alignment: .leading, spacing: 12) {
            Prose(text: reply.answer)
            if !reply.sources.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(reply.sources, id: \.self) { s in
                        Chip(s.label, small: true, action: { nav.openActivity(activitySearch(s.search)) }) {
                            PhIcon("list-bullets", size: 16)
                        }
                    }
                }
            }
            if !reply.lookups.isEmpty {
                Button { withAnimation(theme.animation()) { open.toggle() } } label: {
                    HStack(spacing: 8) {
                        PhIcon("magnifying-glass", size: 16)
                        Text(L.ask_how_found(count: reply.lookups.count)).kFont(.small).foregroundStyle(c.ink2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        PhIcon(open ? "caret-up" : "caret-down", size: 16, color: c.ink3)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .accessibilityValue(open ? Text(L.common_close()) : Text(""))
                if open {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(reply.lookups, id: \.self) { Text($0).kFont(.small) }
                    }
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) { c.line.frame(width: 2) }
                }
            }
            if let model = kosha.meta?.aiModel {
                Text(L.ask_answered_by(provider: providerName(model.provider), model: model.model)).kFont(.xs).foregroundStyle(c.ink3)
            }
        }
    }

    /// A source's search_transactions inputs as Activity's search.
    private func activitySearch(_ j: JSONValue?) -> ActivitySearch {
        func s(_ k: String) -> String? { j?[k]?.string }
        func n(_ k: String) -> Int64? { j?[k]?.int }
        return ActivitySearch(
            query: s("query"), categoryId: s("categoryId"), accountId: s("accountId"), tag: s("tag"), eventId: s("eventId"),
            type: s("type"), minAmount: n("minAmount"), maxAmount: n("maxAmount"), month: s("month").flatMap(Month.init)
        )
    }
}

/// The little Markdown an answer uses (ask.tsx Prose): paragraphs, "- " and "1. " lists, and **bold**.
private struct Prose: View {
    let text: String
    @Environment(\.kosha) private var theme

    var body: some View {
        let c = theme.colors
        let lines = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                let item = line.range(of: #"^\s*(?:[-*]|\d+\.)\s+"#, options: .regularExpression)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let item {
                        let mark = line[item].trimmingCharacters(in: .whitespaces)
                        Text(mark.first?.isNumber == true ? mark : "•").foregroundStyle(c.ink3)
                    }
                    Text(bold(item.map { String(line[$0.upperBound...]) } ?? line)).lineSpacing(4).money()
                }
            }
        }
    }

    private func bold(_ line: String) -> AttributedString {
        var out = AttributedString()
        for (i, part) in line.components(separatedBy: "**").enumerated() {
            var a = AttributedString(part)
            if i % 2 == 1 { a.font = .custom("Geist-Medium", size: 15, relativeTo: .body) }
            out += a
        }
        return out
    }
}

/// Wraps its children onto new lines, for the source chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                y += row + spacing
                x = 0
                row = 0
            }
            x += size.width + spacing
            row = max(row, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += row + spacing
                x = bounds.minX
                row = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}
