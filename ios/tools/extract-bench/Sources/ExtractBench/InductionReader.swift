import Foundation

final class InductionLayout {
  var template: [IElem]
  var examples: [[IToken]]
  var seen: Int
  var lastUsed: Int
  var keys: Set<Int32>
  var analysis: IAnalysis?
  var applied: [IApplied] = []

  init(_ toks: [IToken], now: Int) {
    template = toks.map(IElem.from)
    examples = [toks]
    seen = 1
    lastUsed = now
    keys = Set(toks.map(\.code).filter { $0 > 0 })
  }
}

struct IAnalysis {
  var amountElem: Int?
  var amountSupport: Double
  var amountAmbiguous: Bool
  var merchantGap: Int?
  var merchantLong: Bool
  var merchantVaries: Bool
}

final class InductionReader: Reader {
  let name = "learned"
  static let minExamples = 2
  static let maxExamples = 16
  static let maxLayouts = 40
  static let joinFit = 0.75
  static let spawnBelow = 0.9

  var senders: [String: [InductionLayout]] = [:]
  var interner = IInterner()
  var clock = 0

  func reset() {
    senders = [:]
    interner.reset()
    clock = 0
  }

  func read(_ m: Mail) -> Reading {
    clock += 1
    let toks = ITokenizer.tokenize(subject: m.subject, text: m.text, interner: interner)
    let sender = m.sender.lowercased()
    var layouts = senders[sender] ?? []
    let keySet = Set(toks.map(\.code).filter { $0 > 0 })

    var best: (InductionLayout, IApplied)?
    let ranked = layouts.map { l -> (InductionLayout, Double) in
      let inter = Double(l.keys.intersection(keySet).count)
      let uni = Double(max(1, l.keys.union(keySet).count))
      return (l, inter / uni)
    }.filter { $0.1 >= 0.3 }.sorted { $0.1 > $1.1 }.prefix(4)
    for (l, _) in ranked {
      let a = IAlign.apply(l.template, toks)
      if a.fit >= Self.joinFit && a.fit > (best?.1.fit ?? 0) { best = (l, a) }
    }

    let layout: InductionLayout
    var preFit = 0.0
    var revised = false
    if let (l, pre) = best {
      layout = l
      preFit = pre.fit
      let newT = IAlign.fold(l.template, toks)
      l.examples.append(toks)
      l.seen += 1
      l.lastUsed = clock
      if newT != l.template || l.analysis == nil {
        revised = l.analysis != nil
        l.template = newT
        l.keys = Set(newT.filter { $0.kind == .const && $0.code > 0 }.map(\.code))
        l.applied = l.examples.map { IAlign.apply(newT, $0) }
      } else {
        l.applied.append(IAlign.apply(newT, toks))
      }
      if l.examples.count > Self.maxExamples {
        let drop = l.examples.count - Self.maxExamples
        l.examples.removeFirst(drop)
        l.applied.removeFirst(drop)
      }
      l.analysis = analyze(l)
      if revised && preFit < Self.spawnBelow { addLayout(toks, to: &layouts) }
    } else {
      layout = addLayout(toks, to: &layouts)
    }
    senders[sender] = layouts

    var r: Reading
    if layout.seen < Self.minExamples || layout.analysis == nil {
      r = bare(toks, m)
      r.note = "unlearned layout (\(layout.seen) seen); " + r.note
    } else {
      r = learned(layout, toks, m, preFit: preFit, revised: revised)
    }
    if ProcessInfo.processInfo.environment["INDUCTION_DEBUG"] != nil { debugDump(layout, m, r) }
    return r
  }

  func debugDump(_ l: InductionLayout, _ m: Mail, _ r: Reading) {
    let s = l.template.enumerated().map { (i, e) -> String in
      switch e.kind {
      case .gap: return "[G\(i)]"
      case .typed: return "<\(e.cls)>"
      case .const: return e.cls == .nl ? "/" : e.key
      }
    }.joined(separator: " ")
    let a = l.analysis
    print("RD \(m.id) tx=\(r.isTransaction) \(r.amountMinor ?? -1) \(r.currency ?? "-") m=\(r.merchant ?? "-") \(r.direction ?? "-") c=\(String(format: "%.2f", r.confidence)) | \(r.note)")
    print("DBG \(m.id) amt=\(String(describing: a?.amountElem)) mer=\(String(describing: a?.merchantGap))\n  \(s)")
  }

  @discardableResult
  func addLayout(_ toks: [IToken], to layouts: inout [InductionLayout]) -> InductionLayout {
    let l = InductionLayout(toks, now: clock)
    layouts.append(l)
    if layouts.count > Self.maxLayouts, let idx = layouts.indices.min(by: { layouts[$0].lastUsed < layouts[$1].lastUsed }) {
      layouts.remove(at: idx)
    }
    return l
  }

  func lineTokens(_ toks: [IToken], line: Int) -> [Int] {
    toks.indices.filter { toks[$0].line == line && toks[$0].cls != .nl }
  }

  func leftContext(_ toks: [IToken], _ idx: Int, n: Int = 5) -> [String] {
    var out: [String] = []
    let line = toks[idx].line
    var i = idx - 1
    while i >= 0, toks[i].line == line, toks[i].cls != .nl, out.count < n {
      if toks[i].cls == .punct && toks[i].key == "." { return out }
      if toks[i].cls == .word { out.append(toks[i].key) }
      i -= 1
    }
    let prevHasMoney = toks.contains { $0.line == line - 1 && $0.cls == .money }
    if out.count < 2 && !prevHasMoney {
      var j = i
      while j >= 0, toks[j].line >= line - 1 {
        if toks[j].line == line - 1 && toks[j].cls == .word && out.count < n { out.append(toks[j].key) }
        j -= 1
      }
    }
    return out
  }

  func rightContext(_ toks: [IToken], _ idx: Int, n: Int = 3) -> [String] {
    var out: [String] = []
    var i = idx + 1
    while i < toks.count, out.count < n, toks[i].cls != .nl {
      if toks[i].cls == .word { out.append(toks[i].key) }
      i += 1
    }
    return out
  }

  func amountScore(_ toks: [IToken], _ idx: Int) -> Int {
    var s = 0
    let left = leftContext(toks, idx)
    for (d, k) in left.enumerated() {
      if ILex.balanceWords.contains(k) { s -= d < 4 ? 4 : 2 }
      if ILex.amountWords.contains(k) { s += 2 }
    }
    for k in rightContext(toks, idx) {
      if ILex.direction(k) != nil { s += 2 }
      if ILex.balanceWords.contains(k) { s -= 1 }
    }
    return s
  }

  func currency(_ toks: [IToken], _ idx: Int) -> String {
    if idx > 0, toks[idx - 1].cls == .cur, let c = ILex.currency(toks[idx - 1].raw) { return c }
    if idx + 1 < toks.count, toks[idx + 1].cls == .cur, let c = ILex.currency(toks[idx + 1].raw) { return c }
    return "AED"
  }

  func direction(_ toks: [IToken], amountAt idx: Int?) -> (String?, Int) {
    func nearest(_ ids: [Int], from: Int) -> String? {
      var bestD = Int.max
      var best: String?
      for i in ids {
        if let d = ILex.direction(toks[i].key) {
          let dist = abs(i - from)
          if dist < bestD { bestD = dist; best = d }
        }
      }
      return best
    }
    if let idx = idx {
      let line = toks[idx].line
      if let d = nearest(lineTokens(toks, line: line), from: idx) { return (d, 0) }
      if line > 1, let d = nearest(lineTokens(toks, line: line - 1), from: idx) { return (d, 1) }
      if let d = nearest(lineTokens(toks, line: line + 1), from: idx) { return (d, 1) }
    }
    if let d = nearest(lineTokens(toks, line: 0), from: 0) { return (d, 1) }
    for t in toks { if let d = ILex.direction(t.key) { return (d, 2) } }
    return (nil, 3)
  }

  func excluded(_ toks: [IToken], amountAt idx: Int) -> Bool {
    let line = toks[idx].line
    var wordsPerLine: [Int: Int] = [:]
    for t in toks where t.cls == .word && abs(t.line - line) <= 3 { wordsPerLine[t.line, default: 0] += 1 }
    for (i, t) in toks.enumerated() where ILex.excludeWords.contains(t.key) {
      if t.line == 0 { return true }
      if t.line == line && abs(i - idx) <= 12 { return true }
      if t.line != line && abs(t.line - line) <= 3 && (wordsPerLine[t.line] ?? 0) <= 8 { return true }
    }
    return false
  }

  func hasTxEvidence(_ toks: [IToken], amountAt idx: Int) -> Bool {
    let line = toks[idx].line
    for t in toks where t.line == 0 || abs(t.line - line) <= 3 {
      if ILex.direction(t.key) != nil { return true }
    }
    return false
  }

  func bare(_ toks: [IToken], _ m: Mail) -> Reading {
    let moneys = toks.indices.filter { toks[$0].cls == .money }
    guard !moneys.isEmpty else { return Reading(note: "no money") }
    let scored = moneys.map { ($0, amountScore(toks, $0)) }
    guard let pick = scored.max(by: { $0.1 < $1.1 || ($0.1 == $1.1 && $0.0 > $1.0) }), pick.1 > -2 else {
      return Reading(note: "only balance-like money")
    }
    let idx = pick.0
    if excluded(toks, amountAt: idx) { return Reading(note: "excluded word near amount") }
    guard hasTxEvidence(toks, amountAt: idx) else { return Reading(note: "money without movement verb") }
    let cur = currency(toks, idx)
    guard let minor = ITokenizer.minor(toks[idx].raw, currency: cur) else { return Reading(note: "unparsable amount") }
    let (dir, _) = direction(toks, amountAt: idx)
    var r = Reading()
    r.isTransaction = true
    r.amountMinor = minor
    r.currency = cur
    r.direction = dir ?? "debit"
    r.merchant = bareMerchant(toks, after: idx) ?? labeledValue(toks, allowed: nil)
    r.confidence = m.listUnsubscribe ? 0.25 : 0.4
    r.note = "bare: money+verb"
    return r
  }

  func bareMerchant(_ toks: [IToken], after idx: Int) -> String? {
    var i = idx + 1
    let line = toks[idx].line
    while i < toks.count, toks[i].line == line {
      if toks[i].cls == .word, ["at", "لدى"].contains(toks[i].key) {
        var j = i + 1
        var out: [IToken] = []
        while j < toks.count, toks[j].line == line, toks[j].cls != .nl {
          let k = toks[j].key
          if (toks[j].cls == .punct && k == ".") || (toks[j].cls == .word && ["on", "avl", "available", "using", "with", "via"].contains(k))
            || toks[j].cls == .money
          { break }
          out.append(toks[j])
          j += 1
        }
        let s = clean(ITokenizer.join(out[...]))
        return s.isEmpty || out.count > 8 ? nil : s
      }
      i += 1
    }
    return nil
  }

  func labeledValue(_ toks: [IToken], allowed: Set<Int>?) -> String? {
    let maxLine = toks.last?.line ?? 0
    var byLine = [[Int]](repeating: [], count: maxLine + 1)
    for i in toks.indices where toks[i].cls != .nl { byLine[toks[i].line].append(i) }
    guard maxLine >= 2 else { return nil }
    for ln in 1..<maxLine {
      let lab = byLine[ln]
      let val = byLine[ln + 1]
      let words = lab.filter { toks[$0].cls == .word }
      guard !lab.isEmpty, !val.isEmpty, words.count <= 4, lab.allSatisfy({ toks[$0].cls == .word || toks[$0].cls == .punct }) else { continue }
      guard words.contains(where: { IAlign.strongLabels.contains(toks[$0].key) && !["to", "at"].contains(toks[$0].key) }),
        words.count < 3 || !words.contains(where: { ILex.direction(toks[$0].key) != nil })
      else { continue }
      let valWords = val.filter { toks[$0].cls == .word }
      if valWords.allSatisfy({ ILex.fieldNames.contains(toks[$0].key) || ILex.functionWords.contains(toks[$0].key) }) { continue }
      guard val.count <= 8, val.allSatisfy({ toks[$0].cls == .word || toks[$0].cls == .punct }), toks[val.last!].key != ":" else { continue }
      if let allowed = allowed, !val.allSatisfy({ allowed.contains($0) }) { continue }
      let s = clean(ITokenizer.join(toks[val.first!...val.last!]))
      if !s.isEmpty { return s }
    }
    return nil
  }

  func clean(_ s: String) -> String {
    var t = s.trimmingCharacters(in: .whitespaces)
    while let l = t.last, ".,:;\u{060C}-".contains(l) { t.removeLast() }
    return t.trimmingCharacters(in: .whitespaces)
  }

  func gapContext(_ t: [IElem], _ g: Int) -> (left: [String], wholeLine: Bool, prevLineColon: Bool) {
    var left: [String] = []
    var i = g - 1
    var startsLine = false
    while i >= 0, left.count < 3 {
      if t[i].cls == .nl { startsLine = left.isEmpty; break }
      if t[i].kind == .const && t[i].cls == .word { left.append(t[i].key) }
      if t[i].kind != .const { break }
      i -= 1
    }
    if i < 0 { startsLine = left.isEmpty }
    var prevColon = false
    if startsLine && i >= 0 {
      var j = i - 1
      var prevLine: [String] = []
      var lastWasColon = false
      var first = true
      while j >= 0, t[j].cls != .nl {
        if first { lastWasColon = t[j].key == ":"; first = false }
        if t[j].kind == .const && t[j].cls == .word { prevLine.append(t[j].key) }
        if t[j].kind == .gap { prevLine = []; break }
        j -= 1
      }
      left = prevLine
      prevColon = lastWasColon || prevLine.first.map { $0.hasSuffix(":") } ?? false
    }
    let r = g + 1
    let endsLine = r >= t.count || t[r].cls == .nl
    return (left, startsLine && endsLine, prevColon)
  }

  func analyze(_ l: InductionLayout) -> IAnalysis {
    let t = l.template
    let applied = l.applied
    let k = applied.count
    var bestAmt: (Int, Int, Double)?
    var second = Int.min
    for (e, el) in t.enumerated() where el.kind == .typed && el.cls == .money {
      var sum = 0
      var hits = 0
      for (x, a) in applied.enumerated() {
        if let ti = a.elemTok[e] {
          sum += amountScore(l.examples[x], ti)
          hits += 1
        }
      }
      guard hits > 0 else { continue }
      let avg = sum / hits
      let support = Double(hits) / Double(k)
      if let b = bestAmt {
        if avg > b.1 {
          second = b.1
          bestAmt = (e, avg, support)
        } else {
          second = max(second, avg)
        }
      } else {
        bestAmt = (e, avg, support)
      }
    }
    var merchant: (Int, Int)?
    var merchantLong = false
    var merchantVaries = false
    let amtPos = bestAmt?.0 ?? -1
    for (g, el) in t.enumerated() where el.kind == .gap {
      var values: [String] = []
      var alpha = 0
      var digit = 0
      var dirOnly = 0
      var longest = 0
      for (x, a) in applied.enumerated() {
        guard let r = a.gapRange[g], !r.isEmpty else { continue }
        let toks = l.examples[x][r]
        let words = toks.filter { $0.cls == .word }
        let nums = toks.filter { $0.cls == .num || $0.cls == .money }
        if toks.contains(where: { $0.cls == .nl }) { longest = max(longest, 99) }
        longest = max(longest, toks.count)
        if !words.isEmpty && words.count >= nums.count { alpha += 1 }
        if nums.count > words.count { digit += 1 }
        if !words.isEmpty && words.allSatisfy({ ILex.direction($0.key) != nil || ILex.functionWords.contains($0.key) || ILex.fieldNames.contains($0.key) }) { dirOnly += 1 }
        values.append(ITokenizer.join(toks))
      }
      guard !values.isEmpty, alpha * 2 >= values.count else { continue }
      if dirOnly * 2 >= values.count { continue }
      let ctx = gapContext(t, g)
      var s = 0
      if ctx.left.contains(where: { ILex.greetWords.contains($0) }) { s -= 4 }
      let weak: Set<String> = ["to", "at", "in", "@", "name", "from", "من"]
      if ctx.wholeLine {
        if ctx.left.contains(where: { ILex.merchantLabels.contains($0) && !weak.contains($0) }) { s += 3 }
        else if ctx.left.contains(where: { weak.contains($0) }) { s += 1 }
      } else if let f = ctx.left.first, ILex.merchantLabels.contains(f) { s += f == "from" ? 2 : 3 }
      else if ctx.left.contains(where: { ILex.merchantLabels.contains($0) }) { s += 2 }
      if ctx.left.contains(where: { ILex.balanceWords.contains($0) || ["date", "time", "ref", "reference", "بتاريخ", "التاريخ", "المرجعي"].contains($0) }) { s -= 3 }
      if ctx.wholeLine { s += 1 }
      if ctx.prevLineColon { s += 1 }
      if digit > 0 { s -= 2 }
      if longest > 10 { s -= 2 }
      let distinct = Set(values).count
      if k >= 3 && distinct * 2 > values.count { s += 1 }
      if g < amtPos && !ctx.wholeLine { s -= 0 }
      if s >= 2, s > (merchant?.1 ?? Int.min) {
        merchant = (g, s)
        merchantLong = longest > 8
        merchantVaries = distinct > 1
      }
    }
    return IAnalysis(
      amountElem: bestAmt?.0, amountSupport: bestAmt?.2 ?? 0, amountAmbiguous: bestAmt != nil && second == bestAmt!.1,
      merchantGap: merchant?.0, merchantLong: merchantLong, merchantVaries: merchantVaries)
  }

  func learned(_ l: InductionLayout, _ toks: [IToken], _ m: Mail, preFit: Double, revised: Bool) -> Reading {
    guard let an = l.analysis, let a = l.applied.last else { return bare(toks, m) }
    var conf: Double
    switch l.seen {
    case ..<3: conf = 0.72
    case 3: conf = 0.8
    case 4: conf = 0.85
    default: conf = 0.9
    }
    var notes: [String] = ["layout n=\(l.seen) fit=\(String(format: "%.2f", preFit))"]
    if preFit < 0.85 { conf -= 0.1 }
    if revised { conf -= 0.05; notes.append("layout revised") }
    var idx: Int?
    if let e = an.amountElem, let ti = a.elemTok[e] {
      idx = ti
      if an.amountSupport < 0.99 { conf -= 0.1; notes.append("amount slot not in all") }
      if an.amountAmbiguous { conf -= 0.2; notes.append("amount ambiguous") }
    } else {
      let inGaps = a.gapRange.values.flatMap { Array($0) }.filter { toks[$0].cls == .money }.sorted()
      if let pick = inGaps.max(by: { amountScore(toks, $0) < amountScore(toks, $1) }) {
        idx = pick
        conf = min(conf, 0.5)
        notes.append("amount from free gap")
      }
    }
    if let i = idx, amountScore(toks, i) <= -2 { idx = nil; notes.append("money looks like a balance") }
    if let i = idx {
      let typedHits = Set(l.template.indices.filter { l.template[$0].kind == .typed && l.template[$0].cls == .money }.compactMap { a.elemTok[$0] })
      let extra = toks.indices.filter { toks[$0].cls == .money && !typedHits.contains($0) && $0 != i && amountScore(toks, $0) > -2 }
      if !extra.isEmpty { conf = min(conf, 0.6); notes.append("extra money in mail") }
    }
    guard let ai = idx else {
      return Reading(confidence: conf, note: notes.joined(separator: "; ") + "; no money slot")
    }
    if excluded(toks, amountAt: ai) { return Reading(note: notes.joined(separator: "; ") + "; excluded word") }
    let cur = currency(toks, ai)
    guard let minor = ITokenizer.minor(toks[ai].raw, currency: cur) else { return Reading(note: "unparsable amount") }
    var r = Reading()
    r.amountMinor = minor
    r.currency = cur
    let (dir, src) = direction(toks, amountAt: ai)
    r.direction = dir ?? "debit"
    if src == 2 { conf -= 0.05 }
    if dir == nil { conf -= 0.15; notes.append("no direction word") }
    let strong: Set<String> = ["amount", "المبلغ", "مبلغ", "value", "بقيمة", "sum"]
    let labeled = leftContext(toks, ai).prefix(3).contains { strong.contains($0) }
    r.isTransaction = dir != nil || labeled || hasTxEvidence(toks, amountAt: ai)
    if !r.isTransaction { conf = min(conf, 0.5) }
    if let g = an.merchantGap {
      if let range = a.gapRange[g], !range.isEmpty {
        var slice = toks[range]
        if let nl = slice.firstIndex(where: { $0.cls == .nl }) {
          let head = slice[slice.startIndex..<nl]
          slice = head.contains(where: { $0.cls == .word }) ? head : slice[(nl + 1)...]
          if let nl2 = slice.firstIndex(where: { $0.cls == .nl }) { slice = slice[slice.startIndex..<nl2] }
        }
        let s = clean(ITokenizer.join(slice))
        r.merchant = s.isEmpty ? nil : s
      }
      if an.merchantLong { conf -= 0.1 }
      if !an.merchantVaries && r.merchant != nil { conf = min(conf, 0.75); notes.append("merchant slot never varied") }
    }
    if r.merchant == nil {
      let inGap = Set(a.gapRange.values.flatMap { Array($0) })
      if let s = labeledValue(toks, allowed: inGap) {
        r.merchant = s
        conf = min(conf, 0.7)
        notes.append("merchant from label in free gap")
      }
    }
    r.confidence = max(0, min(1, conf))
    r.note = notes.joined(separator: "; ")
    return r
  }
}
