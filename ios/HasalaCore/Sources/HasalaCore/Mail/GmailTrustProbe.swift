extension AuthResults {
  public struct GmailTrustProbe: Sendable, Equatable {
    public enum Form: String, Sendable, Equatable {
      case gmail
      case microsoft = "ms"
      case other
    }

    public struct DKIM: Sendable, Equatable {
      public let result: String
      public let source: String
      public let domain: String
      public let aligned: Bool

      public var text: String { "\(result)/\(source)/\(domain)/\(aligned ? "aligned" : "unaligned")" }
    }

    public let fromCount: Int
    public let fromDomain: String
    public let forms: [Form]
    public let gmailIndex: Int?
    public let gmailCount: Int
    public let dkim: [DKIM]
    public let dmarc: String
    public let spf: String
    public let arc: String
    public let analysis: Analysis

    public var g1: Bool { gmailCount == 1 && gmailIndex == 0 }

    public var line: String {
      [
        "from=\(fromDomain)",
        "from_fields=\(fromCount)",
        "ar=\(forms.count)",
        "forms=\(forms.isEmpty ? "-" : forms.map(\.rawValue).joined(separator: ","))",
        "gmail_index=\(gmailIndex.map(String.init) ?? "-")",
        "topmost=\(gmailIndex == 0 ? "yes" : "no")",
        "dkim=\(dkim.isEmpty ? "-" : dkim.map(\.text).joined(separator: ","))",
        "dmarc=\(dmarc)",
        "spf=\(spf)",
        "arc=\(arc)",
        "verdict=\(analysis.verdict.reason.rawValue)",
        "domain=\(analysis.domain ?? "-")",
      ].joined(separator: " ")
    }
  }

  public static func gmailTrustProbe(_ rawHeaders: String) -> GmailTrustProbe {
    let analysis = analyze(rawHeaders)
    let fields = readFields(rawHeaders) ?? []
    let parsed = named(fields, "authentication-results").map { parseARValue($0.value) }
    let forms: [GmailTrustProbe.Form] = parsed.map {
      if $0.authservID.utf8.elementsEqual(gmailAuthservID.utf8) { return .gmail }
      return $0.microsoftForm ? .microsoft : .other
    }
    let gmail = forms.indices.filter { forms[$0] == .gmail }

    let froms = named(fields, "from")
    let from = froms.count == 1 ? string(fromDomain(froms[0].value)) : ""
    let shownFrom = froms.first.map { probeDomain(fromDomain($0.value)) } ?? "none"

    var dkim: [GmailTrustProbe.DKIM] = []
    var dmarc = "-"
    var spf = "-"
    var arc = "-"
    if let first = gmail.first {
      let ar = parsed[first]
      for m in ar.methods where same(m.method, "dkim") {
        let hasD = m.props.contains { same($0.key, "header.d") }
        let hasI = m.props.contains { same($0.key, "header.i") }
        let d = dkimDomain(m)
        dkim.append(
          GmailTrustProbe.DKIM(
            result: probeToken(m.result), source: hasD ? "d" : (hasI ? "i" : "-"),
            domain: d.isEmpty ? (hasD || hasI ? "invalid" : "-") : d, aligned: dkimAligned(d, from)))
      }
      func result(_ method: String) -> String {
        ar.methods.first { same($0.method, method) }.map { probeToken($0.result) } ?? "-"
      }
      dmarc = result("dmarc")
      spf = result("spf")
      arc = result("arc")
    }

    return GmailTrustProbe(
      fromCount: froms.count, fromDomain: shownFrom, forms: forms, gmailIndex: gmail.first, gmailCount: gmail.count,
      dkim: dkim, dmarc: dmarc, spf: spf, arc: arc, analysis: analysis)
  }
}
