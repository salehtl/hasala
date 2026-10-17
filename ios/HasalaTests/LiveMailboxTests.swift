import CoreMailbox
import Foundation
import HasalaModels
import Testing

@testable import Hasala

/// The live mailbox layer's pure rules (spec 04 §7.4): what Home and Profile offer, the
/// takeover check before a connect, and the banks read from the trusted senders.
@MainActor
@Suite("Live mailbox")
struct LiveMailboxTests {
  static let signInAgain = MailOffer.signInAgain(mailboxID: "gmail", provider: .gmail)

  /// The bell, Profile and Bank alerts offer Gmail from the lane's phase (spec 04 §6.6 row 4,
  /// §7.4), and never on an account that loaded the App Review sample (§6.13).
  @Test func theGmailOfferFollowsTheLane() {
    func offer(
      _ phase: MailboxPhase, halt: MailboxHaltCode? = nil, sample: Bool = false, link: MailboxLinkStatus? = .noLink
    ) -> MailOffer? {
      LiveMailboxConnecting.offer(phase: phase, halt: halt, sampleLoaded: sample, serverLink: link)
    }
    #expect(offer(.unlinked) == .connect)
    #expect(offer(.reconnectRequired) == Self.signInAgain)
    #expect(offer(.halted) == Self.signInAgain)
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
    #expect(offer(.reconnectRequired, link: nil) == Self.signInAgain)
    // Only a halt a new Google sign-in fixes is offered a new sign-in.
    #expect(offer(.halted, halt: .gmail) == Self.signInAgain)
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
    #expect(throws: MailConnectFailure.takenByOtherIPhone) {
      try LiveMailboxConnecting.checkTakeover(other)
    }
    #expect(MailConnectFailure.takenByOtherIPhone.message(for: .gmail) == "Gmail is read on your other iPhone.")
    #expect(throws: MailConnectFailure.offline) {
      try LiveMailboxConnecting.checkTakeover(nil)
    }
    #expect(MailConnectFailure.offline.message(for: .gmail) == LiveMailboxConnecting.message(.offline))
  }

  /// A connect after setup reads the banks from the bank step's sender trust.
  @Test func theBanksComeFromTheTrustedSenders() {
    #expect(LiveMailboxConnecting.banks(trusted: []) == [])
    #expect(LiveMailboxConnecting.banks(trusted: ["dib.ae"]) == [.dib])
    #expect(LiveMailboxConnecting.banks(trusted: MailboxLane.senderDomains(bank: "enbd") + ["dib.ae"]) == [.enbd, .dib])
  }

  /// Bank alerts names each bank by its templates' sender domains (Emirates NBD's is
  /// emiratesnbd.com, which doesn't contain "enbd").
  @Test func bankAlertsNameTheirBank() {
    #expect(LedgerStateMapper.bankName(domain: "emiratesnbd.com") == "Emirates NBD")
    #expect(LedgerStateMapper.bankName(domain: "dib.ae") == "DIB")
    #expect(LedgerStateMapper.bankName(domain: "alerts.dib.ae") == "DIB")
    #expect(LedgerStateMapper.bankName(domain: "notdib.ae") == nil)
  }

  /// Live reads Gmail only, and one mailbox: no Outlook, no second mailbox (plan B4.6).
  @Test func liveConnectsGmailOnly() {
    let lane = LiveMailboxConnecting(runtime: { nil })
    #expect(lane.connectable.isEmpty)  // no runtime open yet
    #expect(lane.capabilities == [.connect, .signInAgain, .disconnect])
    #expect(!lane.capabilities.contains(.addSecond))
    #expect(lane.mailboxes.isEmpty && lane.offer == nil)
  }

  /// The mailbox page's "Last checked", on the iPhone's clock in its time zone; and a
  /// connect before the account has opened is refused, and says so.
  @Test func theLiveMailboxSaysWhenItLastChecked() async {
    let dubai = TimeZone(identifier: "Asia/Dubai")!
    // Wed 7 Oct 2026, 09:14 in Dubai (05:14 UTC).
    let ms: Int64 = 1_791_350_040_000
    #expect(LiveMailboxConnecting.checkedAt(ms, timeZone: dubai) == "Wed 7 Oct, 09:14")
    let row = LiveMailboxConnecting.mailboxes(
      phase: .active, halt: nil, address: "maya@example.com", lastSuccessAtMs: ms, bankDomains: [],
      nowMs: ms + 60_000, timeZone: dubai
    ).first
    #expect(row?.lastChecked == "Wed 7 Oct, 09:14" && row?.meta == "Checked 1 min ago")
    let lane = LiveMailboxConnecting(runtime: { nil })
    await #expect(throws: MailConnectFailure.failed("Hasala is still opening your account. Try again in a moment.")) {
      try await lane.connect(.outlook)
    }
  }

  /// Bank alerts' bank rows and hero, from the lane's bank health rows: each bank's newest
  /// alert by its sender domains, and the alerts read in this local month only.
  @Test func bankAlertsReadTheLaneHealth() throws {
    // Thu 15 Oct 2026, 12:00 in Dubai.
    let now: Int64 = 1_792_051_200_000
    let json = """
      [{"domain": "emiratesnbd.com", "lastEmailAtMs": \(now - 4 * 60_000), "month": "2026-10", "readThisMonth": 150},
       {"domain": "alerts.dib.ae", "lastEmailAtMs": \(now - 2 * 3_600_000), "month": "2026-10", "readThisMonth": 64},
       {"domain": "dib.ae", "lastEmailAtMs": \(now - 30 * 86_400_000), "month": "2026-09", "readThisMonth": 9}]
      """
    let health = try JSONDecoder().decode([BankHealthRow].self, from: Data(json.utf8))
    #expect(LiveMailboxConnecting.lastEmail(.enbd, health: health, nowMs: now) == "4 min ago")
    #expect(LiveMailboxConnecting.lastEmail(.dib, health: health, nowMs: now) == "2 h ago")
    #expect(LiveMailboxConnecting.lastEmail(.dib, health: [], nowMs: now) == nil)
    #expect(LiveMailboxConnecting.readThisMonth(health, nowMs: now) == MonthRead(count: 214, month: "October"))
    #expect(LiveMailboxConnecting.readThisMonth([], nowMs: now) == nil)
    // A new month: last month's count is not this month's.
    #expect(LiveMailboxConnecting.readThisMonth(health, nowMs: now + 20 * 86_400_000) == nil)
  }

  /// The lane's phase as the one mailbox row (plan B4.4's table).
  @Test func theLanePhaseIsTheRow() {
    let now: Int64 = 10_000_000_000
    func row(_ phase: MailboxPhase, halt: MailboxHaltCode? = nil) -> MailboxSnapshot? {
      LiveMailboxConnecting.mailboxes(
        phase: phase, halt: halt, address: "maya@example.com", lastSuccessAtMs: now - 4 * 60_000,
        bankDomains: ["dib.ae"], nowMs: now
      ).first
    }
    #expect(row(.unlinked) == nil)
    #expect(row(.scanning)?.state == .syncing && row(.scanning)?.meta == "Checking now")
    #expect(row(.awaitingCards)?.state == .syncing)
    #expect(row(.active)?.state == .connected && row(.active)?.meta == "Checked 4 min ago")
    #expect(row(.active)?.banks == ["DIB"] && row(.active)?.id == "gmail")
    #expect(row(.reconnectRequired)?.state == .needsSignIn)
    #expect(row(.halted, halt: .gmail)?.state == .needsSignIn)
    #expect(row(.halted, halt: .accountFull)?.state == .connected && row(.halted, halt: .accountFull)?.note != nil)
    #expect(row(.otherDevice)?.note == "Read on your other iPhone")
  }

  /// A lane halted for a reason a new sign-in doesn't fix: its row reads connected and
  /// nothing is offered, but the Profile card and Bank alerts must not say it works.
  /// (`LedgerStateMapper.health` gives every halted phase `.reconnect`: the lane's hero is
  /// "needs you".) Another iPhone reading the mailbox is still working.
  @Test func aHaltedLaneIsNotWorking() {
    let now: Int64 = 10_000_000_000
    func summary(_ phase: MailboxPhase, halt: MailboxHaltCode?, health: MailboxHealth.Status) -> MailboxesSummary {
      let rows = LiveMailboxConnecting.mailboxes(
        phase: phase, halt: halt, address: "maya@example.com", lastSuccessAtMs: now - 4 * 60_000,
        bankDomains: ["dib.ae"], nowMs: now)
      return MailboxesSummary(
        rows, health: MailboxHealth(status: health, lastEmail: "4 min ago", banks: "DIB"),
        offer: LiveMailboxConnecting.offer(phase: phase, halt: halt, sampleLoaded: false, serverLink: .noLink))
    }
    for halt in [MailboxHaltCode.accountFull, .templatesUnavailable] {
      let s = summary(.halted, halt: halt, health: .reconnect)
      #expect(s.title == "Bank alerts stopped" && s.detail == "Hasala stopped reading maya@example.com.")
      #expect(s.hue == .sand && s.needsYou)
    }
    let fixable = summary(.halted, halt: .gmail, health: .reconnect)
    #expect(fixable.title == "Sign in again" && fixable.needsYou)
    let elsewhere = summary(.otherDevice, halt: nil, health: .working)
    #expect(elsewhere.title == "Bank alerts are working" && !elsewhere.needsYou)
  }
}
