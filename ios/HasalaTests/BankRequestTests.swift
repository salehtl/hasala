import Foundation
import Testing

@testable import Hasala

@MainActor
@Suite("Bank requests")
struct BankRequestTests {
  @Test func stateWordsFollowTheServer() {
    #expect(RequestedBankState(wire: "collecting_samples") == .collectingSamples)
    #expect(RequestedBankState(wire: "template_in_progress") == .templateInProgress)
    #expect(RequestedBankState(wire: "something_new") == .requested)
    #expect(RequestedBank(bank: "fab", name: "First Abu Dhabi Bank", state: .supported).detail
      == "Works now. Update Hasala to use it.")
    #expect(RequestedBank(bank: "adib", name: "Abu Dhabi Islamic Bank", state: .supported).detail
      == "Works now. Turn it on in Change banks.")
  }

  @Test func askableLeavesOutWhatThisBuildReadsAndWhatIsClosed() {
    let s = BankRequestsSnapshot(
      requests: [],
      catalog: [
        BankCatalogChoice(slug: "enbd", name: "Emirates NBD", state: .supported),
        BankCatalogChoice(slug: "fab", name: "First Abu Dhabi Bank", state: .collectingSamples),
        BankCatalogChoice(slug: "liv", name: "Liv", state: .declined),
        BankCatalogChoice(slug: "new-bank", name: "New Bank", state: .supported),
        BankCatalogChoice(slug: "wio", name: "Wio", state: .requested),
      ])
    #expect(s.askable.map(\.slug) == ["fab", "wio"])
  }

  @Test func hintsNameOneDomainPerBank() {
    let hints = OtherBankProbe.hints(found: ["mashreqbank.com", "wio.io", "elsewhere.example"], in: BankCandidate.all)
    #expect(hints.map(\.candidate.slug) == ["mashreq", "wio"])
    #expect(hints.map(\.domain) == ["mashreqbank.com", "wio.io"])
  }

  @Test func candidatesAreNotBanksThisBuildReads() {
    #expect(BankCandidate.all.allSatisfy { SupportedBank(rawValue: $0.slug) == nil })
    #expect(BankCandidate.all.flatMap(\.domains).allSatisfy { $0 == $0.lowercased() && $0.contains(".") })
  }

  @Test func initials() {
    #expect(BankInitials.of("ADCB") == "ADCB")
    #expect(BankInitials.of("First Abu Dhabi Bank") == "FAD")
    #expect(BankInitials.of("Wio") == "WIO")
    #expect(BankInitials.of("Emirates Islamic") == "EI")
  }

  @Test func theMockRecordsSlugAndDomain() async throws {
    let setup = MockSetupAuthoring()
    try await setup.requestBank(slug: "fab", senderDomain: "bankfab.com")
    try await setup.requestBank(slug: "fab", senderDomain: nil)
    try await setup.requestBank("Some Bank")
    let s = try await setup.bankRequests()
    #expect(s.requests.map(\.bank) == ["fab", "other"])
    #expect(setup.senderDomains == ["fab": "bankfab.com"])
  }

  @Test func theMockProbeNeedsAMailbox() async {
    let empty = MockMailbox(mailboxes: [])
    #expect(await empty.probeOtherBanks(BankCandidate.all) == .notReading)
  }
}
