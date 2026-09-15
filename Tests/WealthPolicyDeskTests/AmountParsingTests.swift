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
        XCTAssertEqual(Fmt.parseAmount("1.2.3"), 1.23, accuracy: 0.001, "only the first separator is a decimal point")
    }

    /// Zero renders empty so the prompt shows — that is the affordance the whole change
    /// exists for, and a "0" would defeat it.
    func testZeroRendersEmptySoThePromptIsVisible() {
        XCTAssertEqual(Fmt.editableAmount(0), "")
        XCTAssertEqual(Fmt.editableAmount(600_000), "600000")
        XCTAssertEqual(Fmt.editableAmount(4_123.50), "4123.50")
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
