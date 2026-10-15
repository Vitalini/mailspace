import Foundation

/// The one confident sign-in or verification code in a notification's text,
/// or nothing.
///
/// Copying the wrong number silently is worse than showing no button, so every
/// doubt ends in `nil`. This file is the only place the rules are stated:
///
/// 1. **Keyword.** The text contains, case-insensitively and as a whole word,
///    one of `keywords` or `phrases`. `barcode`, `pinned` and `кодировка` are
///    other words; bare "password" and "verify" are deliberately not keywords.
/// 2. **Disqualified keyword.** A keyword does not count when the word before
///    or after it is one of `disqualifiers` (zip code, promo code, код заказа,
///    трек-код, …).
/// 3. **Candidate.** A run of 4–8 ASCII digits with no letter or digit
///    directly on either side.
/// 4. **Neighbor rule.** A candidate glued to other number material is
///    rejected: one of `rejectedBefore` before it or `rejectedAfter` after it,
///    directly or across spaces only, or one of `joiners` directly beside it
///    with a digit on the joiner's other side. A sentence-ending period, a
///    `code:` colon or a `G-` prefix therefore leave a code alone; phone
///    numbers, dates, times, amounts, masked card digits, URL paths and grouped
///    digits do not survive.
/// 5. **Context words.** A candidate is rejected when the word before it, with
///    only spaces and periods between, is one of `precedingWords` (Order No.,
///    card ending, moved to), or the word after it, with only spaces between,
///    is one of `followingWords` (a currency).
/// 6. **Year rule.** A 4-digit candidate from 1900 to 2099 is rejected.
/// 7. **Proximity.** The candidate starts within `window` characters after
///    the end of a qualifying keyword, or ends within `window` characters
///    before its start. Title and body are joined with a newline, which counts
///    as one character.
/// 8. **Uniqueness.** Exactly one distinct candidate survives 3–7, or the
///    result is nothing. The same code in subject and snippet is one code.
///
/// Foundation only, and pure, so `swift test` pins every rule.
enum OneTimeCode {
    static let window = 40
    static let lengths = 4...8
    static let years = 1900...2099

    static let keywords: Set<String> = [
        "code", "codes", "otp", "verification", "passcode", "pin",
        "код", "кода", "коду", "кодом", "коды", "кодів", "кодов"
    ]
    static let phrases = ["one-time password", "одноразовый пароль", "одноразовий пароль"]
    static let disqualifiers: Set<String> = [
        "zip", "postal", "area", "promo", "discount", "coupon", "tracking", "error",
        "order", "referral", "customer",
        "трек", "промо", "заказа", "заказу", "замовлення", "скидки", "купона", "отслеживания", "посылки"
    ]

    static let rejectedBefore: Set<Character> = ["#", "№", "+", "$", "€", "£", "₽", "₴", "/", "*", "•", ")"]
    static let rejectedAfter: Set<Character> = ["%", "/", "$", "€", "£", "₽", "₴"]
    static let joiners: Set<Character> = ["-", ".", ":", ",", " "]
    static let precedingWords: Set<String> = ["no", "order", "ending", "to"]
    static let followingWords: Set<String> = ["usd", "eur", "gbp", "rub", "руб", "uah", "грн"]

    static func extract(title: String, body: String) -> String? {
        let text = Array("\(title)\n\(body)".lowercased())
        let anchors = keywordRanges(in: text)
        guard !anchors.isEmpty else { return nil }

        var found = Set<String>()
        for run in digitRuns(in: text) where isCandidate(run, in: text) {
            let near = anchors.contains { keyword in
                (0...window).contains(run.lowerBound - keyword.upperBound)
                    || (0...window).contains(keyword.lowerBound - run.upperBound)
            }
            if near { found.insert(String(text[run])) }
        }
        return found.count == 1 ? found.first : nil
    }

    // MARK: - Rules 1 and 2

    private static func isWordCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber
    }

    /// Every qualifying keyword or phrase occurrence, as half-open ranges.
    private static func keywordRanges(in text: [Character]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        let words = wordRanges(in: text)
        for (index, word) in words.enumerated() {
            let value = String(text[word])
            guard keywords.contains(value) else { continue }
            let neighbors = [index - 1, index + 1].filter(words.indices.contains)
            if neighbors.contains(where: { disqualifiers.contains(String(text[words[$0]])) }) { continue }
            ranges.append(word)
        }
        for phrase in phrases.map(Array.init) {
            var start = 0
            while start + phrase.count <= text.count {
                let end = start + phrase.count
                if Array(text[start..<end]) == phrase,
                   start == 0 || !isWordCharacter(text[start - 1]),
                   end == text.count || !isWordCharacter(text[end]) {
                    ranges.append(start..<end)
                }
                start += 1
            }
        }
        return ranges
    }

    /// Maximal runs of letters and digits.
    private static func wordRanges(in text: [Character]) -> [Range<Int>] {
        runs(in: text, where: isWordCharacter)
    }

    // MARK: - Rules 3 to 6

    private static func isASCIIDigit(_ c: Character) -> Bool {
        c.isASCII && c.isNumber
    }

    private static func digitRuns(in text: [Character]) -> [Range<Int>] {
        runs(in: text, where: isASCIIDigit)
    }

    private static func isCandidate(_ run: Range<Int>, in text: [Character]) -> Bool {
        guard lengths.contains(run.count) else { return false }

        let before = run.lowerBound > 0 ? text[run.lowerBound - 1] : nil
        let after = run.upperBound < text.count ? text[run.upperBound] : nil
        if let before, isWordCharacter(before) { return false }
        if let after, isWordCharacter(after) { return false }

        if let c = nearest(from: run.lowerBound - 1, step: -1, in: text, skipping: [" "]), rejectedBefore.contains(c) {
            return false
        }
        if let c = nearest(from: run.upperBound, step: 1, in: text, skipping: [" "]), rejectedAfter.contains(c) {
            return false
        }
        if let before, joiners.contains(before), run.lowerBound >= 2, text[run.lowerBound - 2].isNumber {
            return false
        }
        if let after, joiners.contains(after), run.upperBound + 1 < text.count, text[run.upperBound + 1].isNumber {
            return false
        }

        if let word = word(endingBefore: run.lowerBound, in: text), precedingWords.contains(word) { return false }
        if let word = word(startingAfter: run.upperBound, in: text), followingWords.contains(word) { return false }

        if run.count == 4, let value = Int(String(text[run])), years.contains(value) { return false }
        return true
    }

    /// The first character from `index` on, walking by `step`, that is not in
    /// `skipping`; nil at either end of the text.
    private static func nearest(
        from index: Int, step: Int, in text: [Character], skipping: Set<Character>
    ) -> Character? {
        var i = index
        while text.indices.contains(i) {
            if !skipping.contains(text[i]) { return text[i] }
            i += step
        }
        return nil
    }

    /// The word that ends before `index` with only spaces and periods between.
    private static func word(endingBefore index: Int, in text: [Character]) -> String? {
        var end = index
        while end > 0, text[end - 1] == " " || text[end - 1] == "." { end -= 1 }
        var start = end
        while start > 0, isWordCharacter(text[start - 1]) { start -= 1 }
        return start < end ? String(text[start..<end]) : nil
    }

    /// The word that starts after `index` with only spaces between.
    private static func word(startingAfter index: Int, in text: [Character]) -> String? {
        var start = index
        while start < text.count, text[start] == " " { start += 1 }
        var end = start
        while end < text.count, isWordCharacter(text[end]) { end += 1 }
        return start < end ? String(text[start..<end]) : nil
    }

    private static func runs(in text: [Character], where matches: (Character) -> Bool) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var start: Int?
        for (index, c) in text.enumerated() {
            if matches(c) {
                if start == nil { start = index }
            } else if let open = start {
                result.append(open..<index)
                start = nil
            }
        }
        if let open = start { result.append(open..<text.count) }
        return result
    }
}
