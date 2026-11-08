import Testing
@testable import Design

// One suite, serialised: the language is global.
@Suite(.serialized) struct Strings {
    @Test func english() {
        L.use(language: "en")
        #expect(L.app_key_divide() == "Divide")
        #expect(L.accounts_count(count: 1) == "1 account")
        #expect(L.accounts_count(count: 3) == "3 accounts")
        #expect(L.import_summary(count: 1, accounts: 2, n: "1", a: "2") == "1 transaction in 2 accounts")
    }

    @Test func otherLanguages() {
        L.use(language: "ru")
        #expect(L.accounts_count(count: 1) == "1 счёт")
        #expect(L.accounts_count(count: 3) == "3 счёта")
        #expect(L.accounts_count(count: 5) == "5 счетов")
        L.use(language: "de")
        #expect(L.app_key_divide() == "Teilen")
        L.use(language: "ja")
        #expect(L.pluralCase(1) == "other")
        L.use(language: "en")
    }

    @Test func markup() {
        L.use(language: "en")
        let s = Msg.segments(key: "app_add_privacy", ["provider": "Anthropic"])
        #expect(s.map(\.text).joined() == "Kosha sends only what you share with Anthropic.")
        #expect(s.first { $0.tag == "link" }?.text == "what you share")
    }
}
