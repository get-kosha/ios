import Foundation
import Model

/// Every string people read, from the String Catalog that scripts/sync-strings.py builds out of the web repo's
/// messages. Strings.swift holds one function per message, named as on the web (`L.add_title()`, like `m.add_title()`).
///
/// The language follows the `language` setting, else the phone's languages (`use(language:)`), so lookups go
/// through that language's `.lproj` rather than the system's choice.
public enum L {
    /// The languages Kosha has messages for.
    public static let languages = ["en", "de", "es", "fr", "hi", "it", "ja", "ko", "nl", "pt", "ru", "zh"]

    // ponytail: set on the main actor when the language changes, read anywhere; a rare race reads the old language.
    nonisolated(unsafe) private static var bundle: Bundle = lproj("en") ?? .module
    nonisolated(unsafe) private static var fallback: Bundle = lproj("en") ?? .module
    nonisolated(unsafe) public private(set) static var language = "en"

    private static func lproj(_ language: String) -> Bundle? {
        Bundle.module.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:))
    }

    /// The language Kosha uses for `preferred` (the `language` setting), else the first of the phone's it has.
    public static func resolve(_ preferred: String?) -> String {
        if let p = preferred, languages.contains(p) { return p }
        for id in Locale.preferredLanguages {
            if let code = Locale(identifier: id).language.languageCode?.identifier, languages.contains(code) { return code }
        }
        return "en"
    }

    public static func use(language: String) {
        self.language = languages.contains(language) ? language : "en"
        bundle = lproj(self.language) ?? fallback
    }

    /// The message's text in the current language, English when it has none.
    public static func raw(_ key: String) -> String {
        let missing = "\u{1}"
        let text = bundle.localizedString(forKey: key, value: missing, table: nil)
        if text != missing { return text }
        let en = fallback.localizedString(forKey: key, value: missing, table: nil)
        return en == missing ? key : en
    }

    /// The language's CLDR plural case for `n`: "one", "few", "many" or "other".
    public static func pluralCase(_ n: Int) -> String {
        // Each case reads "<n>|<case>"; the count has to be in the text for the catalog to pick a case by it.
        let format = bundle.localizedString(forKey: "kosha.plural", value: "%lld|other", table: nil)
        let text = String(format: format, locale: Money.locale(language), n)
        return text.split(separator: "|").last.map(String.init) ?? "other"
    }

    static func text(_ key: String, _ args: [String: String]) -> String { Msg.plain(raw(key), args) }

    /// A plural message: the case for each count (`key|one|any`), falling back to `any` per selector, then "other".
    static func plural(_ key: String, _ counts: [Int], _ args: [String: String]) -> String {
        let picked = counts.map(pluralCase)
        var choices: [[String]] = [[]]
        for c in picked { choices = choices.flatMap { [$0 + [c], $0 + ["any"], $0 + ["other"]] } }
        for choice in choices {
            let k = ([key] + choice).joined(separator: "|")
            let missing = "\u{1}"
            let text = bundle.localizedString(forKey: k, value: missing, table: nil)
            if text != missing { return Msg.plain(text, args) }
        }
        for choice in choices {
            let k = ([key] + choice).joined(separator: "|")
            let text = fallback.localizedString(forKey: k, value: "\u{1}", table: nil)
            if text != "\u{1}" { return Msg.plain(text, args) }
        }
        return key
    }
}

/// A message's text with its `{name}` variables filled and its `{#tag}…{/tag}` markup.
public enum Msg {
    /// One run of text, with the markup tag around it if it has one (`num`, `strong`, `link`, …).
    public struct Segment: Equatable, Sendable {
        public let text: String
        public let tag: String?
    }

    static func fill(_ template: String, _ args: [String: String]) -> String {
        var out = template
        for (k, v) in args { out = out.replacingOccurrences(of: "{\(k)}", with: v) }
        return out
    }

    /// The text without markup.
    public static func plain(_ template: String, _ args: [String: String]) -> String {
        segments(template, args).map(\.text).joined()
    }

    /// The text split at its markup, for messages that style part of a sentence (a link, a figure in mono).
    public static func segments(_ template: String, _ args: [String: String]) -> [Segment] {
        let text = fill(template, args)
        var out: [Segment] = []
        var rest = Substring(text)
        while let open = rest.range(of: #"\{#(\w+)\}"#, options: .regularExpression) {
            if open.lowerBound > rest.startIndex { out.append(Segment(text: String(rest[..<open.lowerBound]), tag: nil)) }
            let tag = String(rest[open].dropFirst(2).dropLast())
            let after = rest[open.upperBound...]
            if let close = after.range(of: "{/\(tag)}") {
                out.append(Segment(text: String(after[..<close.lowerBound]), tag: tag))
                rest = after[close.upperBound...]
            } else {
                rest = after
            }
        }
        if !rest.isEmpty { out.append(Segment(text: String(rest), tag: nil)) }
        return out
    }

    /// A message's segments by key, for the rich text views.
    public static func segments(key: String, _ args: [String: String] = [:]) -> [Segment] {
        segments(L.raw(key), args)
    }
}
