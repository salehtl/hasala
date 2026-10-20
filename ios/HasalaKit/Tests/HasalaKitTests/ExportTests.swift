import HasalaMocks
import HasalaModels
import Testing

@Suite("CSV export")
struct CSVExportTests {
  @Test(arguments: [
    ("=SUM(A1)", "'=SUM(A1)"), ("+971", "'+971"), ("-5", "'-5"), ("@cmd", "'@cmd"),
    ("  =x", "'  =x"), ("\u{A0}+x", "'\u{A0}+x"), ("\tTab", "'\tTab"), ("\u{FF1D}1", "'\u{FF1D}1"),
    ("Carrefour", "Carrefour"), ("a=b", "a=b"), ("", ""),
  ])
  func neutralizesFormulas(input: String, expected: String) {
    #expect(CSVExport.neutralize(input) == expected)
  }

  @Test func quotesAfterNeutralizing() {
    #expect(CSVExport.text("=1,2") == "\"'=1,2\"")
    #expect(CSVExport.field("say \"hi\"") == "\"say \"\"hi\"\"\"")
  }

  @Test func amountsStayNumeric() {
    #expect(CSVExport.decimal(-1_234_567) == "-12345.67")
    #expect(CSVExport.decimal(5) == "0.05")
  }

  @Test func exportsTheLedger() {
    let s = MayaLedger.state
    let rows = s.txns.filter { $0.id == "carrefour" }.map { ExportRow($0, s) }
    let csv = CSVExport.csv(rows)
    #expect(csv == "Date,Description,Amount,Currency,Direction,Category,Merchant,Note,Project,Account\r\n"
      + "2026-10-09,CARREFOUR MALL OF EMIRATES,-342.15,AED,Spending,Groceries,Carrefour,,,Emirates NBD ···4412\r\n")
    #expect(CSVExport.fileName(MayaLedger.now.date) == "hasala-2026-10-10.csv")
  }
}

@Suite("Typed amounts")
struct ParseMinorTests {
  @Test(arguments: [
    ("297", Int64?(297_00)), ("45.15", 45_15), ("45.1", 45_10), ("1,800", 1_800_00), (".5", 50), ("0", 0),
    ("", nil), ("4.567", nil), ("1.2.3", nil), ("-3", nil), ("abc", nil), ("٣", 300), ("١٢٫٥", 12_50),
    ("١٬٨٠٠", 1_800_00), ("۴۵.۱۵", 45_15), ("½", nil), ("Ⅻ", nil),
  ])
  func parses(draft: String, expected: Int64?) {
    #expect(MoneyFormat.parseMinor(draft) == expected)
  }

  @Test(arguments: [
    ("8000,50", Int64?(8_000_50)), ("12,5", 12_50), ("12,", 12_00), ("1,800", 1_800_00), ("8,000,5", 8_000_50),
    ("8000.50", 8_000_50), ("1.234,56", nil), ("12,345", 12_345_00), ("١٢,٥", 12_50),
  ])
  func parsesACommaDecimal(draft: String, expected: Int64?) {
    #expect(MoneyFormat.parseMinor(draft, decimalSeparator: ",") == expected)
  }

  @Test func aPointRegionKeepsCommasAsThousands() {
    #expect(MoneyFormat.parseMinor("1,800.5", decimalSeparator: ".") == 1_800_50)
    #expect(MoneyFormat.parseMinor("12,5") == 125_00)
  }

  @Test func draftsRoundTrip() {
    #expect(MoneyFormat.draft(297_00) == "297.00")
    #expect(MoneyFormat.draft(5) == "0.05")
    #expect(MoneyFormat.parseMinor(MoneyFormat.draft(1_234_56)) == 1_234_56)
  }
}
