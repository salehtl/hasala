extension AuthResults {
  public struct OutlookTrustProbe: Sendable, Equatable {
    public enum Form: String, Sendable, Equatable {
      case microsoft = "ms"
      case authserv = "id"
    }

    public enum Tag: String, Sendable, Equatable {
      case received = "rcv0"
      case microsoftAR = "ar:ms"
      case authservAR = "ar:id"
      case authAs = "as"
      case authSource = "src"
    }

    public enum Position: String, Sendable, Equatable {
      case above, below, none
    }

    public enum SecondAR: String, Sendable, Equatable {
      case none
      case fromDomain = "from-domain"
      case other
    }

    public let fromCount: Int
    public let fromDomain: String
    public let forms: [Form]
    public let microsoftIndex: Int?
    public let microsoftCount: Int
    public let topmost: Bool
    public let authAs: [String]
    public let authAsPositions: [Position]
    public let authSource: [String]
    public let authSourcePositions: [Position]
    public let receivedPosition: Position
    public let order: [Tag]
    public let dmarc: String
    public let compauth: String
    public let reason: String
    public let headerFrom: String
    public let scl: String
    public let secondAR: SecondAR
    public let analysis: Analysis

    public var c1: Bool { microsoftCount == 1 && topmost }

    public var c2: Bool {
      authAs.count == 1 && authAs[0] == "anonymous" && authSource.count == 1 && authSource[0] == "ok"
    }

    public var line: String {
      func list(_ v: [String]) -> String { v.isEmpty ? "-" : v.joined(separator: ",") }
      func yn(_ b: Bool) -> String { b ? "yes" : "no" }
      return [
        "from=\(fromDomain)",
        "from_fields=\(fromCount)",
        "ar=\(forms.count)",
        "forms=\(list(forms.map(\.rawValue)))",
        "ms_index=\(microsoftIndex.map(String.init) ?? "-")",
        "topmost=\(yn(topmost))",
        "authas=\(authAs.count)[\(list(authAs))]@\(list(authAsPositions.map(\.rawValue)))",
        "authsource=\(authSource.count)[\(list(authSource))]@\(list(authSourcePositions.map(\.rawValue)))",
        "rcv0=\(receivedPosition.rawValue)",
        "order=\(order.isEmpty ? "-" : order.map(\.rawValue).joined(separator: ">"))",
        "dmarc=\(dmarc)",
        "compauth=\(compauth)",
        "reason=\(reason)",
        "header_from=\(headerFrom)",
        "scl=\(scl)",
        "c7=\(secondAR.rawValue)",
        "verdict=\(analysis.verdict.reason.rawValue)",
        "domain=\(analysis.domain ?? "-")",
      ].joined(separator: " ")
    }
  }

  public static func outlookTrustProbe(_ rawHeaders: String) -> OutlookTrustProbe {
    let analysis = analyzeOutlook(rawHeaders)
    let fields = readFields(rawHeaders) ?? []
    func name(_ f: Field) -> Scalars { jsLower(jsTrim(f.name)) }
    func value(_ f: Field) -> Scalars { jsLower(jsTrim(f.value)) }
    let arName = Array("authentication-results".unicodeScalars)
    let receivedName = Array("received".unicodeScalars)
    let sclName = Array("x-ms-exchange-organization-scl".unicodeScalars)

    typealias Probe = OutlookTrustProbe
    var forms: [Probe.Form] = []
    var parsed: [ARHeader] = []
    var msFieldIndex: Int? = nil
    var tagIndex: [(tag: Probe.Tag, index: Int)] = []
    var sawReceived = false
    for (i, f) in fields.enumerated() {
      let n = name(f)
      if n == arName {
        let p = parseARValue(f.value)
        parsed.append(p)
        forms.append(p.microsoftForm ? .microsoft : .authserv)
        if p.microsoftForm, msFieldIndex == nil { msFieldIndex = i }
        tagIndex.append((p.microsoftForm ? .microsoftAR : .authservAR, i))
      } else if n == outlookAuthAs {
        tagIndex.append((.authAs, i))
      } else if n == outlookAuthSource {
        tagIndex.append((.authSource, i))
      } else if n == receivedName, !sawReceived {
        sawReceived = true
        tagIndex.append((.received, i))
      }
    }
    let order = tagIndex.map { $0.tag }

    func position(_ i: Int) -> Probe.Position {
      guard let ms = msFieldIndex else { return .none }
      return i < ms ? .above : .below
    }
    let ms = parsed.indices.filter { parsed[$0].microsoftForm }
    let authAsFields = fields.enumerated().filter { name($0.element) == outlookAuthAs }
    let authSourceFields = fields.enumerated().filter { name($0.element) == outlookAuthSource }
    let authAs = authAsFields.map { probeAuthAs(value($0.element)) }
    let authSource = authSourceFields.map { probeAuthSource(value($0.element)) }
    let receivedIndex = tagIndex.first(where: { $0.tag == Probe.Tag.received })?.index

    let froms = named(fields, "from")
    let fromDom = froms.first.map { probeDomain(fromDomain($0.value)) } ?? "-"

    var dmarc = "-"
    var compauth = "-"
    var reason = "-"
    var headerFrom = "-"
    if let first = ms.first {
      let ar = parsed[first]
      if let d = ar.methods.first(where: { same($0.method, "dmarc") }) {
        dmarc = probeToken(d.result)
        let hf = domainProp(d, "header.from")
        headerFrom = hf.isEmpty ? "invalid" : hf
      }
      if let c = ar.methods.first(where: { same($0.method, "compauth") }) {
        compauth = probeToken(c.result)
        if let r = c.props.last(where: { same($0.key, "reason") }) { reason = probeToken(r.value) }
      }
    }

    var second: Probe.SecondAR = .none
    if ms.count > 1 {
      second = .other
      for idx in ms.dropFirst() {
        let ar = parsed[idx]
        let domains = ar.methods.flatMap { [domainProp($0, "header.from"), domainProp($0, "header.d")] }
        if fromDom != "-", domains.contains(where: { same($0, fromDom) }) { second = .fromDomain }
      }
    }

    let scl = fields.last { name($0) == sclName }.map { probeSCL(value($0)) } ?? "-"

    return OutlookTrustProbe(
      fromCount: froms.count,
      fromDomain: fromDom,
      forms: forms,
      microsoftIndex: ms.first,
      microsoftCount: ms.count,
      topmost: ms.first == 0,
      authAs: authAs,
      authAsPositions: authAsFields.map { position($0.offset) },
      authSource: authSource,
      authSourcePositions: authSourceFields.map { position($0.offset) },
      receivedPosition: receivedIndex.map(position) ?? .none,
      order: order,
      dmarc: dmarc,
      compauth: compauth,
      reason: reason,
      headerFrom: headerFrom,
      scl: scl,
      secondAR: second,
      analysis: analysis)
  }

  static func probeToken(_ s: String) -> String {
    let v = Array(s.unicodeScalars)
    guard !v.isEmpty, v.count <= 24 else { return "other" }
    let ok = v.allSatisfy { c in
      (c.value >= 0x61 && c.value <= 0x7a) || (c.value >= 0x30 && c.value <= 0x39) || c == "-" || c == "_"
    }
    return ok ? s : "other"
  }

  static func probeAuthAs(_ v: Scalars) -> String {
    let s = string(v)
    return ["anonymous", "internal", "external", "partner"].contains(where: { same($0, s) }) ? s : "other"
  }

  static func probeAuthSource(_ v: Scalars) -> String {
    guard v.count > outlookAuthSourceSuffix.count, v.count <= 253,
      Array(v.suffix(outlookAuthSourceSuffix.count)) == outlookAuthSourceSuffix, isLDHDomain(v)
    else { return "other" }
    return "ok"
  }

  static func probeDomain(_ v: Scalars) -> String {
    if v.isEmpty { return "none" }
    return v.count <= 253 && isLDHDomain(v) ? string(v) : "invalid"
  }

  static func probeSCL(_ v: Scalars) -> String {
    let s = string(v)
    return ["-1", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9"].contains(where: { same($0, s) }) ? s : "other"
  }
}

extension AuthResults {
  public struct OutlookOrderComparison: Sendable, Equatable {
    public let probe: OutlookTrustProbe
    public let listedOrder: [OutlookTrustProbe.Tag]
    public let receivedSame: Bool

    public var orderMatch: Bool { probe.order == listedOrder }

    public var line: String {
      let listed = listedOrder.isEmpty ? "-" : listedOrder.map(\.rawValue).joined(separator: ">")
      return probe.line + " listed_order=\(listed) order_match=\(orderMatch ? "yes" : "no") rcv0=\(receivedSame ? "same" : "differs")"
    }
  }

  public static func outlookOrderComparison(rawHeaders: String, listed: [(name: String, value: String)])
    -> OutlookOrderComparison
  {
    var block = String.UnicodeScalarView()
    for (n, v) in listed {
      block.append(contentsOf: n.unicodeScalars.filter { $0 != "\r" && $0 != "\n" && $0 != ":" })
      block.append(contentsOf: ": ".unicodeScalars)
      block.append(contentsOf: v.unicodeScalars.map { $0 == "\r" || $0 == "\n" ? " " : $0 })
      block.append(contentsOf: "\r\n".unicodeScalars)
    }
    let listedBlock = String(block)
    let probe = outlookTrustProbe(rawHeaders)
    let listedProbe = outlookTrustProbe(listedBlock)
    let same = topReceived(rawHeaders).map { a in topReceived(listedBlock).map { b in a == b } ?? false } ?? false
    return OutlookOrderComparison(probe: probe, listedOrder: listedProbe.order, receivedSame: same)
  }

  static func topReceived(_ rawHeaders: String) -> Scalars? {
    guard let fields = readFields(rawHeaders), let f = named(fields, "received").first else { return nil }
    var out: Scalars = []
    for c in jsTrim(f.value) {
      let space = c == " " || c == "\t" || c == "\r" || c == "\n"
      if space {
        if out.last != " " { out.append(" ") }
      } else {
        out.append(c)
      }
    }
    return out
  }
}
