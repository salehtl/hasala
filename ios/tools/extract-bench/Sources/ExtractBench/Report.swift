import Foundation

enum Report {
  static let header = ["reader", "change", "group", "mails", "txn found", "false txn", "amount", "currency", "merchant", "none ok", "conf. wrong"]

  static func pct(_ n: Int, _ d: Int) -> String { d == 0 ? "–" : String(format: "%.1f%%", 100 * Double(n) / Double(d)) }

  static func cells(_ r: Row) -> [String] {
    let a = r.tally
    return [
      r.reader, r.kind, r.group, "\(a.mails)",
      "\(a.txnTP)/\(a.txnTrue) " + pct(a.txnTP, a.txnTrue),
      "\(a.txnFP)",
      pct(a.amountRight, a.txnTrue),
      pct(a.currencyRight, a.txnTrue),
      a.merchantTotal == 0 ? "–" : "\(pct(a.merchantExact + a.merchantClose, a.merchantTotal)) (\(a.merchantExact)+\(a.merchantClose)~/\(a.merchantTotal))",
      a.noneTotal == 0 ? "–" : "\(a.merchantNoneRight)/\(a.noneTotal)",
      "\(a.confidentWrong)",
    ]
  }

  static func merge(_ rows: [Row]) -> [Row] {
    var out: [String: Row] = [:]
    var order: [String] = []
    for r in rows {
      let k = r.reader + "|" + r.kind
      if out[k] == nil {
        out[k] = Row(reader: r.reader, kind: r.kind, group: "all", tally: Tally())
        order.append(k)
      }
      var t = out[k]!.tally
      let a = r.tally
      t.mails += a.mails; t.txnTrue += a.txnTrue; t.txnTP += a.txnTP; t.txnFP += a.txnFP; t.txnFN += a.txnFN
      t.amountRight += a.amountRight; t.amountWrong += a.amountWrong; t.amountMissing += a.amountMissing
      t.currencyRight += a.currencyRight; t.merchantExact += a.merchantExact; t.merchantClose += a.merchantClose
      t.merchantWrong += a.merchantWrong; t.merchantMissing += a.merchantMissing; t.merchantNoneRight += a.merchantNoneRight
      t.merchantNoneWrong += a.merchantNoneWrong; t.merchantTotal += a.merchantTotal; t.noneTotal += a.noneTotal
      t.confident += a.confident; t.confidentWrong += a.confidentWrong
      out[k]!.tally = t
    }
    return order.map { out[$0]! }
  }

  static func text(_ rows: [Row]) -> String {
    let all = [header] + rows.map(cells)
    let widths = header.indices.map { i in all.map { $0[i].count }.max() ?? 0 }
    return all.map { r in r.enumerated().map { $0.element.padding(toLength: widths[$0.offset], withPad: " ", startingAt: 0) }.joined(separator: "  ") }
      .joined(separator: "\n")
  }

  static func esc(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
  }

  static func table(_ rows: [Row]) -> String {
    "<table><thead><tr>" + header.map { "<th>\(esc($0))</th>" }.joined() + "</tr></thead><tbody>"
      + rows.map { "<tr>" + cells($0).map { "<td>\(esc($0))</td>" }.joined() + "</tr>" }.joined() + "</tbody></table>"
  }

  static func html(summary: [Row], detail: [Row], notes: [String]) -> String {
    """
    <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Extraction bench</title>
    <style>
    :root{--bg:#fff;--fg:#1a1a1a;--mute:#666;--line:#e3e3e3;--head:#f5f5f5}
    @media (prefers-color-scheme:dark){:root{--bg:#141414;--fg:#eee;--mute:#999;--line:#333;--head:#1f1f1f}}
    body{background:var(--bg);color:var(--fg);font:14px/1.45 -apple-system,system-ui,sans-serif;margin:24px 16px}
    table{border-collapse:collapse;margin:12px 0 28px;font-variant-numeric:tabular-nums}
    th,td{border-bottom:1px solid var(--line);padding:5px 10px;text-align:left;white-space:nowrap}
    th{background:var(--head);font-weight:600}.wrap{overflow-x:auto}p,li{color:var(--mute);max-width:760px}
    </style></head><body><h1>Extraction bench</h1><ul>\(notes.map { "<li>\(esc($0))</li>" }.joined())</ul>
    <h2>All mail</h2><div class="wrap">\(table(summary))</div><h2>By sender</h2><div class="wrap">\(table(detail))</div></body></html>
    """
  }
}
