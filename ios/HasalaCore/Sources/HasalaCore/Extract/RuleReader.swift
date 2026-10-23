import Foundation

enum RuleReader {

  struct Scored {
    var money: RuleMoney
    var score: Double
    var labelled: Bool
    var verb: Bool
    var clause: String
    var fromSubject: Bool
    var balanceLike: Bool
    var conversion: Bool
  }

  static let sentenceBreak = try! NSRegularExpression(pattern: "[.!?;؛](?=\\s|$)|\\s[-|•]\\s")
  static let justNumber = try! NSRegularExpression(pattern: "^[\\s(]*[A-Za-z]{0,3}\\.?\\s*[\\d.,]+\\s*[A-Za-z]{0,3}[\\s)]*$")
  static let vatPhrase = RuleText.re("القيمه المضافه|value added tax")
  static let stops =
    "(?=\\s+on\\s+(?:your|the|card|\\d)|\\s+(?:with|using|via|by)\\s+(?:your|card|the|a\\s)|\\s+(?:from|in|into|to)\\s+(?:your|the\\s+account|a/c|account|card)|\\s+(?:dated|date|ref|reference|avl|avail|available|balance|for|using|via|card|in\\s+(?:aed|usd)|has|is|was|were)\\b|\\s+\\d{1,2}[-/]\\d|\\s+\\d{1,2}:\\d\\d|\\.\\s|\\.$|,\\s|;|\\s+-\\s|$)"
  static let inlineAt = RuleText.re("(?<![a-z])(?:at|@)\\s+(.+?)" + stops)
  static let inlineAtAr = RuleText.re("(?:لدى|لدي|عند|من متجر|في متجر)\\s+(.+?)(?=\\s+(?:بتاريخ|في|على|علي|باستخدام|بمبلغ|بقيمة|بقيمه)|[.،,؛]|$)")
  static let inlineTo = RuleText.re(
    "(?<![a-z])(?:(?:transferred|sent|paid|payment|transfer|remitted|remittance)\\b(?:(?![.!?](?:\\s|$)).)*?\\bto|towards)\\s+(.+?)" + stops)
  static let inlineFrom = RuleText.re(
    "(?<![a-z])(?:received|credited|transfer|deposit|deposited|remittance|refund|refunded|reversal|reversed)\\b(?:(?![.!?](?:\\s|$)).)*?\\bfrom\\s+(.+?)" + stops)
  static let dateLike = RuleText.re(
    "^\\s*(?:\\d{1,4}[-/.]\\d{1,2}[-/.]\\d{2,4}|\\d{1,2}[-/ ](?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*[-/ ]\\d{2,4}|\\d{1,2}:\\d{2})")
  static let iban = RuleText.re("^[a-z]{2}\\d{2}[a-z0-9x* ]{10,}$")
  static let ownWords = RuleText.re("(?<![a-z])(?:your|you|yours)(?![a-z])|حسابك|بطاقتك|لكم")
  static let bankingWith = RuleText.re("banking with\\s+(.+?)(?:[.!]|$)")

  static func read(_ m: ExtractInput) -> Reading {
    readLines(RuleText.cleanLines(m.text), m)
  }

  static let aedDebitLabel = RuleText.words(
    ["debit", "debited", "deducted", "charged", "billed", "billing", "withdrawn", "equivalent", "local"],
    ["خصم", "المخصوم", "مدين", "يعادل", "المعادل"])

  static func aedAmount(_ m: ExtractInput, foreign: Int64, currency: String) -> Int64? {
    let lines = RuleText.cleanLines(m.text)
    var cands = candidates(lines, lines.map(RuleText.fold), fromSubject: false)
    for i in cands.indices { cands[i].score -= 0.25 * Double(i) }
    let foreignLines = Set(cands.filter { $0.money.currency == currency && $0.money.minor == foreign }.map(\.money.line))
    let eligible = cands.filter {
      $0.money.currency == "AED" && $0.money.explicit && $0.money.minor > 0 && !$0.money.badScale && !$0.balanceLike
        && !$0.fromSubject && !PromoFilter.isPromo($0.clause)
    }
    let tied = eligible.filter {
      foreignLines.contains($0.money.line) || $0.conversion || ($0.labelled && RuleText.has(aedDebitLabel, $0.clause))
    }
    let sameLine = tied.filter { foreignLines.contains($0.money.line) }
    return (sameLine.isEmpty ? tied : sameLine).max { $0.score < $1.score }?.money.minor
  }

  static func readLines(_ lines: [String], _ m: ExtractInput) -> Reading {
    let subject = RuleText.clean(RuleText.asciiDigits(m.subject))
    let folded = lines.map(RuleText.fold)
    let fSubject = RuleText.fold(subject)
    let fBody = folded.joined(separator: "\n")

    var cands = candidates(lines, folded, fromSubject: false)
    if cands.allSatisfy({ $0.score < 3 }) { cands += candidates([subject], [fSubject], fromSubject: true) }
    guard !cands.isEmpty else { return Reading(note: "no money") }
    for i in cands.indices { cands[i].score -= 0.25 * Double(i) }
    let best = cands.max { $0.score < $1.score }!
    let runner = cands.filter { $0.money.minor != best.money.minor || $0.money.currency != best.money.currency }.map(\.score).max()

    let heading = folded.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
    let hardNeg = RuleText.has(RuleLexicon.hardNegative, fSubject) || RuleText.has(RuleLexicon.hardNegative, best.clause)
      || RuleText.has(RuleLexicon.hardNegative, heading)
    let verbAnywhere = RuleText.has(RuleLexicon.txnVerb, fSubject) || RuleText.has(RuleLexicon.txnVerb, fBody)
    let grounded = best.labelled || best.verb
    var notes: [String] = []
    if hardNeg { return Reading(confidence: 0, note: "negative word", negative: true) }
    guard best.score >= 3, grounded, verbAnywhere else {
      return Reading(note: "weak money score \(best.score)")
    }
    if best.labelled { notes.append("amount label") }
    if best.verb { notes.append("verb by amount") }
    if best.fromSubject { notes.append("subject amount") }

    let (dir, dirStrong, dirMargin) = direction(clause: best.clause, subject: fSubject, body: fBody)
    notes.append("dir \(dir)\(dirStrong ? "" : " weak")")

    let banks = ownBankNames(lines, folded)
    let (merchant, msource) = merchant(lines, folded, banks: banks)
    if let s = msource { notes.append("merchant " + s) }

    var c = 45
    if best.money.explicit { c += 15 } else { c -= 5 }
    if best.labelled { c += 10 }
    if best.verb { c += 15 }
    if RuleText.has(RuleLexicon.maskedRef, fBody) || RuleText.has(RuleLexicon.maskedRef, fSubject) { c += 5 }
    let anyCredit = RuleText.has(RuleLexicon.credit, fBody) || RuleText.has(RuleLexicon.credit, fSubject)
    if dirStrong { c += 10 } else if dirMargin == 0 { c -= anyCredit ? 15 : 5 }
    if best.labelled && best.money.explicit && msource == "label" { c += 10 }
    if let r = runner {
      let gap = best.score - r
      if gap < 1.5 { c -= 25 } else if gap < 3 { c -= 8 }
    }
    if best.fromSubject { c -= 15 }
    if m.listUnsubscribe { c -= 30; notes.append("list-unsubscribe") }
    if RuleText.has(RuleLexicon.softNegative, fBody) || RuleText.has(RuleLexicon.softNegative, fSubject) {
      c -= 15
      notes.append("soft negative")
    }
    if msource == "weak-label" || msource == "inline-to" || msource == "inline-from" { c -= 5 }
    c = min(95, max(5, c))

    return Reading(
      isTransaction: true, amountMinor: best.money.minor, currency: best.money.currency, currencyExplicit: best.money.explicit,
      merchant: merchant, direction: dir, directionGuessed: dirMargin == 0, confidence: c, note: notes.joined(separator: "; "))
  }

  static func prevLabel(_ lines: [String], _ i: Int) -> String {
    var j = i - 1
    var steps = 0
    while j >= 0 && steps < 3 {
      let l = lines[j]
      if l.isEmpty || l.hasPrefix("(") { j -= 1; steps += 1; continue }
      return l
    }
    return ""
  }

  static func nextLine(_ lines: [String], _ i: Int) -> String {
    var j = i + 1
    while j < lines.count {
      if !lines[j].isEmpty { return lines[j] }
      j += 1
    }
    return ""
  }

  static func nextLines(_ lines: [String], _ i: Int, _ n: Int) -> String {
    var out: [String] = []
    var j = i + 1
    while j < lines.count && out.count < n {
      if !lines[j].isEmpty { out.append(lines[j]) }
      j += 1
    }
    return out.joined(separator: " ")
  }

  static func clauseBounds(_ s: NSString, _ start: Int, _ end: Int) -> (String, String) {
    var pStart = 0
    var sEnd = s.length
    for b in Self.sentenceBreak.matches(in: s as String, range: NSRange(location: 0, length: s.length)) {
      if b.range.location + b.range.length <= start { pStart = b.range.location + b.range.length }
      if b.range.location >= end && b.range.location < sEnd { sEnd = b.range.location }
    }
    return (s.substring(with: NSRange(location: pStart, length: start - pStart)), s.substring(with: NSRange(location: end, length: sEnd - end)))
  }

  static func candidates(_ lines: [String], _ folded: [String], fromSubject: Bool) -> [Scored] {
    var out: [Scored] = []
    for (i, line) in lines.enumerated() where line.contains(where: { $0.isNumber }) {
      let ns = line as NSString
      var lastEnd: (line: Int, end: Int)? = nil
      let isJust = RuleText.has(Self.justNumber, line)
      let label = fromSubject ? "" : prevLabel(lines, i)
      let labelCur = isJust ? RuleMoneyParser.labelCurrency(label) : nil
      for mo in RuleMoneyParser.scan(line, line: i, labelCurrency: labelCur) {
        let (pre, suf) = clauseBounds(ns, mo.start, mo.end)
        let preStrip = Self.stripMoneyWords(pre)
        let sufStrip = Self.stripMoneyWords(suf)
        let useLabel = !fromSubject && !preStrip.contains(where: { $0.isLetter })
        let useNext = !fromSubject && !sufStrip.contains(where: { $0.isLetter })
        let fPre = RuleText.fold(pre)
        let fSuf = RuleText.fold(suf)
        let fPreTail = String(fPre.suffix(32))
        let fLabel = useLabel && label.count <= 60 ? RuleText.fold(label) : ""
        let fNext = useNext ? String(RuleText.fold(nextLines(lines, i, 3)).prefix(70)) : ""
        let labelNoVat = Self.vatPhrase.stringByReplacingMatches(
          in: fLabel, range: NSRange(location: 0, length: (fLabel as NSString).length), withTemplate: " ")
        let preNoVat = Self.vatPhrase.stringByReplacingMatches(
          in: fPreTail, range: NSRange(location: 0, length: (fPreTail as NSString).length), withTemplate: " ")

        var s = 0.0
        var balanceLike = false
        var conversion = false
        if mo.explicit { s += 2 } else if mo.decimals == RuleMoneyParser.exponent(mo.currency) && mo.decimals > 0 { s += 1 } else if mo.grouped || mo.decimals > 0 { s += 0.5 } else if !isJust { continue }
        let labelled = RuleText.has(RuleLexicon.amountLabel, preNoVat) || RuleText.has(RuleLexicon.amountLabel, labelNoVat)
        if labelled { s += 3 }
        let verb = RuleText.has(RuleLexicon.txnVerb, fPre) || RuleText.has(RuleLexicon.txnVerb, fSuf)
          || RuleText.has(RuleLexicon.txnVerb, fNext) || (isJust && RuleText.has(RuleLexicon.txnVerb, fLabel))
        if verb { s += 2 }
        if RuleText.has(RuleLexicon.balance, fPreTail) || RuleText.has(RuleLexicon.balance, fLabel) { s -= 6; balanceLike = true }
        if RuleText.has(RuleLexicon.balance, String(fSuf.prefix(25))) { s -= 3; balanceLike = true }
        if RuleText.has(RuleLexicon.fee, fPreTail) || RuleText.has(RuleLexicon.fee, labelNoVat) {
          balanceLike = true
          s -= RuleText.has(Self.postingVerb, fSuf) || RuleText.has(Self.postingVerb, fNext) ? 1 : 3
        }
        if let prev = lastEnd, prev.line == i, Self.isConversion(ns, from: prev.end, to: mo.start) { s -= 2.5; conversion = true }
        lastEnd = (i, mo.end)
        if RuleText.has(RuleLexicon.rate, fPreTail) || RuleText.has(RuleLexicon.rate, fLabel) { s -= 5; balanceLike = true }
        if mo.badScale { s -= 5 }
        if mo.minor == 0 { s -= 4 }
        if !isJust && !labelled && !verb && !mo.explicit { s -= 1 }
        let clause = [fPre, fSuf, fLabel, fNext].joined(separator: " ")
        out.append(
          Scored(
            money: mo, score: s, labelled: labelled, verb: verb, clause: clause, fromSubject: fromSubject,
            balanceLike: balanceLike, conversion: conversion))
      }
    }
    return out
  }

  static let postingVerb = RuleText.words(
    ["debited", "deducted", "charged", "credited", "withdrawn", "collected", "levied", "applied"], ["خصم", "تم خصم", "استيفاء"])

  static func isConversion(_ ns: NSString, from a: Int, to b: Int) -> Bool {
    guard b > a, b - a <= 8 else { return false }
    let gap = ns.substring(with: NSRange(location: a, length: b - a))
    return gap.contains("(") || gap.contains("≈") || gap.contains("~") || gap.lowercased().contains("eq")
  }

  static let typeOnly = RuleText.re(
    "^(?:purchase|debit|credit|payment|transfer|refund|pos|ecom|e-commerce|online|transaction|شراء|مشتريات|خصم|ايداع|تحويل|دفع)$")

  static let moneyWords = RuleText.re(
    "(?<![a-z])(?:aed|usd|eur|gbp|sar|qar|kwd|bhd|omr|inr|dhs?)\\.?(?![a-z])|د\\.إ\\.?|دراهم|درهم|[$€£₹()\\[\\]:*.,\\-]")

  static func stripMoneyWords(_ s: String) -> String {
    moneyWords.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: " ")
      .trimmingCharacters(in: .whitespaces)
  }

  static func direction(clause: String, subject: String, body: String) -> (String, Bool, Double) {
    func scrub(_ s: String) -> String {
      RuleLexicon.directionNoise.stringByReplacingMatches(
        in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: " ")
    }
    let parts: [(String, Double)] = [(scrub(clause), 3), (scrub(subject), 2), (scrub(body), 1)]
    var d = 0.0, c = 0.0
    var cd = 0, cc = 0
    for (k, (t, w)) in parts.enumerated() {
      let nd = Double(min(3, RuleText.count(RuleLexicon.debit, t)))
      let nc = Double(min(3, RuleText.count(RuleLexicon.credit, t)) + 2 * min(1, RuleText.count(RuleLexicon.incomingTransfer, t)))
      d += nd * w
      c += nc * w
      if k == 0 { cd = Int(nd); cc = Int(nc) }
    }
    let dir = c > d ? "credit" : "debit"
    let strong = dir == "credit" ? (cc > 0 && cd == 0) : (cd > 0 && cc == 0)
    return (dir, strong, abs(c - d))
  }

  static func ownBankNames(_ lines: [String], _ folded: [String]) -> Set<String> {
    var out: Set<String> = []
    for (i, f) in folded.enumerated() {
      if RuleText.has(RuleLexicon.closing, f) {
        let n = nextLine(lines, i)
        if !n.isEmpty { out.insert(RuleText.norm(n)) }
      }
      let ns = f as NSString
      if let m = Self.bankingWith.firstMatch(in: f, range: NSRange(location: 0, length: ns.length)) {
        out.insert(RuleText.norm(ns.substring(with: m.range(at: 1))))
      }
    }
    return out
  }

  static func labelKey(_ f: String) -> String {
    var s = f.trimmingCharacters(in: .whitespaces)
    while let l = s.last, l == ":" || l == "：" || l == "-" || l == " " { s.removeLast() }
    return s
  }

  static func validMerchant(_ raw: String, banks: Set<String>) -> String? {
    var v = raw.trimmingCharacters(in: .whitespaces)
    while let l = v.last, l == "." || l == "," || l == ":" || l == ";" { v.removeLast() }
    v = v.trimmingCharacters(in: .whitespaces)
    if v.isEmpty || v.count > 70 { return nil }
    if !v.contains(where: { $0.isLetter }) { return nil }
    let f = RuleText.fold(v)
    if RuleText.has(Self.ownWords, f) { return nil }
    if RuleText.has(Self.dateLike, f) { return nil }
    if RuleText.has(Self.iban, f) { return nil }
    let nonSpace = v.filter { !$0.isWhitespace }
    let maskish = nonSpace.filter { $0.isNumber || $0 == "X" || $0 == "x" || $0 == "*" || $0 == "-" }
    let maskRun = v.contains("XXX") || v.contains("xxx") || v.contains("***")
    if (v.contains(where: { $0.isNumber }) || maskRun) && Double(maskish.count) >= 0.6 * Double(nonSpace.count) { return nil }
    if v.hasPrefix("[") && v.hasSuffix("]") { return nil }
    if v.count < 40 && RuleText.has(RuleLexicon.greeting, f) { return nil }
    if RuleText.has(RuleLexicon.statusValue, f) { return nil }
    if RuleText.has(Self.typeOnly, f) { return nil }
    if RuleText.has(RuleLexicon.closing, f) { return nil }
    let key = Self.labelKey(f)
    if RuleLexicon.otherLabels.contains(key) || RuleLexicon.strongMerchantLabels.contains(key)
      || RuleLexicon.weakMerchantLabels.contains(key)
    {
      return nil
    }
    if RuleMoneyParser.scan(v, line: 0, labelCurrency: nil).contains(where: { $0.explicit }) { return nil }
    if banks.contains(RuleText.norm(v)) { return nil }
    return v
  }

  static func labelValue(_ lines: [String], _ folded: [String], _ i: Int) -> (String, String)? {
    let f = folded[i]
    if let colon = f.firstIndex(where: { $0 == ":" || $0 == "：" }) {
      let key = Self.labelKey(String(f[..<colon]))
      let rawLine = lines[i]
      if let rc = rawLine.firstIndex(where: { $0 == ":" || $0 == "：" }) {
        let val = String(rawLine[rawLine.index(after: rc)...]).trimmingCharacters(in: .whitespaces)
        if !val.isEmpty { return (key, val) }
      }
    }
    let key = Self.labelKey(f)
    guard key.count <= 40 else { return nil }
    guard i + 1 < lines.count else { return (key, "") }
    return (key, lines[i + 1])
  }

  static func merchant(_ lines: [String], _ folded: [String], banks: Set<String>) -> (String?, String?) {
    var weak: String?
    var strong: String?
    for i in lines.indices where !lines[i].isEmpty {
      guard let (key, val) = labelValue(lines, folded, i) else { continue }
      if strong == nil, RuleLexicon.strongMerchantLabels.contains(key) {
        if let v = validMerchant(val, banks: banks) { strong = v }
      } else if weak == nil, RuleLexicon.weakMerchantLabels.contains(key) {
        if let v = validMerchant(val, banks: banks) { weak = v }
      }
    }
    if let s = strong { return (s, "label") }
    for r in [Self.inlineAt, Self.inlineAtAr] {
      for line in lines where !line.isEmpty {
        let ns = line as NSString
        for m in r.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
          if let v = validMerchant(ns.substring(with: m.range(at: 1)), banks: banks) { return (v, "inline-at") }
        }
      }
    }
    if let w = weak { return (w, "weak-label") }
    for (r, tag) in [(Self.inlineTo, "inline-to"), (Self.inlineFrom, "inline-from")] {
      for line in lines where !line.isEmpty {
        let ns = line as NSString
        for m in r.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
          if let v = validMerchant(ns.substring(with: m.range(at: 1)), banks: banks) { return (v, tag) }
        }
      }
    }
    return (nil, nil)
  }
}
