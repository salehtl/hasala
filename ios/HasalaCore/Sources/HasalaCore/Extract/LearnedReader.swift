import Foundation

struct IAnalysis {
  var amountElem: Int?
  var amountSupport: Double
  var amountAmbiguous: Bool
  var merchantGap: Int?
  var merchantLong: Bool
  var merchantVaries: Bool
}

enum LearnedReader {
  static let minExamples = 2
  static let joinFit = 0.75
  static let spawnBelow = 0.9

  static func read(_ m: ExtractInput, _ memory: LearnedLayouts) -> (Reading, LearnedLayouts) {
    var memory = memory
    var sender = memory.layouts(for: m.sender)
    let r = read(m, &sender)
    memory.store(sender, for: m.sender)
    return (r, memory)
  }

  static func read(_ m: ExtractInput, _ sender: inout SenderLayouts) -> Reading {
    sender.clock += 1
    let clock = sender.clock
    var interner = IInterner()
    let toks = ITokenizer.tokenize(subject: m.subject, text: m.text, interner: &interner)
    let keySet = Set(toks.filter { $0.code > 0 }.map(\.key))

    var best: (Int, IApplied, [IElem])?
    let ranked = sender.layouts.indices.map { i -> (Int, Double) in
      let keys = LayoutCodec.anchorKeys(sender.layouts[i].anchors)
      let inter = Double(keys.intersection(keySet).count)
      let uni = Double(max(1, keys.union(keySet).count))
      return (i, inter / uni)
    }.filter { $0.1 >= 0.3 }.sorted { $0.1 > $1.1 }.prefix(4)
    for (i, _) in ranked {
      let t = LayoutCodec.elems(sender.layouts[i].anchors, &interner)
      let a = IAlign.apply(t, toks)
      if a.fit >= joinFit && a.fit > (best?.1.fit ?? 0) { best = (i, a, t) }
    }

    if let (i, pre, oldT) = best {
      let stored = sender.layouts[i]
      var l = RuntimeLayout(
        template: oldT, examples: stored.examples.map { LayoutCodec.decode($0, template: oldT, &interner) }, seen: stored.seen,
        lastUsed: stored.lastUsed)
      let wasAnalyzed = l.seen >= minExamples
      let preFit = pre.fit
      let newT = IAlign.fold(oldT, toks)
      l.examples.append(toks)
      l.seen += 1
      l.lastUsed = clock
      let revised = wasAnalyzed && newT != oldT
      l.template = newT
      if l.examples.count > LearnedLayouts.exampleLimitPerLayout {
        l.examples.removeFirst(l.examples.count - LearnedLayouts.exampleLimitPerLayout)
      }
      let applied = l.examples.map { IAlign.apply(newT, $0) }
      let analysis = analyze(l, applied)
      sender.layouts[i] = LearnedLayout(
        anchors: LayoutCodec.slots(newT),
        examples: zip(l.examples, applied).map { LayoutCodec.encode($0, template: newT, applied: $1) }, seen: l.seen,
        lastUsed: l.lastUsed)
      if revised && preFit < spawnBelow { addLayout(toks, &interner, clock: clock, to: &sender) }
      return learned(l, analysis, applied, toks, m, preFit: preFit, revised: revised)
    }
    addLayout(toks, &interner, clock: clock, to: &sender)
    var r = bare(toks, m)
    r.note = "unlearned layout (1 seen); " + r.note
    return r
  }

  static func addLayout(_ toks: [IToken], _ interner: inout IInterner, clock: Int, to sender: inout SenderLayouts) {
    let t = toks.map(IElem.from)
    sender.layouts.append(
      LearnedLayout(
        anchors: LayoutCodec.slots(t), examples: [LayoutCodec.encode(toks, template: t, applied: IAlign.apply(t, toks))], seen: 1,
        lastUsed: clock))
    if sender.layouts.count > LearnedLayouts.layoutLimitPerSender,
      let idx = sender.layouts.indices.min(by: { sender.layouts[$0].lastUsed < sender.layouts[$1].lastUsed })
    {
      sender.layouts.remove(at: idx)
    }
  }

  static func lineTokens(_ toks: [IToken], line: Int) -> [Int] {
    toks.indices.filter { toks[$0].line == line && toks[$0].cls != .nl }
  }

  static func leftContext(_ toks: [IToken], _ idx: Int, n: Int = 5) -> [String] {
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

  static func rightContext(_ toks: [IToken], _ idx: Int, n: Int = 3) -> [String] {
    var out: [String] = []
    var i = idx + 1
    while i < toks.count, out.count < n, toks[i].cls != .nl {
      if toks[i].cls == .word { out.append(toks[i].key) }
      i += 1
    }
    return out
  }

  static func amountScore(_ toks: [IToken], _ idx: Int) -> Int {
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

  static func currency(_ toks: [IToken], _ idx: Int) -> String {
    if idx > 0, toks[idx - 1].cls == .cur, let c = ILex.currency(toks[idx - 1].raw) { return c }
    if idx + 1 < toks.count, toks[idx + 1].cls == .cur, let c = ILex.currency(toks[idx + 1].raw) { return c }
    return "AED"
  }

  static func direction(_ toks: [IToken], amountAt idx: Int?) -> (String?, Int) {
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

  static func excluded(_ toks: [IToken], amountAt idx: Int) -> Bool {
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

  static func hasTxEvidence(_ toks: [IToken], amountAt idx: Int) -> Bool {
    let line = toks[idx].line
    for t in toks where t.line == 0 || abs(t.line - line) <= 3 {
      if ILex.direction(t.key) != nil { return true }
    }
    return false
  }

  static func bare(_ toks: [IToken], _ m: ExtractInput) -> Reading {
    let moneys = toks.indices.filter { toks[$0].cls == .money }
    guard !moneys.isEmpty else { return Reading(note: "no money") }
    let scored = moneys.map { ($0, amountScore(toks, $0)) }
    guard let pick = scored.max(by: { $0.1 < $1.1 || ($0.1 == $1.1 && $0.0 > $1.0) }), pick.1 > -2 else {
      return Reading(note: "only balance-like money")
    }
    let idx = pick.0
    if excluded(toks, amountAt: idx) { return Reading(note: "excluded word near amount", negative: true) }
    guard hasTxEvidence(toks, amountAt: idx) else { return Reading(note: "money without movement verb") }
    var cur = currency(toks, idx)
    guard var minor = ITokenizer.minor(toks[idx].raw, currency: cur) else { return Reading(note: "unparsable amount") }
    var aedNote = ""
    if cur != "AED", let aed = RuleReader.aedAmount(m) {
      aedNote = "; aed over \(cur)"
      minor = aed
      cur = "AED"
    }
    let (dir, _) = direction(toks, amountAt: idx)
    var r = Reading()
    r.isTransaction = true
    r.amountMinor = minor
    r.currency = cur
    r.direction = dir ?? "debit"
    r.merchant = bareMerchant(toks, after: idx) ?? labeledValue(toks, allowed: nil)
    r.confidence = m.listUnsubscribe ? 25 : 40
    r.note = "bare: money+verb" + aedNote
    return r
  }

  static func bareMerchant(_ toks: [IToken], after idx: Int) -> String? {
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

  static func labeledValue(_ toks: [IToken], allowed: Set<Int>?) -> String? {
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

  static func clean(_ s: String) -> String {
    var t = s.trimmingCharacters(in: .whitespaces)
    while let l = t.last, ".,:;\u{060C}-".contains(l) { t.removeLast() }
    return t.trimmingCharacters(in: .whitespaces)
  }

  static func gapContext(_ t: [IElem], _ g: Int) -> (left: [String], wholeLine: Bool, prevLineColon: Bool) {
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

  static func analyze(_ l: RuntimeLayout, _ applied: [IApplied]) -> IAnalysis {
    let t = l.template
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

  static func learned(
    _ l: RuntimeLayout, _ an: IAnalysis, _ applied: [IApplied], _ toks: [IToken], _ m: ExtractInput, preFit: Double, revised: Bool
  ) -> Reading {
    guard let a = applied.last else { return bare(toks, m) }
    var conf: Int
    switch l.seen {
    case ..<3: conf = 72
    case 3: conf = 80
    case 4: conf = 85
    default: conf = 90
    }
    var notes: [String] = ["layout n=\(l.seen) fit=\(Int((preFit * 100).rounded()))%"]
    if preFit < 0.85 { conf -= 10 }
    if revised { conf -= 5; notes.append("layout revised") }
    var idx: Int?
    if let e = an.amountElem, let ti = a.elemTok[e] {
      idx = ti
      if an.amountSupport < 0.99 { conf -= 10; notes.append("amount slot not in all") }
      if an.amountAmbiguous { conf -= 20; notes.append("amount ambiguous") }
    } else {
      let inGaps = a.gapRange.values.flatMap { Array($0) }.filter { toks[$0].cls == .money }.sorted()
      if let pick = inGaps.max(by: { amountScore(toks, $0) < amountScore(toks, $1) }) {
        idx = pick
        conf = min(conf, 50)
        notes.append("amount from free gap")
      }
    }
    if let i = idx, amountScore(toks, i) <= -2 { idx = nil; notes.append("money looks like a balance") }
    if let i = idx {
      let typedHits = Set(l.template.indices.filter { l.template[$0].kind == .typed && l.template[$0].cls == .money }.compactMap { a.elemTok[$0] })
      let extra = toks.indices.filter { toks[$0].cls == .money && !typedHits.contains($0) && $0 != i && amountScore(toks, $0) > -2 }
      if !extra.isEmpty { conf = min(conf, 60); notes.append("extra money in mail") }
    }
    guard let ai = idx else {
      return Reading(confidence: conf, note: notes.joined(separator: "; ") + "; no money slot")
    }
    if excluded(toks, amountAt: ai) { return Reading(note: notes.joined(separator: "; ") + "; excluded word", negative: true) }
    var cur = currency(toks, ai)
    guard var minor = ITokenizer.minor(toks[ai].raw, currency: cur) else { return Reading(note: "unparsable amount") }
    if cur != "AED", let aed = RuleReader.aedAmount(m) {
      notes.append("aed over \(cur)")
      minor = aed
      cur = "AED"
    }
    var r = Reading()
    r.amountMinor = minor
    r.currency = cur
    let (dir, src) = direction(toks, amountAt: ai)
    r.direction = dir ?? "debit"
    if src == 2 { conf -= 5 }
    if dir == nil { conf -= 15; notes.append("no direction word") }
    let strong: Set<String> = ["amount", "المبلغ", "مبلغ", "value", "بقيمة", "sum"]
    let labeled = leftContext(toks, ai).prefix(3).contains { strong.contains($0) }
    r.isTransaction = dir != nil || labeled || hasTxEvidence(toks, amountAt: ai)
    if !r.isTransaction { conf = min(conf, 50) }
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
      if an.merchantLong { conf -= 10 }
      if !an.merchantVaries && r.merchant != nil { conf = min(conf, 75); notes.append("merchant slot never varied") }
    }
    if r.merchant == nil {
      let inGap = Set(a.gapRange.values.flatMap { Array($0) })
      if let s = labeledValue(toks, allowed: inGap) {
        r.merchant = s
        conf = min(conf, 70)
        notes.append("merchant from label in free gap")
      }
    }
    r.confidence = max(0, min(100, conf))
    r.note = notes.joined(separator: "; ")
    return r
  }
}
