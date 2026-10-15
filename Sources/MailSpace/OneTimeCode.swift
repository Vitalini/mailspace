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
/// 2. **Disqualified keyword.** `code` does not count when the word before it
///    is one of `disqualifiers` (zip code, promo code, tracking code, …).
/// 3. **Candidate.** A run of 4–8 ASCII digits with no letter or digit
///    directly on either side.
/// 4. **Neighbor rule.** A candidate glued to other number material is
///    rejected: one of `rejectedBefore` directly before it or `rejectedAfter`
///    directly after it, or one of `joiners` directly beside it with a digit on
///    the joiner's other side. A sentence-ending period, a `code:` colon or a
///    `G-` prefix therefore leave a code alone; phone numbers, dates, times,
///    amounts, URL paths and grouped digits do not survive.
/// 5. **Year rule.** A 4-digit candidate from 1900 to 2099 is rejected.
/// 6. **Proximity.** The candidate starts within `window` characters after
///    the end of a qualifying keyword, or ends within `window` characters
///    before its start. Title and body are joined with a newline, which counts
///    as one character.
/// 7. **Uniqueness.** Exactly one distinct candidate survives 3–6, or the
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
        "zip", "postal", "area", "promo", "discount", "coupon", "tracking", "error"
    ]

    static let rejectedBefore: Set<Character> = ["#", "№", "+", "$", "€", "£", "₽", "/"]
    static let rejectedAfter: Set<Character> = ["%", "/"]
    static let joiners: Set<Character> = ["-", ".", ":", ",", " "]

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
            if value == "code", index > 0, disqualifiers.contains(String(text[words[index - 1]])) {
                continue
            }
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

    // MARK: - Rules 3 to 5

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

        if let before, rejectedBefore.contains(before) { return false }
        if let after, rejectedAfter.contains(after) { return false }
        if let before, joiners.contains(before), run.lowerBound >= 2, text[run.lowerBound - 2].isNumber {
            return false
        }
        if let after, joiners.contains(after), run.upperBound + 1 < text.count, text[run.upperBound + 1].isNumber {
            return false
        }

        if run.count == 4, let value = Int(String(text[run])), years.contains(value) { return false }
        return true
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
