import HasalaModels
import Testing

@testable import HasalaDesign

/// The amount keypad's input rules (page 11 · Behaviour): input that breaks a rule is ignored,
/// so there is nothing to correct afterwards. Amounts are integer fils.
@Suite("Amount entry")
struct KeypadTests {
  private func typed(_ keys: [AmountKey]) -> AmountEntry {
    var e = AmountEntry()
    for k in keys { e.type(k) }
    return e
  }

  @Test func leadingZerosCollapse() {
    let e = AmountEntry(typing: "007")
    #expect(e.text == "7")
    #expect(e.minor == 7_00)
    #expect(AmountEntry(typing: "000").text == "0")
    #expect(AmountEntry(typing: "0.07").minor == 7)
  }

  @Test func aSecondPointIsIgnored() {
    let e = AmountEntry(typing: "12.3.4")
    #expect(e.text == "12.34")
    #expect(e.minor == 12_34)
  }

  @Test func aThirdDecimalIsIgnored() {
    let e = AmountEntry(typing: "48.505")
    #expect(e.text == "48.50")
    #expect(e.minor == 48_50)
  }

  @Test func minorIsInFils() {
    #expect(AmountEntry(typing: "25000").minor == 25_000_00)
    #expect(AmountEntry(typing: "12.").minor == 12_00)
    #expect(AmountEntry(typing: "12.5").minor == 12_50)
    #expect(AmountEntry(typing: "0.").minor == 0)
    #expect(AmountEntry().minor == nil)
    #expect(AmountEntry().isZero)
    #expect(AmountEntry(typing: "0.00").isZero)
    #expect(!AmountEntry(typing: "0.01").isZero)
  }

  @Test func nineWholeDigitsAtMost() {
    let e = AmountEntry(typing: "1234567890")
    #expect(e.text == "123456789")
    #expect(e.minor == 123_456_789_00)
    // Decimals still go in after nine whole digits.
    #expect(AmountEntry(typing: "999999999.99").minor == 999_999_999_99)
  }

  @Test func aPointFirstMeansZeroPoint() {
    #expect(typed([.decimal, .digit(5)]).text == "0.5")
    #expect(typed([.decimal, .digit(5)]).minor == 50)
  }

  @Test func deleteRemovesOneCharacterAndHoldClears() {
    var e = AmountEntry(typing: "48.5")
    e.type(.delete)
    #expect(e.text == "48.")
    e.type(.delete)
    #expect(e.text == "48")
    e.clear()
    #expect(e.isEmpty)
    var zero = AmountEntry(typing: "0.")
    zero.type(.delete)
    #expect(zero.isEmpty)
    var empty = AmountEntry()
    empty.type(.delete)
    #expect(empty.isEmpty)
  }

  @Test func thousandsGetCommasAsYouType() {
    #expect(AmountEntry(typing: "25000").display == "25,000")
    #expect(AmountEntry(typing: "1234567.8").display == "1,234,567.8")
    #expect(AmountEntry(typing: "12.").display == "12.")
    #expect(AmountEntry().display == "0")
  }

  @Test func savedAmountsOpenAsTheyRead() {
    #expect(AmountEntry(minor: 25_000_00).text == "25000")
    #expect(AmountEntry(minor: 297_50).text == "297.50")
    #expect(AmountEntry(minor: 297_05).display == "297.05")
    #expect(AmountEntry(minor: 25_000_00).minor == 25_000_00)
  }

  @Test func voiceOverReadsDirhams() {
    #expect(AmountEntry(typing: "48").spoken() == "48 dirhams")
    #expect(AmountEntry(typing: "25000").spoken() == "25,000 dirhams")
    #expect(AmountEntry(typing: "5").spoken(unit: "USD") == "USD 5")
  }

  @Test func arabicIndicDigitsCount() {
    #expect(AmountEntry(typing: "١٢٫٥").minor == 12_50)
    #expect(AmountEntry(typing: "۲۵۰۰۰").display == "25,000")
    #expect(AmountEntry(typing: "١٢.٣٤").text == "12.34")
  }

  @Test func aTypedCommaIsThePointWhereTheRegionUsesOne() {
    #expect(AmountEntry(editing: "12,", previous: "12", decimalSeparator: ",").text == "12.")
    #expect(AmountEntry(editing: "12.5", previous: "12.", decimalSeparator: ",").minor == 12_50)
    #expect(AmountEntry(editing: "12,5", previous: "", decimalSeparator: ",").minor == 12_50)
    #expect(AmountEntry(editing: "1,800,", previous: "1,800", decimalSeparator: ",").text == "1800.")
    #expect(AmountEntry(editing: "1,8005", previous: "1,800", decimalSeparator: ",").text == "18005")
  }

  @Test func deletingKeepsThousandsCommasOutOfTheFigure() {
    #expect(AmountEntry(editing: "1,80", previous: "1,800", decimalSeparator: ",").text == "180")
    #expect(AmountEntry(editing: "1,80", previous: "1,800", decimalSeparator: ".").text == "180")
  }

  @Test func aPointRegionIgnoresATypedComma() {
    #expect(AmountEntry(editing: "12,5", previous: "12", decimalSeparator: ".").text == "125")
  }

  @Test func clampsToTheLargestAmount() {
    #expect(AmountEntry.clamped(1_000_000_000_00) == 999_999_999_99)
    #expect(AmountEntry.clamped(-5) == 0)
    #expect(AmountEntry.clamped(48_00) == 48_00)
    #expect(AmountEntry(minor: AmountEntry.maxMinor).minor == AmountEntry.maxMinor)
    #expect(AmountEntry(typing: MoneyFormat.string(AmountEntry.maxMinor)).minor == AmountEntry.maxMinor)
  }

  @Test func digitsOutsideZeroToNineAreIgnored() {
    var e = AmountEntry()
    e.type(.digit(12))
    #expect(e.isEmpty)
  }
}
