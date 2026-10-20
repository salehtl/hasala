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
    #expect(csv == "Date,Description,Amount,Currency,AED amount,Direction,Category,Merchant,Note,Project,Account\r\n"
      + "2026-10-09,CARREFOUR MALL OF EMIRATES,-342.15,AED,-342.15,Spending,Groceries,Carrefour,,,Emirates NBD ···4412\r\n")
    #expect(CSVExport.fileName(MayaLedger.now.date) == "hasala-2026-10-10.csv")
  }
}

@Suite("Typed amounts")
struct ParseMinorTests {
  @Test(arguments: [
    ("297", Int64?(297_00)), ("45.15", 45_15), ("45.1", 45_10), ("1,800", 1_800_00), (".5", 50), ("0", 0),
    ("", nil), ("4.567", nil), ("1.2.3", nil), ("-3", nil), ("abc", nil), ("٣", nil),
  ])
  func parses(draft: String, expected: Int64?) {
    #expect(MoneyFormat.parseMinor(draft) == expected)
  }

  @Test func draftsRoundTrip() {
    #expect(MoneyFormat.draft(297_00) == "297.00")
    #expect(MoneyFormat.draft(5) == "0.05")
    #expect(MoneyFormat.parseMinor(MoneyFormat.draft(1_234_56)) == 1_234_56)
  }
}
