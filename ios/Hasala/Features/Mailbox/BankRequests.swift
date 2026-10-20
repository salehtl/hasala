import Foundation

struct BankCandidate: Identifiable, Hashable, Sendable {
  let slug: String
  let name: String
  let domains: [String]

  var id: String { slug }

  static let all: [BankCandidate] = [
    BankCandidate(slug: "adcb", name: "ADCB", domains: ["adcb.com"]),
    BankCandidate(slug: "emirates-islamic", name: "Emirates Islamic", domains: ["emiratesislamic.ae"]),
    BankCandidate(slug: "fab", name: "First Abu Dhabi Bank", domains: ["bankfab.com"]),
    BankCandidate(slug: "liv", name: "Liv", domains: ["liv.me"]),
    BankCandidate(slug: "mashreq", name: "Mashreq", domains: ["mashreq.com", "mashreqbank.com"]),
    BankCandidate(slug: "rakbank", name: "RAKBANK", domains: ["rakbank.ae"]),
    BankCandidate(slug: "wio", name: "Wio", domains: ["wio.io"]),
  ]
}

enum RequestedBankState: String, Sendable, Hashable {
  case requested
  case collectingSamples = "collecting_samples"
  case templateInProgress = "template_in_progress"
  case supported
  case declined

  init(wire: String) { self = RequestedBankState(rawValue: wire) ?? .requested }

  func detail(knownToThisBuild: Bool) -> String {
    switch self {
    case .requested: "Requested. We'll tell you here when it works."
    case .collectingSamples: "We're collecting sample alerts for it."
    case .templateInProgress: "Being added to Hasala."
    case .supported: knownToThisBuild ? "Works now. Turn it on in Change banks." : "Works now. Update Hasala to use it."
    case .declined: "We can't add it yet."
    }
  }
}

struct RequestedBank: Identifiable, Hashable, Sendable {
  let bank: String
  let name: String
  let state: RequestedBankState

  var id: String { bank == "other" ? "other:" + name : bank }
  var knownToThisBuild: Bool { SupportedBank(rawValue: bank) != nil }
  var detail: String { state.detail(knownToThisBuild: knownToThisBuild) }
}

struct BankCatalogChoice: Identifiable, Hashable, Sendable {
  let slug: String
  let name: String
  let state: RequestedBankState

  var id: String { slug }
}

struct BankRequestsSnapshot: Equatable, Sendable {
  var requests: [RequestedBank]
  var catalog: [BankCatalogChoice]

  var askable: [BankCatalogChoice] {
    catalog.filter { SupportedBank(rawValue: $0.slug) == nil && $0.state != .supported && $0.state != .declined }
  }

  static let offline = BankRequestsSnapshot(
    requests: [], catalog: BankCandidate.all.map { BankCatalogChoice(slug: $0.slug, name: $0.name, state: .requested) })
}

struct BankHint: Identifiable, Hashable, Sendable {
  let candidate: BankCandidate
  let domain: String

  var id: String { candidate.slug + "|" + domain }
}

enum OtherBankProbe: Equatable, Sendable {
  case found([BankHint])
  case notReading
  case signInAgain
  case offline
}

@MainActor
protocol OtherBankProbing: AnyObject {
  func probeOtherBanks(_ candidates: [BankCandidate]) async -> OtherBankProbe
}

extension OtherBankProbe {
  static func hints(found domains: [String], in candidates: [BankCandidate]) -> [BankHint] {
    var out: [BankHint] = []
    for c in candidates {
      if let d = c.domains.first(where: { domains.contains($0) }) { out.append(BankHint(candidate: c, domain: d)) }
    }
    return out
  }
}
