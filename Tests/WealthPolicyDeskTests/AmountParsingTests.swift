import XCTest
@testable import WealthPolicyDesk

/// Every money field in intake now parses its own text, so that it can show a prompt when
/// nothing has been entered — a zero that renders as "0" is indistinguishable from an
/// answer, which is the whole reason the dollar defaults were zeroed.
///
/// The first version filtered the input to digits alone. That silently dropped the decimal
/// point, so a figure copied off an SSA statement — "4,123.50" — became 412350: a
/// hundredfold overstatement of guaranteed income, on the very field that asks the client to
/// copy their benefit verbatim.
final class AmountParsingTests: XCTestCase {

    func testACopiedStatementFigureKeepsItsCents() {
        XCTAssertEqual(Fmt.parseAmount("4,123.50"), 4_123.50, accuracy: 0.001)
        XCTAssertEqual(Fmt.parseAmount("$4,123.50"), 4_123.50, accuracy: 0.001)
        XCTAssertEqual(Fmt.parseAmount("4123.50"), 4_123.50, accuracy: 0.001)
        XCTAssertEqual(Fmt.parseAmount(" 4 123.50 "), 4_123.50, accuracy: 0.001)
    }

    func testCommasAreThousandsSeparatorsNotDecimalPoints() {
        XCTAssertEqual(Fmt.parseAmount("1,000,000"), 1_000_000, accuracy: 0.001)
        XCTAssertEqual(Fmt.parseAmount("250,000"), 250_000, accuracy: 0.001)
    }

    func testPlainIntegersAreUnchanged() {
        XCTAssertEqual(Fmt.parseAmount("600000"), 600_000, accuracy: 0.001)
        XCTAssertEqual(Fmt.parseAmount("0"), 0, accuracy: 0.001)
    }

    /// Junk must not become a number, and a second "." must not create one either.
    func testJunkParsesToZeroAndASecondDotIsIgnored() {
        XCTAssertEqual(Fmt.parseAmount(""), 0, accuracy: 0.001)
        XCTAssertEqual(Fmt.parseAmount("abc"), 0, accuracy: 0.001)
        XCTAssertEqual(Fmt.parseAmount("$"), 0, accuracy: 0.001)
        // A separator repeated is GROUPING, which is what makes the EU form "1.234.567" parse
        // as 1234567 rather than as a fraction. Malformed input inherits that reading.
        XCTAssertEqual(Fmt.parseAmount("1.2.3"), 123, accuracy: 0.001)
        XCTAssertEqual(Fmt.parseAmount("1.234.567"), 1_234_567, accuracy: 0.001, "EU grouping")
    }

    /// Zero renders empty so the prompt shows — that is the affordance the whole change
    /// exists for, and a "0" would defeat it.
    func testZeroRendersEmptySoThePromptIsVisible() {
        XCTAssertEqual(Fmt.editableAmount(0), "")
        XCTAssertEqual(Fmt.editableAmount(600_000), "600000")
        XCTAssertEqual(Fmt.editableAmount(4_123.50), "4123.50")
    }

    /// `.decimalPad` renders the DEVICE's decimal separator, which is "," across most of the
    /// EU. Treating "," as grouping unconditionally re-created the hundredfold overstatement
    /// this function exists to prevent — on the keyboard change that was supposed to let the
    /// client type cents in the first place.
    func testACommaDecimalSeparatorIsNotReadAsThousands() {
        XCTAssertEqual(Fmt.parseAmount("4123,50"), 4_123.50, accuracy: 0.001, "German/French entry")
        XCTAssertEqual(Fmt.parseAmount("1.234,56"), 1_234.56, accuracy: 0.001, "and its grouped form")
        XCTAssertEqual(Fmt.parseAmount("4,123.50"), 4_123.50, accuracy: 0.001, "US form still works")
    }

    /// A separator with three digits after it is grouping, not cents — that is what keeps
    /// "250,000" from becoming $250.
    func testThreeDigitGroupsAreNotCents() {
        XCTAssertEqual(Fmt.parseAmount("250,000"), 250_000, accuracy: 0.001)
        XCTAssertEqual(Fmt.parseAmount("250.000"), 250_000, accuracy: 0.001, "the EU grouping form")
        XCTAssertEqual(Fmt.parseAmount("1,000,000"), 1_000_000, accuracy: 0.001)
    }

    /// Every keystroke re-renders through `editableAmount`, which formats whole values via
    /// `Int` — and `Int(Double)` TRAPS above Int64.max. Nineteen digits, reachable by holding
    /// a key on the pad, used to crash the app outright.
    func testALongRunOfDigitsCannotCrashTheField() {
        for digits in [15, 17, 19, 25, 40] {
            let typed = String(repeating: "9", count: digits)
            let parsed = Fmt.parseAmount(typed)
            XCTAssertLessThanOrEqual(parsed, Fmt.maxEnterableAmount, "\(digits) digits must be clamped")
            XCTAssertFalse(Fmt.editableAmount(parsed).isEmpty, "\(digits) digits must still render")
        }
        XCTAssertEqual(Fmt.editableAmount(.infinity), "", "a non-finite value must not reach Int()")
        XCTAssertEqual(Fmt.editableAmount(.nan), "")
    }

    /// Edit, re-render, edit again must not drift — a field the advisor tabs through twice
    /// has to hold its value.
    func testTheFieldRoundTripsWithoutDrift() {
        for v in [0.0, 1.0, 250_000.0, 4_123.50, 1_000_000.0, 0.99] {
            XCTAssertEqual(Fmt.parseAmount(Fmt.editableAmount(v)), v, accuracy: 0.001,
                           "\(v) drifted through a render/parse cycle")
        }
    }
}
