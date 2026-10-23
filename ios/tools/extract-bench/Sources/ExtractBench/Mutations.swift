import Foundation

enum MutationSelfCheck {
  static func run(_ dir: String, _ muts: [Mutation]) {
    guard let items = try? Corpus.loadSynthetic(dir) else {
      print("selfcheck: cannot load \(dir)")
      return
    }
    print("selfcheck: \(items.count) synthetic cases")
    var bad = 0
    for mu in muts {
      var nils = 0
      var ok = 0
      for (m, t) in items {
        guard let v = mu.apply(m, t) else { nils += 1; continue }
        var fail: [String] = []
        if let a = t.amountMinor, !MU.amountPresent(v.mail.text, minor: a, currency: t.currency) { fail.append("amount") }
        if let mer = t.merchant, !mer.isEmpty, m.text.contains(mer), !v.mail.text.contains(mer) { fail.append("merchant") }
        if v.truth != t { fail.append("truth") }
        if !v.mail.id.hasSuffix("~" + mu.kind) { fail.append("id") }
        if let s = ProcessInfo.processInfo.environment["EB_SHOW"], m.id.contains(s) { print("--- \(mu.kind)\n\(v.mail.text)") }
        if fail.isEmpty { ok += 1 } else {
          bad += 1
          print("  FAIL \(mu.kind) \(m.id): \(fail.joined(separator: ","))")
          if ProcessInfo.processInfo.environment["EB_SELFCHECK_VERBOSE"] != nil { print(v.mail.text) }
        }
      }
      print("selfcheck \(mu.kind): applied \(items.count - nils) nil \(nils) of \(items.count)")
    }
    print("selfcheck failures: \(bad)")
  }
}
