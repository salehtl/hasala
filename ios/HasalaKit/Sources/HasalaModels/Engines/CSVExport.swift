// Export (CSV), spec 04 §16.2 T5 / X6: the PWA export's columns (`exportFile.ts`) plus the
// merchant's display name, note, project and account, with spreadsheet-formula
// neutralization on text columns only (F5, R-14).
//
// TODO(spec 04 §19.7): pin against `csv-neutralize.json` once CoreDomain's port and the
// vectors land; this follows the rule as written in §16.2 T5.

public struct ExportRow: Sendable, Hashable {
  public var date: LocalDate
  /// The merchant as the bank wrote it.
  public var description: String
  /// Signed: money out negative.
  public var amount: Money
  public var direction: Direction
  public var category: String
  public var merchant: String
  public var note: String
  public var project: String
  public var account: String

  public init(_ t: Txn, _ s: LedgerState) {
    date = t.postedAt.date
    description = t.provenance?.rawMerchant ?? t.merchant
    amount = .aed(t.direction == .out ? -t.amount.minor : t.amount.minor)
    direction = t.direction
    category = s.category(t.categoryID)?.name ?? ""
    merchant = t.title
    note = t.note
    project = s.project(t.projectID)?.name ?? ""
    account = s.account(t.accountID)?.label ?? ""
  }
}

public enum CSVExport {
  public static let headers = [
    "Date", "Description", "Amount", "Currency", "Direction", "Category", "Merchant", "Note", "Project", "Account",
  ]

  /// The whole file, CRLF line ends and a trailing CRLF, as the PWA writes it.
  public static func csv(_ rows: [ExportRow]) -> String {
    var lines = [headers.map(field).joined(separator: ",")]
    for r in rows {
      let cells: [String] = [
        date(r.date),
        text(r.description),
        decimal(r.amount.minor),
        r.amount.currency,
        r.direction == .out ? "Spending" : "Income",
        text(r.category),
        text(r.merchant),
        text(r.note),
        text(r.project),
        text(r.account),
      ]
      lines.append(cells.joined(separator: ","))
    }
    return lines.joined(separator: "\r\n") + "\r\n"
  }

  /// `hasala-2026-10-10.csv`.
  public static func fileName(_ today: LocalDate) -> String { "hasala-\(date(today)).csv" }

  /// A text cell: neutralized, then quoted.
  public static func text(_ value: String) -> String { field(neutralize(value)) }

  /// Prefixes `'` to a value a spreadsheet would run as a formula: one whose first scalar
  /// is TAB, CR or LF, or whose first scalar after leading blanks is `= + - @` or their
  /// full-width forms.
  public static func neutralize(_ value: String) -> String {
    guard let first = value.unicodeScalars.first else { return value }
    if first == "\t" || first == "\r" || first == "\n" { return "'" + value }
    let blanks: Set<Unicode.Scalar> = [" ", "\t", "\n", "\u{0B}", "\u{0C}", "\r", "\u{A0}"]
    let triggers: Set<Unicode.Scalar> = ["=", "+", "-", "@", "\u{FF1D}", "\u{FF0B}", "\u{FF0D}", "\u{FF20}"]
    if let lead = value.unicodeScalars.first(where: { !blanks.contains($0) }), triggers.contains(lead) {
      return "'" + value
    }
    return value
  }

  /// RFC 4180 quoting when the value holds a quote, a comma or a line break.
  public static func field(_ value: String) -> String {
    let needs = value.unicodeScalars.contains { $0 == "\"" || $0 == "," || $0 == "\r" || $0 == "\n" }
    guard needs else { return value }
    return "\"" + value.split(separator: "\"", omittingEmptySubsequences: false).joined(separator: "\"\"") + "\""
  }

  /// `-123.45`: no grouping, a leading minus.
  public static func decimal(_ minor: Int64) -> String {
    (minor < 0 ? "-" : "") + MoneyFormat.string(minor, style: .exact).replacingCommas()
  }

  /// `2026-10-09`.
  public static func date(_ d: LocalDate) -> String {
    func two(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
    return "\(d.year)-\(two(d.month))-\(two(d.day))"
  }
}

extension String {
  fileprivate func replacingCommas() -> String { String(filter { $0 != "," }) }
}
