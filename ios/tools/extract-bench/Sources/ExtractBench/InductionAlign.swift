import Foundation

enum IElemKind: Int {
  case const, typed, gap
}

struct IElem: Equatable {
  var kind: IElemKind
  var code: Int32
  var key: String
  var cls: IClass

  static let gap = IElem(kind: .gap, code: ILex.gapCode, key: "", cls: .word)

  static func from(_ t: IToken) -> IElem {
    switch t.cls {
    case .money, .num, .cur: return IElem(kind: .typed, code: t.code, key: "", cls: t.cls)
    default: return IElem(kind: .const, code: t.code, key: t.key, cls: t.cls)
    }
  }
}

struct IApplied {
  var elemTok: [Int?]
  var gapRange: [Int: Range<Int>]
  var matched: Int
  var matchable: Int
  var inGap: Int
  var tokens: Int
  var core: Double

  var tCov: Double { matchable == 0 ? 0 : Double(matched) / Double(matchable) }
  var eCov: Double { tokens == 0 ? 0 : Double(matched + inGap) / Double(tokens) }
  var fit: Double { min(tCov, eCov, core) }
}

enum IAlign {
  static func lcs(_ a: [Int32], _ b: [Int32]) -> [(Int, Int)] {
    let n = a.count, m = b.count
    if n == 0 || m == 0 { return [] }
    let w = m + 1
    var table = [UInt16](repeating: 0, count: (n + 1) * w)
    table.withUnsafeMutableBufferPointer { t in
      a.withUnsafeBufferPointer { ap in
        b.withUnsafeBufferPointer { bp in
          var i = n - 1
          while i >= 0 {
            let ai = ap[i]
            let row = i * w
            let next = (i + 1) * w
            var j = m - 1
            while j >= 0 {
              if ai == bp[j] && ai != ILex.gapCode {
                t[row + j] = t[next + j + 1] &+ 1
              } else {
                let x = t[next + j], y = t[row + j + 1]
                t[row + j] = x >= y ? x : y
              }
              j -= 1
            }
            i -= 1
          }
        }
      }
    }
    var out: [(Int, Int)] = []
    out.reserveCapacity(Int(table[0]))
    var i = 0, j = 0
    while i < n && j < m {
      if i > 0 && a[i - 1] == ILex.gapCode && table[i * w + j + 1] == table[i * w + j] {
        j += 1
      } else if a[i] == b[j] && a[i] != ILex.gapCode && table[i * w + j] == table[(i + 1) * w + j + 1] + 1 {
        out.append((i, j))
        i += 1
        j += 1
      } else if table[(i + 1) * w + j] >= table[i * w + j + 1] {
        i += 1
      } else {
        j += 1
      }
    }
    return out
  }

  static func apply(_ t: [IElem], _ e: [IToken]) -> IApplied {
    let pairs = lcs(t.map(\.code), e.map(\.code))
    var elemTok = [Int?](repeating: nil, count: t.count)
    var gapRange: [Int: Range<Int>] = [:]
    var inGap = 0
    var pi = 0, pj = 0
    for (i, j) in pairs + [(t.count, e.count)] {
      if let g = (pi..<i).first(where: { t[$0].kind == .gap }) {
        gapRange[g] = pj..<j
        inGap += j - pj
      }
      if i < t.count { elemTok[i] = j }
      pi = i + 1
      pj = j + 1
    }
    let matchable = t.filter { $0.kind != .gap }.count
    var coreSet = Set<Int>()
    for (mi, el) in t.enumerated() where el.kind == .typed && el.cls == .money {
      var n = 0
      var i = mi - 1
      while i >= 0 && n < 6 {
        if t[i].kind == .const && t[i].cls == .word { coreSet.insert(i); n += 1 }
        i -= 1
      }
      n = 0
      i = mi + 1
      while i < t.count && n < 6 {
        if t[i].kind == .const && t[i].cls == .word { coreSet.insert(i); n += 1 }
        i += 1
      }
    }
    let coreTotal = coreSet.count
    let coreHit = coreSet.filter { elemTok[$0] != nil }.count
    let tc = matchable == 0 ? 0 : Double(pairs.count) / Double(matchable)
    let core = coreTotal < 2 ? min(tc, Double(coreHit) / Double(max(1, coreTotal))) : Double(coreHit) / Double(coreTotal)
    return IApplied(
      elemTok: elemTok, gapRange: gapRange, matched: pairs.count, matchable: matchable, inGap: inGap, tokens: e.count, core: core)
  }

  static func fold(_ t: [IElem], _ e: [IToken]) -> [IElem] {
    let pairs = lcs(t.map(\.code), e.map(\.code))
    var out: [IElem] = []
    var pi = 0, pj = 0
    for (i, j) in pairs + [(t.count, e.count)] {
      if i > pi || j > pj {
        if out.last?.kind != .gap { out.append(.gap) }
      }
      if i < t.count { out.append(t[i]) }
      pi = i + 1
      pj = j + 1
    }
    return generalize(smooth(out))
  }

  static let strongLabels: Set<String> = [
    "merchant", "beneficiary", "payee", "الى", "إلى", "لدى", "التاجر", "المستفيد", "description", "المعاملة", "to", "at",
    "towards", "لصالح",
  ]

  static func generalize(_ t: [IElem]) -> [IElem] {
    var lines: [[IElem]] = [[]]
    for el in t {
      lines[lines.count - 1].append(el)
      if el.cls == .nl { lines.append([]) }
    }
    func body(_ l: [IElem]) -> [IElem] { l.filter { $0.cls != .nl } }
    var out: [IElem] = []
    for (n, line) in lines.enumerated() {
      let b = body(line)
      if n > 0, !b.isEmpty, b.count <= 8 {
        let prev = body(lines[n - 1])
        let prevWords = prev.filter { $0.cls == .word }
        let labelLine = !prev.isEmpty && prev.allSatisfy { $0.kind == .const } && prevWords.count <= 4
          && prevWords.contains { strongLabels.contains($0.key) } && (prevWords.count < 3 || !prevWords.contains { ILex.direction($0.key) != nil })
        let valueLine = b.allSatisfy { $0.kind == .const && ($0.cls == .word || $0.cls == .punct) } && b.contains { $0.cls == .word }
          && b.last?.key != ":" && !b.contains { $0.key == ILex.subjKey }
          && !b.filter { $0.cls == .word }.allSatisfy { ILex.fieldNames.contains($0.key) || ILex.functionWords.contains($0.key) }
        if labelLine && valueLine {
          out.append(.gap)
          if let nl = line.last, nl.cls == .nl { out.append(nl) }
          continue
        }
      }
      out.append(contentsOf: line)
    }
    return out
  }

  static func isSoftConst(_ el: IElem) -> Bool {
    el.kind == .const && el.cls == .word && !ILex.isLabelish(el.key) && el.key != ILex.subjKey && !el.key.hasSuffix(":")
  }

  static func smooth(_ t0: [IElem]) -> [IElem] {
    var t = t0
    var changed = true
    while changed {
      changed = false
      var g = 0
      while g < t.count {
        guard t[g].kind == .gap else { g += 1; continue }
        var l = g - 1
        var run = 0
        while l >= 0, isSoftConst(t[l]), run < 2 {
          l -= 1
          run += 1
        }
        if run > 0 && (l < 0 || t[l].kind == .gap || t[l].cls == .nl || (t[l].kind == .const && ILex.merchantLabels.contains(t[l].key))) {
          t.removeSubrange((l + 1)..<g)
          if l >= 0 && t[l].kind == .gap { t.remove(at: l + 1) }
          changed = true
          break
        }
        var r = g + 1
        run = 0
        while r < t.count, isSoftConst(t[r]), run < 2 {
          r += 1
          run += 1
        }
        if run > 0 && r < t.count && (t[r].kind == .gap || t[r].cls == .nl || (t[r].cls == .punct && [".", ",", "\u{060C}"].contains(t[r].key))) {
          t.removeSubrange((g + 1)..<r)
          if g + 1 < t.count && t[g + 1].kind == .gap { t.remove(at: g + 1) }
          changed = true
          break
        }
        g += 1
      }
    }
    return t
  }
}
