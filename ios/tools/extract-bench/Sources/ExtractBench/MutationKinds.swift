import Foundation

enum Kinds {
  static func labelSwap(_ line: String, _ table: [(String, String)], caseInsensitive: Bool) -> String? {
    let k = MU.key(line)
    for (a, b) in table where (caseInsensitive ? a.lowercased() : a) == k {
      let colon = line.trimmingCharacters(in: .whitespaces).hasSuffix(":") ? ":" : ""
      return b + colon
    }
    return nil
  }

  static func reword(_ m: Mail, _ t: Truth) -> String? {
    reword(m, t, en: Lexicon.rewordEn, ar: Lexicon.rewordAr, enPhrases: Lexicon.rewordEnPhrases, arPhrases: Lexicon.rewordArPhrases)
  }

  static func rewordUnseen(_ m: Mail, _ t: Truth) -> String? {
    reword(
      m, t, en: HeldOut.rewordEn, ar: HeldOut.rewordAr, enPhrases: HeldOut.rewordEnPhrases, arPhrases: HeldOut.rewordArPhrases)
  }

  static func reword(
    _ m: Mail, _ t: Truth, en: [(String, String)], ar: [(String, String)], enPhrases: [(String, String)],
    arPhrases: [(String, String)]
  ) -> String? {
    MU.protect(m.text, t) { s in
      let ls = MU.lines(s).map { l -> String in
        if let r = labelSwap(l, en, caseInsensitive: true) { return r }
        if let r = labelSwap(l, ar, caseInsensitive: false) { return r }
        var x = MU.replacePhrases(l, enPhrases)
        x = MU.replacePhrases(x, arPhrases)
        return x
      }
      return MU.join(ls)
    }
  }

  static func reorder(_ m: Mail, _ t: Truth) -> String? {
    var ls = MU.lines(m.text)
    let h = MU.hash(m.id)
    let ps = MU.pairs(ls)
    var changed = false
    if ps.count >= 2 {
      let blocks = ps.map { [ls[$0], ls[$0 + 1]] }
      let shift = 1 + h % (ps.count - 1)
      for (n, p) in ps.enumerated() {
        let b = blocks[(n + shift) % ps.count]
        ls[p] = b[0]
        ls[p + 1] = b[1]
      }
      changed = true
    }
    let greetKeys = ["dear ", "عزيزي"]
    if let gi = ls.firstIndex(where: { l in greetKeys.contains { l.lowercased().hasPrefix($0) } }), gi < ls.count - 1 {
      let g = ls.remove(at: gi)
      var end = ls.count
      while end > 0 && ls[end - 1].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
      ls.insert(g, at: end)
      changed = true
    }
    return changed ? MU.join(ls) : nil
  }

  static func fmtBalance(_ f: MU.Found, _ h: Int) -> String {
    let base = Int(f.intPart) ?? 100
    let nv = base * 3 + 1500 + h % 900
    let ip = f.hasComma || nv >= 1000 ? MU.group(String(nv)) : String(nv)
    let frac = f.frac.isEmpty ? "" : "." + String((String(h % 97 + 3) + String(repeating: "0", count: f.frac.count)).prefix(f.frac.count))
    return ip + frac
  }

  static func balanceLine(_ m: Mail, _ t: Truth) -> String? {
    guard let minor = t.amountMinor, let f = MU.findAmount(m.text, minor: minor) else { return nil }
    let h = MU.hash(m.id)
    var ls = MU.lines(m.text)
    var pos = 0
    var acc = 0
    for (i, l) in ls.enumerated() {
      let end = acc + (l as NSString).length
      if f.range.location >= acc && f.range.location <= end { pos = i; break }
      acc = end + 1
    }
    if pos > 0, MU.isLabel(ls[pos - 1]) { pos -= 1 }
    let cur = t.currency ?? "AED"
    let num = fmtBalance(f, h)
    let ar = MU.mainIsArabic(m.text)
    let label = ar ? "الرصيد المتاح" : "Available balance"
    ls.insert(contentsOf: [label, cur + " " + num], at: pos)
    return MU.join(ls)
  }

  static func amountFormat(_ m: Mail, _ t: Truth) -> String? {
    guard let minor = t.amountMinor, let f = MU.findAmount(m.text, minor: minor) else { return nil }
    let h = MU.hash(m.id)
    let ns = m.text as NSString
    var lo = f.range.location
    var hi = f.range.location + f.range.length
    let cur = t.currency
    var codes = ["AED", "Dhs", "DHS", "Dh", "د.إ", "درهم"]
    if let c = cur { codes.append(c) }
    let alt = codes.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
    let left = try! NSRegularExpression(pattern: "(?:\(alt))[ \\u00a0]?$")
    let right = try! NSRegularExpression(pattern: "^[ \\u00a0]?(?:\(alt))(?![A-Za-z])")
    var hadCurrency = false
    let before = ns.substring(to: lo)
    if let r = left.firstMatch(in: before, range: NSRange(location: 0, length: (before as NSString).length)) {
      lo = r.range.location
      hadCurrency = true
    }
    let after = ns.substring(from: hi)
    if let r = right.firstMatch(in: after, range: NSRange(location: 0, length: (after as NSString).length)) {
      hi += r.range.length
      hadCurrency = true
    }
    var num = f.number.replacingOccurrences(of: ",", with: "")
    let ns2 = (h / 4) % 3
    var numChanged = false
    if ns2 == 0 || ns2 == 1 {
      if f.hasComma {
        numChanged = true
      } else if f.intPart.count >= 4 {
        num = MU.group(f.intPart) + (f.frac.isEmpty ? "" : "." + f.frac)
        numChanged = true
      }
    }
    if ns2 == 2 || !numChanged && h % 2 == 0 {
      num = MU.toArabicIndic(num)
    }
    let c = cur ?? (hadCurrency ? "AED" : nil)
    var token = num
    if let c = c {
      let aed = c == "AED"
      switch h % 4 {
      case 0: token = num + " " + c
      case 1: token = aed ? "Dhs " + num : num + " " + c
      case 2: token = aed ? "د.إ " + num : c + num
      default: token = c + num
      }
    }
    return ns.replacingCharacters(in: NSRange(location: lo, length: hi - lo), with: token)
  }

  static func oneLine(_ m: Mail, _ t: Truth) -> String? {
    let ls = MU.lines(m.text)
    let ps = MU.pairs(ls)
    guard !ps.isEmpty else { return nil }
    var out: [String] = []
    var i = 0
    var set = Set(ps)
    while i < ls.count {
      if set.contains(i) {
        let l = ls[i].trimmingCharacters(in: .whitespaces)
        let lab = l.hasSuffix(":") ? l : l + ":"
        out.append(lab + " " + ls[i + 1].trimmingCharacters(in: .whitespaces))
        set.remove(i)
        i += 2
      } else {
        out.append(ls[i])
        i += 1
      }
    }
    return MU.join(out)
  }

  static func translate(_ m: Mail, _ t: Truth, toArabic: Bool) -> String? {
    guard MU.mainIsArabic(m.text) != toArabic else { return nil }
    return MU.protect(m.text, t) { s in
      let table = toArabic ? Lexicon.enToAr : Lexicon.arToEn
      let phr: [(String, String)] = toArabic ? Lexicon.phrases.map { ($0.en, $0.ar) } : Lexicon.arOnlyToEn + Lexicon.phrases.map { ($0.ar, $0.en) }
      let ls = MU.lines(s).map { l -> String in
        let k = toArabic ? MU.key(l) : l.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ":", with: "")
        if let r = table[k] {
          let colon = l.trimmingCharacters(in: .whitespaces).hasSuffix(":") ? ":" : ""
          return r + colon
        }
        return MU.replacePhrases(l, phr)
      }
      return MU.join(ls)
    }
  }

  static func boilerplate(_ m: Mail, _ t: Truth) -> String? {
    boilerplate(m, t) { promo, ar, _ in
      ar ? "اربح استرداد نقدي بقيمة \(promo) درهم عند التسوق هذا الشهر." : "Earn AED \(promo) cashback when you shop with your card this month."
    }
  }

  static func boilerplateUnseen(_ m: Mail, _ t: Truth) -> String? {
    boilerplate(m, t) { promo, ar, h in
      let list = ar ? HeldOut.promoAr : HeldOut.promoEn
      return list[h % list.count].replacingOccurrences(of: "{n}", with: String(promo))
    }
  }

  static func boilerplate(_ m: Mail, _ t: Truth, promoLine: (Int, Bool, Int) -> String) -> String? {
    let h = MU.hash(m.id)
    var promo = [500, 750, 1200, 300, 2000][h % 5]
    if let a = t.amountMinor, Int64(promo) * 100 == a { promo += 50 }
    let phone = ["800 2 3456", "600 5 12345", "+971 4 123 4567", "04 123 4567"][(h / 5) % 4]
    let ar = MU.mainIsArabic(m.text)
    let extra: [String] =
      ar
      ? [
        promoLine(promo, true, h / 20),
        "للاستفسار اتصل بنا على \(phone).",
        "هذه الرسالة سرية ومخصصة للمرسل اليه فقط. اذا استلمتها بالخطأ يرجى حذفها.",
      ]
      : [
        promoLine(promo, false, h / 20),
        "Questions? Call us on \(phone).",
        "This message is confidential and intended for the addressee only. If you received it in error please delete it.",
      ]
    var ls = MU.lines(m.text)
    while let l = ls.last, l.trimmingCharacters(in: .whitespaces).isEmpty { ls.removeLast() }
    return MU.join(ls + extra) + (m.text.hasSuffix("\n") ? "\n" : "")
  }
}

func allMutations() -> [Mutation] {
  let all: [Mutation] = [
    TextMutation(kind: "reword", body: Kinds.reword),
    TextMutation(kind: "reorder", body: Kinds.reorder),
    TextMutation(kind: "balance-line", body: Kinds.balanceLine),
    TextMutation(kind: "amount-format", body: Kinds.amountFormat),
    TextMutation(kind: "one-line", body: Kinds.oneLine),
    TextMutation(kind: "english", body: { Kinds.translate($0, $1, toArabic: false) }),
    TextMutation(kind: "arabic", body: { Kinds.translate($0, $1, toArabic: true) }),
    TextMutation(kind: "boilerplate", body: Kinds.boilerplate),
    TextMutation(kind: "reword-unseen", body: Kinds.rewordUnseen),
    TextMutation(kind: "boilerplate-unseen", body: Kinds.boilerplateUnseen),
  ]
  if let dir = ProcessInfo.processInfo.environment["EB_SELFCHECK"] { MutationSelfCheck.run(dir, all) }
  return all
}
