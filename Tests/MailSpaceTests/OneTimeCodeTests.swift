import XCTest
@testable import MailSpace

/// The fixtures `OneTimeCode` is held to. Every rule in that file has at least
/// one row here that turns red without it; a new false positive or miss found
/// in real mail becomes a new row, not a new rule, unless no rule absorbs it.
final class OneTimeCodeTests: XCTestCase {
    private struct Fixture {
        let title: String
        let body: String
        let expected: String?
        let note: String

        init(_ body: String, title: String = "", _ expected: String?, _ note: String = "") {
            self.title = title
            self.body = body
            self.expected = expected
            self.note = note
        }
    }

    private let positives: [Fixture] = [
        Fixture("Your verification code is 482913", "482913"),
        Fixture("482913 is your Instagram code", "482913", "keyword after the code"),
        Fixture("Slack confirmation code: 731904", "731904"),
        Fixture("Your OTP is 5521", "5521"),
        Fixture("Use passcode 99887766 to sign in", "99887766", "8 digits"),
        Fixture("PIN: 4821", "4821"),
        Fixture("Ваш код подтверждения: 123456", "123456"),
        Fixture("Код для входа 4821", "4821"),
        Fixture("Ваш код підтвердження 739201", "739201"),
        Fixture("Your sign-in code\nYour code is 650214", title: "Acme", "650214",
                "keyword in subject, code in snippet"),
        Fixture("Your code is 650214. Code: 650214", "650214", "a repeat counts once"),
        Fixture("VERIFICATION CODE 318274", "318274", "case-insensitive"),
        Fixture("Your verification code is 482913.", "482913", "sentence-ending period is not a joiner"),
        Fixture("Login code:731904", "731904", "colon after a letter is not a joiner"),
        Fixture("G-482913 is your Google verification code", "482913", "hyphen after a letter is not a joiner"),
        Fixture("Your one-time password is 482913", "482913"),
        Fixture("Одноразовый пароль: 4821", "4821"),
        Fixture("Code 482913 to confirm payment of 1500 USD", "482913", "the amount falls to a currency word"),
        Fixture("Код 482913 для подтверждения. Сумма 15000 ₽", "482913", "the amount falls to a spaced currency sign")
    ]

    private let negatives: [Fixture] = [
        Fixture("Order #123456 has shipped", nil, "no keyword, # neighbor"),
        Fixture("Your order 12345678 is on its way", nil, "no keyword"),
        Fixture("2FA was turned on for your account", nil, "no 4-8 digit run"),
        Fixture("Two-factor (2FA) code settings changed on 15.10.2026", nil, "date, neighbor rule"),
        Fixture("Security code policy changes in 2026", nil, "year rule"),
        Fixture("Your code expires 2026-10-15", nil, "neighbor rule"),
        Fixture("Call +1 555 123 4567 to get your PIN", nil, "space-joined digit groups"),
        Fixture("Total $1234 paid — receipt code inside", nil, "$ neighbor"),
        Fixture("Payment of 1,250.00 USD — code to follow", nil, "no 4-8 digit run"),
        Fixture("Discount 20% with code 2024", nil, "year rule"),
        Fixture("Get your code at example.com/1234567", nil, "/ neighbor"),
        Fixture("Tracking code 12345678 for your parcel", nil, "disqualified keyword"),
        Fixture("Zip code 94103", nil, "disqualified keyword"),
        Fixture("Promo code SAVE2024", nil, "letter-adjacent run"),
        Fixture("Tracking code 1Z999AA10123456784", nil, "letter-adjacent run"),
        Fixture("Your code is ABC48291", nil, "letter-adjacent run, no other rule rejects it"),
        Fixture("Code review requested on PR #4821", nil, "# neighbor"),
        Fixture("Your code is 123456 or use backup code 654321", nil, "uniqueness"),
        Fixture("Your code is 123", nil, "too short"),
        Fixture("Your code is 123456789", nil, "too long"),
        Fixture("New barcode scanner 12345678 shipped", nil, "barcode is not the keyword"),
        Fixture("Message pinned in room 4821", nil, "pinned is not the keyword"),
        Fixture("Codes are attached. Meeting notes from the quarterly planning session, ref 48213", nil,
                "beyond the 40-character window"),
        Fixture("Your code is 123 456", nil, "grouped code, the known miss"),
        Fixture("Your OTP is 2047", nil, "year rule, the known miss"),
        // Order, amount and phone mails: a wrong number copied is worse than no button.
        Fixture("Заказ № 12345678 доставлен. Код для получения придёт в SMS", nil, "№ across a space"),
        Fixture("Order No. 123456 confirmed. Use code THANKS", nil, "preceding word no"),
        Fixture("Списание 15000 ₽. Код подтверждения придет отдельно", nil, "₽ across a space"),
        Fixture("Payment of 1500 USD requires a verification code", nil, "following currency word"),
        Fixture("Call (555) 1234 to reset your PIN", nil, ") across a space"),
        Fixture("Оплата 12500₽ прошла, код заказа отправлен", nil, "₽ after"),
        Fixture("Your order 123456 — verification required", nil, "preceding word order"),
        // Order, track and promo codes named as codes.
        Fixture("Код заказа 12345678. Спасибо за покупку!", nil, "disqualifier after the keyword"),
        Fixture("Трек-код: 80012345", nil, "disqualifier before the keyword"),
        Fixture("Промо-код 202405 на скидку 10%", nil, "disqualifier before the keyword"),
        Fixture("Ваш код скидки 482913", nil, "disqualifier after the keyword"),
        Fixture("Order code 482913 confirmed", nil, "disqualifier before the keyword"),
        Fixture("Referral code 482913", nil, "disqualifier before the keyword"),
        // PIN-changed mails: masked card digits and times.
        Fixture("Карта *4242: PIN-код изменён", nil, "* mask before"),
        Fixture("Карта •4242: PIN-код изменён", nil, "bullet mask before"),
        Fixture("Your card ending 4242: PIN changed", nil, "preceding word ending"),
        Fixture("Team sync moved to 1430. Dial-in PIN below", nil, "preceding word to"),
        // Known miss, kept on the safe side: an amount with a currency prefix the
        // rules do not read survives as a second candidate, so uniqueness drops both.
        Fixture("OTP 482913 for Rs.15000 at AMAZON", nil, "uniqueness, the payment known miss"),
        Fixture("", nil, "empty")
    ]

    func testPositiveFixturesYieldTheirCode() {
        for fixture in positives {
            XCTAssertEqual(
                OneTimeCode.extract(title: fixture.title, body: fixture.body),
                fixture.expected,
                "\(fixture.title) | \(fixture.body) — \(fixture.note)"
            )
        }
    }

    func testNegativeFixturesYieldNothing() {
        for fixture in negatives {
            XCTAssertNil(
                OneTimeCode.extract(title: fixture.title, body: fixture.body),
                "\(fixture.body) — \(fixture.note)"
            )
        }
    }
}
