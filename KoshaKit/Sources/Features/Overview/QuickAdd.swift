import Foundation
import Model

// Quick add parses one line of text into a transaction as you type. A port of ../kosha-web/src/lib/quick-add.ts (via
// the Android app's QuickAdd.kt), pure so the tests run the web's asserts (core.test.ts). Amounts use Decimal, never
// floating point.

enum QuickDate: Equatable, Sendable { case today, yesterday }

struct QuickParse: Equatable, Sendable {
    /// Minor units, always positive; `income` carries the sign.
    var amount: Int64?
    var income = false
    /// Today or yesterday when typed (in any language Kosha speaks).
    var date: QuickDate?
    var walletId: String?
    var categoryId: String?
    var payee = ""
    /// Words typed as #hashtags, cleaned as stored.
    var tags: [String] = []
    /// A currency sign or unit was typed (€12, 9000원, 35元), so the account's own currency may not apply.
    var currency = false
}

/// An account or category quick add can match by name.
struct Named: Sendable {
    let id: String
    let name: String
}

enum QuickAdd {
    private struct Words {
        let today: [String], yesterday: [String], sentence: String
        var plain: [String] = []
    }

    // The words quick add knows, per language (quick-add.ts WORDS). Every language's words work whatever the UI language
    // is; `plain` words stay ordinary while that language is the UI language.
    private static let words: [String: Words] = [
        "en": Words(
            today: ["today", "tdy"], yesterday: ["yesterday", "yday", "yest"],
            sentence: #"at|for|from|with|on|in|via|by|and|paid|pay|spent|spend|bought|got|received|refund|refunded|split|last|ago|this|next|tomorrow|tonight|morning|noon|evening|week|month|(mon|tues?|wed(nes)?|thu(rs)?|fri|satur|sun)(day)?|jan(uary)?|feb(ruary)?|march|april|june|july|aug(ust)?|sept?(ember)?|oct(ober)?|nov(ember)?|dec(ember)?|\d+(st|nd|rd|th|am|pm)|\d{1,2}:\d{2}|eur|usd|gbp|inr|chf|jpy|aud|cad|sgd|aed|bucks|euros?|dollars?|pounds?|quid|rupees?"#,
            plain: ["met", "mars"]
        ),
        "de": Words(
            today: ["heute", "heut"], yesterday: ["gestern"],
            sentence: #"am|um|für|von|vom|mit|bei|beim|im|über|und|bezahlt|gezahlt|ausgegeben|gekauft|bekommen|erhalten|erstattet|erstattung|geteilt|letzte[nrs]?|vor|diese[nrs]?|nächste[nrs]?|morgen|übermorgen|vorgestern|abends?|morgens|mittags?|tage?n?|woche|monat|(mon|diens|donners|frei|sams|sonn)tag|mittwoch|januar|februar|märz|mai|juni|juli|oktober|dezember|uhr|franken|rupien"#,
            plain: ["hier"]
        ),
        "es": Words(
            today: ["hoy"], yesterday: ["ayer"],
            sentence: #"con|para|por|en|desde|pagu[eé]|pagad[oa]|gast[eé]|gastad[oa]|compr[eé]|comprad[oa]|recib[ií]|recibid[oa]|reembolso|devoluci[oó]n|dividid[oa]|pasad[oa]|[uú]ltim[oa]|pr[oó]xim[oa]|est[ea]|ma[nñ]ana|anoche|anteayer|antier|tarde|noche|mediod[ií]a|hace|d[ií]as|semana|mes|lunes|martes|mi[eé]rcoles|jueves|viernes|s[aá]bado|domingo|enero|febrero|marzo|abril|mayo|junio|julio|agosto|sep?tiembre|octubre|noviembre|diciembre|pesos|d[oó]lares|pavos"#
        ),
        "fr": Words(
            today: ["aujourd'hui", "aujourd’hui", "auj"], yesterday: ["hier"],
            sentence: #"avec|pour|par|en|et|pay[ée]e?|d[ée]pens[ée]e?|achet[ée]e?|re[çc]ue?|rembours[ée]e?|remboursement|partag[ée]e?|derni[eè]re?|prochaine?|demain|avant-hier|soir|matin|midi|semaine|mois|jours|(lun|mar|mercre|jeu|vendre|same)di|dimanche|janvier|f[ée]vrier|mars|avril|juin|juillet|ao[uû]t|septembre|octobre|novembre|d[ée]cembre|balles"#,
            plain: ["mes"]
        ),
        "it": Words(
            today: ["oggi"], yesterday: ["ieri"],
            sentence: #"con|per|pagat[oaie]|spes[oi]|comprat[oaie]|ricevut[oaie]|rimbors[oa]|rimborsat[oaie]|divis[oa]|scors[oa]|prossim[oa]|domani|dopodomani|(l['’])?altroieri|l['’]altro|stasera|stamattina|stamani|mattina|sera|pomeriggio|settimana|mese|giorni|(lune|marte|mercole|giove|vener)d[iì]|sabato|domenica|gennaio|febbraio|marzo|aprile|maggio|giugno|luglio|agosto|settembre|ottobre|novembre|dicembre"#
        ),
        "pt": Words(
            today: ["hoje", "hj"], yesterday: ["ontem"],
            sentence: #"com|para|pra|por|em|paguei|pago|gastei|comprei|comprad[oa]|recebi|recebid[oa]|reembolso|estorno|dividid[oa]|passad[oa]|[uú]ltim[oa]|pr[oó]xim[oa]|amanh[aã]|anteontem|semana|m[eê]s|dias|atr[aá]s|(segunda|ter[cç]a|quarta|quinta|sexta)(-feira)?|s[aá]bado|domingo|janeiro|fevereiro|mar[cç]o|abril|maio|junho|julho|agosto|setembro|outubro|novembro|dezembro|reais"#
        ),
        "nl": Words(
            today: ["vandaag"], yesterday: ["gisteren", "gister"],
            sentence: #"met|voor|bij|op|en|om|betaald|uitgegeven|gekocht|gekregen|ontvangen|terugbetaald|terugbetaling|gedeeld|vorige?|afgelopen|volgende?|morgen|overmorgen|eergisteren|vanavond|vanochtend|vanmorgen|vanmiddag|ochtend|middag|avond|maand|dagen|geleden|uur|(maan|dins|woens|donder|vrij|zater|zon)dag|januari|februari|maart|mei|augustus|oktober"#,
            plain: ["hier"]
        ),
        "ru": Words(
            today: ["сегодня"], yesterday: ["вчера"],
            sentence: #"в|во|на|с|со|за|для|и|от|из|через|(за|о)?платил[аи]?|потратил[аи]?|купил[аи]?|получил[аи]?|вернул[аи]?|возврат|пополам|прошл\p{L}*|следующ\p{L}*|эт(от|у|ой|а)|завтра|позавчера|вечером|утром|днём|днем|недел\p{L}*|месяц\p{L}*|дн(я|ей)|назад|час(а|ов)?|понедельник|вторник|сред[аеуы]|четверг|пятниц[аеуы]|суббот[аеуы]|воскресень[еяю]|январ[ья]|феврал[ья]|марта?|апрел[ья]|ма[йя]|июн[ья]|июл[ья]|августа?|сентябр[ья]|октябр[ья]|ноябр[ья]|декабр[ья]|евро|долл\p{L}*|бакс\p{L}*"#
        ),
        // Hindi has only "today": "कल" (and "kal") means both yesterday and tomorrow, so it goes to AI.
        "hi": Words(
            today: ["आज", "aaj"], yesterday: [],
            sentence: #"में|से|को|के|का|की|और|लिए|साथ|पर|ख़?र्च[ाे]?|दिए|दिया|दी|मिले|मिला|मिली|ख़?रीद[ाे]|भुगतान|वापस|रिफंड|पिछल[ेा]|अगल[ेा]|परसों|कल|सुबह|शाम|रात|दोपहर|हफ़?्त[ेा]|सप्ताह|महीन[ेा]|दिन|पहले|बजे|(सोम|मंगल|बुध|गुरु|बृहस्पति|शुक्र|शनि|रवि)वार|जनवरी|फ़?रवरी|मार्च|अप्रैल|मई|जून|जुलाई|अगस्त|सित(ं|म्)बर|अक्[टत]ूबर|नव(ं|म्)बर|दिस(ं|म्)बर|डॉलर|kal|parso"#
        ),
        "ja": Words(
            today: ["今日", "きょう", "本日"], yesterday: ["昨日", "きのう"],
            sentence: #"で|払[っい]|支払|買っ|使っ|もらっ|貰っ|返金|割り?勘|先週|来週|今週|先月|来月|今月|明日|あした|一昨日|おととい|今朝|今夜|昨夜|曜|ドル|ユーロ"#
        ),
        "zh": Words(
            today: ["今天", "今日"], yesterday: ["昨天", "昨日"],
            sentence: #"花了|付了|[买買]了|[给給]了|收到|退款|退了|平分|在(?![线線])|上[周週]|下[周週]|本[周週]|[这這][周週]|上[个個]月|下[个個]月|明天|前天|今晚|昨晚|早上|晚上|中午|下午|上午|[周週][一二三四五六日天]|星期|礼拜|禮拜|美元|[欧歐]元"#
        ),
        "ko": Words(
            today: ["오늘"], yesterday: ["어제"],
            sentence: #"에서|이랑|하고|한테|에게|샀[어다음]|썼[어다음]|냈[어다음]|결제|받았|환불|더치|나눠|지난|다음|이번|내일|그저께|그제|오전|오후|[월화수목금토일]요일|달러|유로"#
        ),
    ]
    private static let attached = ["ja", "zh", "ko"]

    private static func re(_ pattern: String, ci: Bool = false) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: ci ? [.caseInsensitive] : [])
    }

    private static func matches(_ r: NSRegularExpression, _ s: String) -> Bool {
        let range = NSRange(s.startIndex..., in: s)
        return r.firstMatch(in: s, options: [.anchored], range: range).map { $0.range == range } ?? false
    }

    private static func finds(_ r: NSRegularExpression, _ s: String) -> Bool {
        r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    // Chinese, Japanese and Korean pack a category into two characters and need no spaces.
    private static let cjkRe = re(#"[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]"#)
    private static func cjk(_ s: String) -> Bool { finds(cjkRe, s) }

    private static func nfkc(_ s: String) -> String { s.precomposedStringWithCompatibilityMapping }

    private static let dates: [String: QuickDate] = {
        var out: [String: QuickDate] = [:]
        for w in words.values {
            for t in w.today { out[nfkc(t)] = .today }
            for y in w.yesterday { out[nfkc(y)] = .yesterday }
        }
        return out
    }()

    // Longest first, so 一昨日 is never read as 昨日.
    private static let cjkDates = dates.keys.filter(cjk).sorted { $0.count > $1.count }
    private static func sentence(_ langs: [String]) -> String { nfkc(langs.map { words[$0]!.sentence }.joined(separator: "|")) }
    private static let spaced = re("^(\(sentence(words.keys.filter { !attached.contains($0) }.sorted())))$", ci: true)
    private static let joined = re(sentence(attached), ci: true)

    // Currency signs, and the units people write after a number (1200円, 35元, 9000원, 500₽, 50रु).
    private static let sign = #"R\$|US\$|[€$£₹¥₩₽]"#
    private static let unit = #"円|元|块钱?|塊錢?|원|ドル|ユーロ|美元|[欧歐]元|달러|유로|руб(?:лей|ля|ль)?\.?|р\.?|रु\.?|रू\.?|रुपये|रुपए|रुपया"#

    // 3万 and 5천 are 30,000 and 5,000.
    private static let mult: [String: Int64] = ["万": 10_000, "萬": 10_000, "만": 10_000, "千": 1_000, "천": 1_000]

    // A number with `.` or `,` decimals and optional grouping: 1.234,56, 1,234.56, 1'234.50, 1,00,000 (lakh). Three
    // digits after a separator always group thousands, since no currency here has three decimals.
    private static let number = #"\d+|[1-9]\d{0,2}(?:([.,'’])\d{3})(?:\3\d{3})*|[1-9]\d?(?:,\d\d)+,\d{3}"#
    private static let money = re(#"^([+-])?(?:"# + sign + ")?(" + number + #")(?:[.,](\d{1,2}))?([万萬만千천])?("# + sign + "|" + unit + ")?$", ci: true)
    private static let currencyOnly = re("^(" + sign + "|" + unit + ")$", ci: true)
    private static let moneyEnd = re("(" + sign + "|" + unit + ")$", ci: true)
    private static let run = re(#"[+-]?(?:"# + sign + #")?\d[\d.,'’]*[万萬만千천]?(?:"# + sign + "|" + unit + ")?", ci: true)

    // Full-width forms (１２，５０ ＃旅行) become plain, and Devanagari digits become 0-9.
    private static func normalize(_ q: String) -> String {
        String(String.UnicodeScalarView(nfkc(q).unicodeScalars.map { s in
            (0x966...0x96F).contains(s.value) ? Unicode.Scalar(0x30 + s.value - 0x966)! : s
        }))
    }

    private static let edgePunct = re(#"^\p{P}+|\p{P}+$"#)
    private static func bare(_ w: String) -> String {
        let low = w.lowercased()
        return edgePunct.stringByReplacingMatches(in: low, range: NSRange(low.startIndex..., in: low), withTemplate: "")
    }

    /// Splits words in scripts written without spaces: a number at the end of a run of text or closed by a currency
    /// ("午饭35", "35元午饭", "점심9000원", but not "11月3日"), then a date word at either end ("昨天午饭").
    private static func splitJoined(_ t: String) -> [String] {
        guard cjk(t) else { return [t] }
        let ns = t as NSString
        var parts: [String] = []
        var at = 0
        for m in run.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
            let start = m.range.location, end = m.range.location + m.range.length
            let group = ns.substring(with: m.range)
            let before = start > 0 ? ns.substring(with: NSRange(location: start - 1, length: 1)) : ""
            if (end < ns.length && !finds(moneyEnd, group)) || before.contains(where: { ("0"..."9").contains($0) })
                || mult[before] != nil { continue }
            parts.append(ns.substring(with: NSRange(location: at, length: start - at)))
            parts.append(group)
            at = end
        }
        parts.append(ns.substring(from: at))
        return parts.filter { !$0.isEmpty }.flatMap(splitDate)
    }

    private static func splitDate(_ t: String) -> [String] {
        // A sentence keeps its date word, since AI reads it whole (一昨日 is not 昨日).
        if !cjk(t) || finds(joined, t) { return [t] }
        for w in cjkDates {
            if t == w { return [t] }
            if t.hasPrefix(w) { return [w] + splitDate(String(t.dropFirst(w.count))) }
            if t.hasSuffix(w) { return splitDate(String(t.dropLast(w.count))) + [w] }
        }
        return [t]
    }

    private static let split = re(#"[\s\p{Z}、。]+"#)
    private static func tokenize(_ q: String) -> [String] {
        let n = normalize(q)
        let marked = split.stringByReplacingMatches(in: n, range: NSRange(n.startIndex..., in: n), withTemplate: "\u{0}")
        return marked.split(separator: "\u{0}").map(String.init).filter { !$0.isEmpty }.flatMap(splitJoined)
    }

    /// Whether `word` (bare) is ordinary in the UI language, whatever it means in another.
    private static func plain(_ word: String, _ locale: String) -> Bool { words[locale]?.plain.contains(word) == true }

    private static func dateOf(_ word: String, _ locale: String) -> QuickDate? {
        if plain(word, locale) { return nil }
        if let own = words[locale] {
            if own.today.contains(word) { return .today }
            if own.yesterday.contains(word) { return .yesterday }
        }
        return dates[word]
    }

    private static let marks = re(#"\p{M}"#)
    private static let leadingSymbol = re(#"^[+-]?[^\d+-]"#)

    /// `#word` is a tag. The first number is the amount, written the way any of Kosha's languages writes it (12,50,
    /// 1.234,56, 1,00,000, ¥1200, 9000원, 3万), with a leading `+` for income. Today or yesterday, in any language Kosha
    /// speaks, sets the date. A word equal to an account's name or its first word sets the account. A word of 3 or more
    /// letters (2 in Chinese, Japanese or Korean) that starts a category name sets the category. The remaining words are
    /// the payee.
    static func parse(_ q: String, wallets: [Named], categories: [Named], locale: String) -> QuickParse {
        var out = QuickParse()
        var tags: [String] = []
        var rest: [String] = []
        for t in tokenize(q) {
            let low = bare(t)
            if t.hasPrefix("#") {
                let tag = cleanTag(t)
                if !tag.isEmpty && !tags.contains(tag) { tags.append(tag) }
                continue
            }
            if out.amount == nil {
                var trimmed = t
                if trimmed.hasSuffix(".") || trimmed.hasSuffix(",") { trimmed.removeLast() }
                let ns = trimmed as NSString
                if let m = money.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)) {
                    func g(_ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
                    let whole = (g(2) ?? "").filter { !".,'’".contains($0) }
                    var value = Decimal(string: "\(whole).\(g(4) ?? "0")", locale: Locale(identifier: "en_US_POSIX")) ?? 0
                    value *= Decimal(g(5).flatMap { mult[$0] } ?? 1)
                    out.amount = NSDecimalNumber(decimal: (value * 100).rounded(0)).int64Value
                    out.income = g(1) == "+"
                    out.currency = out.currency || g(6) != nil || finds(leadingSymbol, t)
                    continue
                }
            }
            if matches(currencyOnly, t) {
                out.currency = true
                continue
            }
            if out.date == nil, let date = dateOf(low, locale) {
                out.date = date
                continue
            }
            if out.walletId == nil, let w = wallets.first(where: { x in
                let n = x.name.lowercased()
                return n == low || n.split(whereSeparator: \.isWhitespace).first.map(String.init) == low
            }) {
                out.walletId = w.id
                continue
            }
            // Vowel signs (Devanagari, Hangul jamo) are marks, not letters.
            let stripped = marks.stringByReplacingMatches(in: low, range: NSRange(low.startIndex..., in: low), withTemplate: "")
            let letters = stripped.unicodeScalars.count
            if out.categoryId == nil, letters >= (cjk(low) ? 2 : 3),
               let c = categories.first(where: { $0.name.lowercased().hasPrefix(low) }) {
                out.categoryId = c.id
                continue
            }
            rest.append(t)
        }
        out.payee = rest.joined(separator: " ")
        out.tags = tags
        return out
    }

    private static let moneyChar = re(#"[0-9€$£₹¥₩₽]"#)

    /// Whether quick add should ask AI to read the line (quick-add.ts needsAi): a leftover sentence word, a currency,
    /// digits inside the payee, a long payee, or no amount in three or more words.
    static func needsAi(_ q: String, _ p: QuickParse, locale: String) -> Bool {
        let tokens = tokenize(q)
        if tokens.count < 2 { return false }
        let ws = p.payee.split(whereSeparator: \.isWhitespace).map { bare(String($0)) }.filter { !$0.isEmpty }
        return p.currency
            || ws.contains { w in
                finds(moneyChar, w) || (!plain(w, locale) && (matches(spaced, w) || (cjk(w) && finds(joined, w))))
            }
            || ws.count > 3
            || (p.amount == nil && tokens.count >= 3)
    }
}
