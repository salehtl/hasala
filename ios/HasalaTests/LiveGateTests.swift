import CoreMailbox
import CorePrimitives
import CoreStore
import CoreSync
import Foundation
import HasalaMocks
import HasalaModels
import Testing

@testable import Hasala

/// The live gate's decisions (spec 04 §6.5) and what this iPhone keeps about the account
/// outside its store (§4.5).
@MainActor
@Suite("Live gate")
struct LiveGateTests {
  static func binding() -> AccountBinding {
    AccountBinding(
      userID: UserID("11111111-1111-4111-8111-111111111111")!, writerID: WriterID("ios-22222222-2222-4222-8222-222222222222")!,
      apiBase: "https://api.hasala.app", keyEpoch: 1, emailNorm: "maya@example.com", serverSalt: Data(count: 32),
      displayName: "Maya")
  }

  @Test func eachBootStateHasItsScreen() {
    func check(_ s: BootState, finished: Bool = false, _ phase: AccountSession.Phase, _ wall: BootController.Wall?) {
      let (p, w) = BootController.initialPhase(s, finished: finished)
      #expect(p == phase && w == wall, "\(s)")
    }
    check(.signedOut, .signedOut, nil)
    check(.signedOutBound, .signedOut, nil)
    check(.foreignData, .signedOut, .foreignData)
    check(.unenrolled, .signedOut, .unenrolled)
    check(.restoring, .signedOut, .restoring)
    check(.onboardingKeys, .checking, nil)
    check(.needsUnlock, .checking, nil)
    check(.opening(Self.binding()), .onboarding(.bank), nil)
    check(.opening(Self.binding()), finished: true, .ready, nil)
  }

  @Test func theGmailStepResumesFromTheLane() {
    #expect(BootController.mailboxFact(.unlinked) == .unlinked)
    #expect(BootController.mailboxFact(.scanning) == .scanning)
    #expect(BootController.mailboxFact(.awaitingCards) == .scanning)  // filed on the next run
    #expect(BootController.mailboxFact(.otherDevice) == .otherDevice)
    #expect(BootController.mailboxFact(.active) == .linked)
  }

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

  // MARK: UserDefaults (§4.5: no identifier but installID)

  static func defaults() -> UserDefaults {
    let name = "LiveGateTests.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    d.set("install-a", forKey: "app.hasala.installID")
    return d
  }

  @Test func theSkippedCardsAreKeptAsDigests() {
    let d = Self.defaults()
    let prefs = DevicePrefsStore(defaults: d)
    let today = LocalDate(2026, 10, 12)
    prefs.skip("txn-123", on: today)
    let stored = String(decoding: d.data(forKey: "prefs.review.skipped.v2") ?? Data(), as: UTF8.self)
    #expect(!stored.contains("txn-123"))
    let digests = prefs.skippedDigests(on: today)
    #expect(digests == [LocalAccountData.digest("txn-123", salt: "install-a")])
    #expect(prefs.skippedDigests(on: LocalDate(2026, 10, 13)).isEmpty)
    // The mapper turns them back into this ledger's ids.
    let c = LedgerStateMapper.Context(
      today: today, profile: ProfileInfo(displayName: "", email: "", signIn: .password), skippedDigests: digests,
      digestSalt: prefs.salt)
    #expect(LedgerStateMapper.skipped(MayaFixture.txns(["txn-1", "txn-123"]), c) == ["txn-123"])
  }

  @Test func theFaceIDLockIsOffUntilTheAppLockExists() {
    #expect(DevicePrefsStore(defaults: Self.defaults()).prefs.faceIDLock == false)
  }

  @Test func leavingTheAccountForgetsWhatThisIPhoneNoted() {
    let d = Self.defaults()
    LocalAccountData.markSetupFinished(d)
    DevicePrefsStore(defaults: d).skip("txn-1", on: LocalDate(2026, 10, 12))
    d.set("x", forKey: "push.apns.registered.v2")
    d.set("x", forKey: "push.apns.registered.v1")
    d.set(Data([1]), forKey: "debug.simulatorApprovalKey.u:w")
    LocalAccountData.forget(defaults: d)
    #expect(!LocalAccountData.setupFinished(d))
    #expect(d.object(forKey: "prefs.review.skipped.v2") == nil)
    #expect(d.object(forKey: "push.apns.registered.v2") == nil && d.object(forKey: "push.apns.registered.v1") == nil)
    #if targetEnvironment(simulator)
      #expect(d.object(forKey: "debug.simulatorApprovalKey.u:w") == nil)
    #endif
    #expect(d.string(forKey: "app.hasala.installID") == "install-a")
  }

  @Test func theEarlierSetupListBecomesOneFlag() {
    let d = Self.defaults()
    d.set(["someone-else", "u-1"], forKey: "setup.finished.v1")
    LocalAccountData.migrate(boundUserID: "u-1", defaults: d)
    #expect(LocalAccountData.setupFinished(d))
    #expect(d.object(forKey: "setup.finished.v1") == nil)
    let e = Self.defaults()
    e.set(["someone-else"], forKey: "setup.finished.v1")
    LocalAccountData.migrate(boundUserID: "u-1", defaults: e)
    #expect(!LocalAccountData.setupFinished(e))
    #expect(e.object(forKey: "setup.finished.v1") == nil)
  }

  @Test func digestsNameNothingOutsideTheInstall() {
    let a = LocalAccountData.digest("u|t|e", salt: "install-a")
    #expect(a == LocalAccountData.digest("u|t|e", salt: "install-a"))
    #expect(a != LocalAccountData.digest("u|t|e", salt: "install-b"))
    #expect(a.count == 16 && !a.contains("u|t|e"))
  }
}

/// Transactions for the mapper's skipped-card check, from Maya's ledger.
@MainActor
enum MayaFixture {
  static func txns(_ ids: [String]) -> [HasalaModels.Txn] {
    let base = MayaLedger.state.txns[0]
    return ids.map { id in
      var t = base
      t.id = id
      return t
    }
  }
}
