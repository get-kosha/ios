import Testing
@testable import Features

// The web's quick add asserts (../kosha-web/src/lib/core.test.ts), as the Android app's QuickAddTest.kt runs them.

private let qw = [Named(id: "v", name: "Visa Card"), Named(id: "n", name: "Main account")]
private let qc = [Named(id: "dining", name: "Dining"), Named(id: "groceries", name: "Groceries")]
private func q(_ s: String, _ locale: String = "en", c: [Named] = qc) -> QuickParse {
    QuickAdd.parse(s, wallets: qw, categories: c, locale: locale)
}
private func ai(_ s: String, _ locale: String = "en") -> Bool { QuickAdd.needsAi(s, q(s, locale), locale: locale) }
private func local(_ s: String, _ locale: String) -> (Int64?, QuickDate?, String, Bool) {
    let p = q(s, locale)
    return (p.amount, p.date, p.payee, QuickAdd.needsAi(s, p, locale: locale))
}
private func same(_ a: (Int64?, QuickDate?, String, Bool), _ b: (Int64?, QuickDate?, String, Bool)) -> Bool {
    a.0 == b.0 && a.1 == b.1 && a.2 == b.2 && a.3 == b.3
}

@Test func parsesALine() {
    #expect(q("29,57 Pizza Hut dining visa yesterday")
        == QuickParse(amount: 2957, date: .yesterday, walletId: "v", categoryId: "dining", payee: "Pizza Hut"))
    let qt = q("12 #Trip lunch #trip #rome-2026")
    #expect(qt.tags == ["trip", "rome-2026"])
    #expect(qt.payee == "lunch")
    let qi = q("+4200 salary main di")
    #expect(qi.amount == 420_000)
    #expect(qi.income)
    #expect(qi.walletId == "n")
    #expect(qi.categoryId == nil) // "di" is under 3 letters
    #expect(qi.payee == "salary di")
    #expect(q("tesco").amount == nil)
    #expect(q("12,50 tesco ayer").date == .yesterday)
    #expect(q("12.50 tesco 昨天").payee == "tesco")
    #expect(q("9000 외식", c: [Named(id: "d", name: "외식")]).categoryId == "d")
}

@Test func onlySentencesGoToAi() {
    #expect(!ai("24.90 pizza hut yesterday visa"))
    #expect(!ai("coffee 4.5"))
    #expect(!ai("+3200 salary"))
    #expect(!ai("tesco"))
    #expect(ai("lunch with sam at nandos 18.50 last friday"))
    #expect(ai("€12 coffee"))
    #expect(ai("uber 23 eur"))
    #expect(ai("rent 1200 on the 3rd"))
    #expect(ai("twelve fifty nandos"))
    let qg = q("12,50 Lebensmittel gestern", c: [Named(id: "food", name: "Lebensmittel")])
    #expect(qg.amount == 1250)
    #expect(qg.date == .yesterday)
    #expect(qg.categoryId == "food")
    #expect(qg.payee == "")
    #expect(q("Bäcker 3 heute").date == .today)
    #expect(q("constructor 3").date == nil)
    #expect(!ai("Bäcker 4,20 gestern visa"))
    #expect(ai("Miete 1200 am 3."))
    #expect(ai("Essen mit Sam 18,50 letzten Freitag"))
    #expect(ai("Kino 12 vorgestern"))
}

@Test func numberFormats() {
    #expect(q("1,234.56 rent", "en").amount == 123_456)
    #expect(q("1.234,56 Miete", "de").amount == 123_456)
    #expect(q("1'200.50 Miete", "de").amount == 120_050)
    #expect(q("1,234 rent", "en").amount == 123_400)
    #expect(q("0,5 café", "fr").amount == 50)
    #expect(q("1,00,000 किराया", "hi").amount == 10_000_000)
    #expect(q("３万円 家賃", "ja").amount == 3_000_000)
    #expect(q("1.5万 房租", "zh").amount == 1_500_000)
}

@Test func everyLanguage() {
    #expect(same(local("24.90 pizza hut yesterday", "en"), (2490, .yesterday, "pizza hut", false)))
    #expect(same(local("Bäcker 4,20 heute", "de"), (420, .today, "Bäcker", false)))
    #expect(same(local("12,50 mercadona ayer", "es"), (1250, .yesterday, "mercadona", false)))
    #expect(same(local("4,20 boulangerie aujourd’hui", "fr"), (420, .today, "boulangerie", false)))
    #expect(same(local("3,50 bar ieri", "it"), (350, .yesterday, "bar", false)))
    #expect(same(local("padaria 8,90 hj", "pt"), (890, .today, "padaria", false)))
    #expect(same(local("6,95 albert heijn gister", "nl"), (695, .yesterday, "albert heijn", false)))
    #expect(same(local("350 пятёрочка вчера", "ru"), (35000, .yesterday, "пятёрочка", false)))
    #expect(same(local("दूध ५० आज", "hi"), (5000, .today, "दूध", false)))
    #expect(same(local("昨日ランチ850", "ja"), (85000, .yesterday, "ランチ", false)))
    #expect(same(local("昨天午饭35", "zh"), (3500, .yesterday, "午饭", false)))
    #expect(same(local("점심 9000 오늘", "ko"), (900_000, .today, "점심", false)))
    #expect(same(local("１２００ 本屋 きのう", "ja"), (120_000, .yesterday, "本屋", false)))
    #expect(q("11月3日 家賃 80000", "ja").amount == 8_000_000)
    #expect(q("hier boulangerie 4,20", "fr").date == .yesterday)
    #expect(q("hier boulangerie 4,20", "en").date == .yesterday)
    #expect(q("hier Bäcker 4,20", "de").date == nil)
    #expect(q("어제 점심 9000원", "ko").amount == 900_000)
    #expect(q("어제 점심 9000원", "ko").payee == "점심")
    #expect(q("3만원 택시", "ko").amount == 3_000_000)
    #expect(q("500₽ такси", "ru").currency)
    #expect(q("R$ 20 padaria", "pt").amount == 2000)
    #expect(q("35元午饭", "zh").payee == "午饭")
    for (s, l) in [("12,50 € café", "fr"), ("35元 打车", "zh"), ("スタバ 500円", "ja"), ("500 руб такси", "ru")] {
        #expect(ai(s, l), "\(s)")
    }
    for (s, l) in [
        ("café con Ana 4,50 el viernes", "es"), ("déjeuner avec Paul 18,50 vendredi", "fr"),
        ("pizza con Marco 25 sabato", "it"), ("almoço com a Ana 30 sexta-feira", "pt"), ("lunch met Sanne 15 vrijdag", "nl"),
        ("обед с Машей 800 в пятницу", "ru"), ("कल दूध 50", "hi"), ("スタバで500", "ja"), ("一昨日 ランチ 900", "ja"),
        ("在星巴克花了35", "zh"), ("스타벅스에서 5000", "ko"), ("Essen 20 vorgestern", "de"),
    ] {
        #expect(ai(s, l), "\(s)")
    }
    #expect(!ai("mars 1,20", "en"))
    #expect(ai("mars 1,20 courses", "fr"))
}
