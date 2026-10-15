import CoreMailbox
import Foundation
import Testing

@testable import Hasala

/// The live mailbox layer's pure rules (spec 04 §7.4): what Home and Profile offer, the
/// takeover check before a connect, and the banks read from the trusted senders.
@MainActor
@Suite("Live mailbox")
struct LiveMailboxTests {
  /// Home and Profile offer Gmail from the lane's phase (spec 04 §6.6 row 4, §7.4), and
  /// never on an account that loaded the App Review sample (§6.13).
  @Test func theGmailOfferFollowsTheLane() {
    func offer(
      _ phase: MailboxPhase, halt: MailboxHaltCode? = nil, sample: Bool = false, link: MailboxLinkStatus? = .noLink
    ) -> GmailOffer? {
      LiveMailboxConnecting.offer(phase: phase, halt: halt, sampleLoaded: sample, serverLink: link)
    }
    #expect(offer(.unlinked) == .connect)
    #expect(offer(.reconnectRequired) == .reconnect)
    #expect(offer(.halted) == .reconnect)
    // The first import runs on its own: nothing to offer while it does.
    for phase in [MailboxPhase.scanning, .awaitingCards, .authoringBackfill, .active, .otherDevice] {
      #expect(offer(phase) == nil)
    }
    for phase in MailboxPhase.allCases {
      #expect(offer(phase, sample: true) == nil)
    }
    // No link here: offered only once the server says no other iPhone reads Gmail.
    #expect(offer(.unlinked, link: nil) == nil)
    #expect(offer(.unlinked, link: .holder(isThisDevice: false, watchExpiresAtMs: nil)) == nil)
    #expect(offer(.unlinked, link: .holder(isThisDevice: true, watchExpiresAtMs: nil)) == .connect)
    #expect(offer(.reconnectRequired, link: nil) == .reconnect)
    // Only a halt a new Google sign-in fixes is offered a reconnect.
    #expect(offer(.halted, halt: .gmail) == .reconnect)
    #expect(offer(.halted, halt: .accountFull) == nil)
    #expect(offer(.halted, halt: .templatesUnavailable) == nil)
  }

  /// Another iPhone takes the link after this one was offered "Connect Gmail": the offer
  /// goes with the next answer, and a connect asks again first and is refused, as it is
  /// when the server can't be asked.
  @Test func aLinkTakenElsewhereRefusesTheConnect() throws {
    let other = MailboxLinkStatus.holder(isThisDevice: false, watchExpiresAtMs: nil)
    #expect(LiveMailboxConnecting.offer(phase: .unlinked, sampleLoaded: false, serverLink: .noLink) == .connect)
    try LiveMailboxConnecting.checkTakeover(.noLink)
    #expect(LiveMailboxConnecting.offer(phase: .unlinked, sampleLoaded: false, serverLink: other) == nil)
    #expect(throws: SetupFailure.failed("Gmail is read on your other iPhone.")) {
      try LiveMailboxConnecting.checkTakeover(other)
    }
    #expect(throws: SetupFailure.failed(LiveMailboxConnecting.message(.offline))) {
      try LiveMailboxConnecting.checkTakeover(nil)
    }
  }

  /// A connect after setup reads the banks from the bank step's sender trust.
  @Test func theBanksComeFromTheTrustedSenders() {
    #expect(LiveMailboxConnecting.banks(trusted: []) == [])
    #expect(LiveMailboxConnecting.banks(trusted: ["dib.ae"]) == [.dib])
    #expect(LiveMailboxConnecting.banks(trusted: GmailLane.senderDomains(bank: "enbd") + ["dib.ae"]) == [.enbd, .dib])
  }

  /// Bank alerts names each bank by its templates' sender domains (Emirates NBD's is
  /// emiratesnbd.com, which doesn't contain "enbd").
  @Test func bankAlertsNameTheirBank() {
    #expect(LedgerStateMapper.bankName(domain: "emiratesnbd.com") == "Emirates NBD")
    #expect(LedgerStateMapper.bankName(domain: "dib.ae") == "DIB")
    #expect(LedgerStateMapper.bankName(domain: "alerts.dib.ae") == "DIB")
    #expect(LedgerStateMapper.bankName(domain: "notdib.ae") == nil)
  }
}
