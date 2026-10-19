import CoreMailbox
import Foundation
import HasalaModels
import Synchronization
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
  @Test func theMailboxOfferFollowsTheLane() {
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
    // No link here: offered once the server answered, also while it names another iPhone
    // (which may be gone; the connect asks before it takes the link over).
    #expect(offer(.unlinked, link: nil) == nil)
    #expect(offer(.unlinked, link: .holder(isThisDevice: false, watchExpiresAtMs: nil)) == .connect)
    #expect(offer(.unlinked, link: .holder(isThisDevice: true, watchExpiresAtMs: nil)) == .connect)
    #expect(offer(.reconnectRequired, link: nil) == Self.signInAgain)
    // Only a halt a new Google sign-in fixes is offered a new sign-in.
    #expect(offer(.halted, halt: .gmail) == Self.signInAgain)
    #expect(offer(.halted, halt: .accountFull) == nil)
    #expect(offer(.halted, halt: .templatesUnavailable) == nil)
    // A Microsoft account with no mailbox: another account's sign-in fixes it (main's rule).
    #expect(offer(.halted, halt: .noMailbox) == Self.signInAgain)
  }

  /// The offer names the lane's provider (main's `theOfferNamesTheLanesProvider`): Outlook's
  /// broken link is signed in again as Outlook. v2 has no `.change`: a working link offers
  /// nothing, and a switch is Bank alerts' "Use another email".
  @Test func theOfferNamesTheLanesProvider() {
    func offer(_ phase: MailboxPhase, halt: MailboxHaltCode? = nil) -> MailOffer? {
      LiveMailboxConnecting.offer(phase: phase, halt: halt, sampleLoaded: false, serverLink: .noLink, provider: .outlook)
    }
    let outlook = MailOffer.signInAgain(mailboxID: "outlook", provider: .outlook)
    #expect(offer(.reconnectRequired) == outlook)
    #expect(offer(.halted, halt: .noMailbox) == outlook)
    #expect(offer(.active) == nil)
    #expect(offer(.scanning) == nil)
  }

  /// Main's `noMailboxIsSaidInWords`: the no-mailbox halt and failure in plain words, and
  /// Outlook's copy names personal Microsoft accounts.
  @Test func noMailboxIsSaidInWords() {
    let outlook = "This Microsoft account has no Outlook mailbox. Sign in with the account your bank alerts go to, such as you@outlook.com or you@hotmail.com."
    let gmail = "This Google account has no Gmail. Sign in with the account your bank alerts go to."
    #expect(LiveMailboxConnecting.message(.noMailbox, provider: .outlook) == outlook)
    #expect(LiveMailboxConnecting.message(.noMailbox, provider: .gmail) == gmail)
    #expect(LiveMailboxConnecting.stopped(.noMailbox, provider: .outlook) == outlook)
    #expect(LiveMailboxConnecting.stopped(.noMailbox, provider: .gmail) == gmail)
    #expect(MailConnectFailure.noMailbox(.gmail).message(for: .gmail) == gmail)
    #expect(LiveMailboxConnecting.stopped(.gmail, provider: .gmail) == "Reading your bank alerts stopped. Try again.")
    #expect(LiveMailboxConnecting.message(.google, provider: .outlook).contains("personal Microsoft accounts"))
    #expect(LiveMailboxConnecting.message(.offline, provider: .outlook).contains("Connect Outlook when"))
  }

  @Test func aConnectWithNoMailboxIsItsOwnFailure() throws {
    #expect(throws: MailConnectFailure.noMailbox(.outlook)) {
      try LiveMailboxConnecting.linked(.failed(.noMailbox), provider: .outlook)
    }
    #expect(throws: MailConnectFailure.offline) { try LiveMailboxConnecting.linked(.failed(.offline), provider: .outlook) }
    #expect(throws: MailConnectFailure.cancelled) { try LiveMailboxConnecting.linked(.cancelled, provider: .outlook) }
    #expect(throws: MailConnectFailure.failed(LiveMailboxConnecting.message(.permissionMissing, provider: .outlook))) {
      try LiveMailboxConnecting.linked(.failed(.permissionMissing), provider: .outlook)
    }
    try LiveMailboxConnecting.linked(.connected(address: nil), provider: .outlook)
    #expect(MailConnectFailure.noMailbox(.outlook).message(for: .outlook)
      == "This Microsoft account has no Outlook mailbox. Sign in with the account your bank alerts go to, such as you@outlook.com or you@hotmail.com.")
  }

  @Test func aMailboxOnAnotherAccountIsSaidInWords() {
    let gmail = LiveMailboxConnecting.message(.mailboxInUse)
    #expect(gmail.contains("This Gmail address is connected to another Hasala account"))
    #expect(gmail.contains("connect a different address"))
    #expect(LiveMailboxConnecting.message(.mailboxInUse, provider: .outlook).hasPrefix("This Outlook address"))
    #expect(gmail != LiveMailboxConnecting.message(.serverRefused))
  }

  /// One link per account (main's `switchingFromGmailToOutlookIsConfirmed`, at the seam): a
  /// working link, or the other provider's broken one, is replaced only on a confirmed
  /// switch; the same provider is a sign-in again when broken and already connected when
  /// it works; another iPhone's link refuses any connect.
  @Test func aWorkingLinkIsNeverReplacedUnconfirmed() throws {
    func admit(_ requested: MailProviderKind, _ phase: MailboxPhase, replacing: Bool = false) throws(MailConnectFailure)
      -> Bool
    {
      try LiveMailboxConnecting.admit(
        requested, current: .gmail, phase: phase, address: "maya@example.com", replacing: replacing)
    }
    for provider in MailProviderKind.allCases {
      #expect(try admit(provider, .unlinked) == false)
      #expect(try admit(provider, .unlinked, replacing: true) == false)
      #expect(throws: MailConnectFailure.takenByOtherIPhone) { try admit(provider, .otherDevice) }
    }
    for phase in [MailboxPhase.reconnectRequired, .halted] {
      #expect(try admit(.gmail, phase) == false)
      #expect(throws: MailConnectFailure.failed("Disconnect Gmail first, then connect Outlook.")) {
        try admit(.outlook, phase)
      }
      #expect(try admit(.outlook, phase, replacing: true) == true)
    }
    for phase in [MailboxPhase.scanning, .awaitingCards, .authoringBackfill, .active] {
      #expect(throws: MailConnectFailure.alreadyConnected(address: "maya@example.com")) { try admit(.gmail, phase) }
      #expect(throws: MailConnectFailure.failed("Disconnect Gmail first, then connect Outlook.")) {
        try admit(.outlook, phase)
      }
      #expect(try admit(.outlook, phase, replacing: true) == true)
    }
  }

  /// Another iPhone takes the link after this one was offered "Connect Gmail": the offer
  /// goes with the next answer, and a connect asks again first and is refused, as it is
  /// when the server can't be asked.
  /// The server deletes the account's link whichever iPhone holds it, so an iPhone the
  /// link moved away from refuses a disconnect, which would end the other iPhone's reading.
  @Test func aLinkTakenElsewhereRefusesTheDisconnect() throws {
    #expect(throws: MailConnectFailure.takenByOtherIPhone) { try LiveMailboxConnecting.checkDisconnect(.otherDevice) }
    for phase in [MailboxPhase.unlinked, .scanning, .awaitingCards, .authoringBackfill, .active, .reconnectRequired,
                  .halted] {
      try LiveMailboxConnecting.checkDisconnect(phase)
    }
  }

  /// One step-up for both lanes: its reason names neither Gmail nor Outlook.
  @Test func theStepUpNamesNoProvider() {
    #expect(LiveStepUp.reason("mailbox.link") == "Confirm it's you to connect this mailbox to Hasala")
    #expect(LiveStepUp.reason("mailbox.unlink") == "Confirm it's you to disconnect this mailbox")
  }

  /// Another iPhone holds the account's link (a new install or a recovered account, while
  /// the server still names the earlier iPhone, which may be gone): "Connect" is offered,
  /// and the connect takes the link over only once the person confirmed it. An unconfirmed
  /// connect (the link moved after the screen asked) and no answer are refused.
  @Test func aLinkHeldElsewhereIsTakenOverOnlyOnceConfirmed() throws {
    let other = MailboxLinkStatus.holder(isThisDevice: false, watchExpiresAtMs: nil)
    #expect(LiveMailboxConnecting.offer(phase: .unlinked, sampleLoaded: false, serverLink: .noLink) == .connect)
    try LiveMailboxConnecting.checkTakeover(.noLink)
    #expect(LiveMailboxConnecting.offer(phase: .unlinked, sampleLoaded: false, serverLink: other) == .connect)
    #expect(LiveMailboxConnecting.offer(phase: .unlinked, sampleLoaded: false, serverLink: nil) == nil)
    #expect(throws: MailConnectFailure.takenByOtherIPhone) {
      try LiveMailboxConnecting.checkTakeover(other)
    }
    try LiveMailboxConnecting.checkTakeover(other, confirmed: true)
    // That iPhone may read the other provider: the copy names none.
    #expect(MailConnectFailure.takenByOtherIPhone.message(for: .gmail) == "Your email is read on your other iPhone.")
    #expect(MailConnectFailure.takenByOtherIPhone.message(for: .outlook) == "Your email is read on your other iPhone.")
    for confirmed in [false, true] {
      #expect(throws: MailConnectFailure.offline) {
        try LiveMailboxConnecting.checkTakeover(nil, confirmed: confirmed)
      }
    }
    #expect(MailConnectFailure.offline.message(for: .gmail) == LiveMailboxConnecting.message(.offline))
    // The confirmation names the link's provider and says the other iPhone may be gone.
    #expect(MailCopy.takeoverTitle == "Read your email on this iPhone?")
    #expect(MailCopy.takeoverMessage(from: .gmail, to: .gmail)
      == "Your Gmail is read on another iPhone, or was on one you no longer have. Hasala reads it on this iPhone instead, and the other iPhone stops. Past transactions stay.")
    #expect(MailCopy.takeoverMessage(from: .outlook, to: .gmail)
      == "Your Outlook is read on another iPhone, or was on one you no longer have. Hasala reads your bank alerts from Gmail on this iPhone instead, and the other iPhone stops. Past transactions stay.")
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

  /// Live connects what the build has a client id for, before an account opens too, and
  /// holds one mailbox: no second one, a switch only once confirmed (`.replace`).
  @Test func liveConnectsWhatTheBuildHasAClientFor() throws {
    func build(google: String, outlook: String) throws -> BuildInfo {
      try BuildInfo(infoDictionary: [
        "CFBundleShortVersionString": "0.2.0", "CFBundleVersion": "1", "HasalaGitCommit": "unset",
        "HasalaEnvironment": "qa", "HasalaAPIBaseURL": "https://api.example.com", "HasalaGoogleClientID": google,
        "HasalaGoogleRedirectScheme": google == "unset" ? "unset" : "com.googleusercontent.apps.test",
        "HasalaGmailPubSubTopic": "unset", "HasalaOutlookClientID": outlook,
        "HasalaOutlookRedirectScheme": "msauth.app.hasala.ios",
      ])
    }
    let google = "test.apps.googleusercontent.com"
    let microsoft = "00000000-0000-4000-8000-000000000000"
    #expect(LiveMailboxConnecting.providers(build: try build(google: google, outlook: microsoft)) == [.gmail, .outlook])
    #expect(LiveMailboxConnecting.providers(build: try build(google: google, outlook: "unset")) == [.gmail])
    #expect(LiveMailboxConnecting.providers(build: try build(google: "unset", outlook: "unset")).isEmpty)
    let lane = LiveMailboxConnecting(runtime: { nil }, buildProviders: [.gmail, .outlook])
    #expect(lane.connectable == [.gmail, .outlook])  // no runtime open yet: the build's
    #expect(LiveMailboxConnecting(runtime: { nil }).connectable.isEmpty)
    #expect(lane.capabilities == [.connect, .signInAgain, .disconnect, .replace])
    #expect(!lane.capabilities.contains(.addSecond) && lane.holdsOneLink)
    #expect(lane.mailboxes.isEmpty && lane.offer == nil && lane.linkedProvider == nil)
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
    // Read on the other iPhone: no Disconnect and no switch from here.
    #expect(row(.otherDevice)?.readElsewhere == true && row(.otherDevice)?.state == .connected)
    #expect(row(.active)?.readElsewhere == false && row(.halted, halt: .noMailbox)?.readElsewhere == false)
    // No Outlook mailbox on the Microsoft account: a sign-in, in words that say why.
    #expect(row(.halted, halt: .noMailbox)?.state == .needsSignIn)
    #expect(row(.halted, halt: .noMailbox)?.note == MailConnectFailure.noMailboxLine(.gmail))
    let haltedOutlook = LiveMailboxConnecting.mailboxes(
      phase: .halted, halt: .noMailbox, address: "maya.k@example.com", lastSuccessAtMs: nil, bankDomains: [],
      provider: .outlook, nowMs: now
    ).first
    #expect(haltedOutlook?.note == MailConnectFailure.noMailboxLine(.outlook))
    #expect(row(.halted, halt: .gmail)?.note == nil)
    // An Outlook lane's row: its id and provider, a personal Microsoft account.
    let outlook = LiveMailboxConnecting.mailboxes(
      phase: .active, halt: nil, address: "maya.k@example.com", lastSuccessAtMs: nil, bankDomains: [],
      provider: .outlook, nowMs: now
    ).first
    #expect(outlook?.id == "outlook" && outlook?.provider == .outlook && outlook?.accountKind == "Personal Microsoft")
    #expect(row(.active)?.accountKind == nil)
  }

  /// This iPhone has never read the mailbox (a new install, a recovered account) while the
  /// server names another iPhone as the link's holder, which may be one the person no
  /// longer has: nothing is listed as read here, and the screens say the email isn't
  /// connected and offer the connect, never "Bank alerts are working".
  @Test func aLinkHeldByAnotherIPhoneIsNotShownAsWorkingHere() {
    let rows = LiveMailboxConnecting.mailboxes(
      phase: .unlinked, halt: nil, address: nil, lastSuccessAtMs: nil, bankDomains: [], nowMs: 10_000_000_000)
    #expect(rows.isEmpty)
    let offer = LiveMailboxConnecting.offer(
      phase: .unlinked, sampleLoaded: false, serverLink: .holder(isThisDevice: false, watchExpiresAtMs: nil))
    let summary = MailboxesSummary(
      rows, health: MailboxHealth(status: .notConnected, lastEmail: "", banks: ""), offer: offer)
    #expect(summary.title == "Your email isn't connected" && summary.needsYou)
    #expect(summary.detail == "Connect it so Hasala can read your bank alerts.")
    #expect(ProfileSheet.mailboxesValue(rows, known: true) == ("Not connected", nil))
    // No runtime: nothing is held elsewhere as far as this iPhone knows.
    #expect(LiveMailboxConnecting(runtime: { nil }).heldElsewhere == nil)
  }

  /// Before an account opens there is no lane status: the mailboxes aren't known, so the
  /// screens say they are checking rather than "not connected".
  @Test func noRuntimeMeansNotKnownYet() {
    let lane = LiveMailboxConnecting(runtime: { nil })
    #expect(!lane.mailboxesKnown && lane.mailboxes.isEmpty)
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
    // No mailbox on that Microsoft account: the summary says so, not that access ended.
    let noMailbox = summary(.halted, halt: .noMailbox, health: .reconnect)
    #expect(noMailbox.title == "Sign in again" && noMailbox.detail == MailConnectFailure.noMailboxLine(.gmail))
    let elsewhere = summary(.otherDevice, halt: nil, health: .working)
    #expect(elsewhere.title == "Bank alerts are working" && !elsewhere.needsYou)
  }

  @Test func homesImportPillFollowsTheFirstScan() {
    func work(_ phase: MailboxPhase?, seen: Bool = true, _ progress: MailboxProgress? = nil) -> MailImport? {
      LiveMailboxConnecting.importing(phase: phase, seen: seen, progress: progress)
    }
    let reading = MailboxProgress(stage: .downloading, done: 214, total: 268)
    for phase in [MailboxPhase.scanning, .awaitingCards, .authoringBackfill] {
      #expect(work(phase, reading) == MailImport(state: .reading, read: 214, total: 268))
    }
    let pill = work(.scanning, reading)
    #expect(pill?.label == "Reading your alerts" && pill?.count == "214 of 268" && pill?.busy == true)
    #expect(pill?.opensBankAlerts == false)
    #expect(work(.scanning)?.count == nil && work(.scanning)?.busy == true)
    let offline = work(.scanning, MailboxProgress(stage: .failed(.offline), done: 214, total: 268))
    #expect(offline?.state == .offline && offline?.label == "Offline" && offline?.count == nil && offline?.busy == false)
    for code in [MailboxHaltCode.gmail, .quota] {
      let paused = work(.scanning, MailboxProgress(stage: .failed(code), done: 214, total: 268))
      #expect(paused?.state == .paused && paused?.label == "Reading paused" && paused?.busy == false)
      #expect(paused?.count == "214 of 268" && paused?.opensBankAlerts == false)
    }
    #expect(work(.scanning, MailboxProgress(stage: .done, done: 268, total: 268)) == nil)
    for phase in [MailboxPhase.active, .unlinked, .otherDevice] {
      #expect(work(phase, reading) == nil)
    }
    #expect(work(nil) == nil)
    let stopped = work(.halted, reading)
    #expect(stopped?.label == "Reading stopped" && stopped?.busy == false && stopped?.count == nil)
    #expect(stopped?.opensBankAlerts == true)
    let signIn = work(.reconnectRequired)
    #expect(signIn?.label == "Sign in again" && signIn?.opensBankAlerts == true)
    #expect(work(.halted, seen: false) == nil)
    #expect(work(.reconnectRequired, seen: false) == nil)
  }

  @Test func aFirstScanThatGivesUpOnAPassingStopPausesThePill() {
    func totals(_ phase: MailboxPhase, _ halt: MailboxHaltCode?) -> MailboxLane.FirstScanTotals {
      var t = MailboxLane.FirstScanTotals()
      t.phase = phase
      t.haltedOn = halt
      return t
    }
    for code in [MailboxHaltCode.offline, .gmail, .quota] {
      #expect(totals(.scanning, code).pause == MailboxProgress(stage: .failed(code), done: 0, total: 0))
      #expect(totals(.authoringBackfill, code).pause?.stage == .failed(code))
    }
    #expect(totals(.scanning, nil).pause == nil)
    #expect(totals(.scanning, .stagingFull).pause == nil)
    #expect(totals(.active, nil).pause == nil)
    #expect(totals(.halted, .accountFull).pause == nil)
    #expect(totals(.reconnectRequired, .reconnectRequired).pause == nil)
  }
}

/// The grant endings of accounts that left this iPhone (gmail-sync): Google's revoke and
/// `users.stop` act on the Google account, which the next account here may link again, so
/// they run in order and a connect waits for them.
@Suite("Mail grant endings")
struct MailGrantEndsTests {
  nonisolated final class Log: Sendable {
    let entries = Mutex<[String]>([])
    func add(_ s: String) { entries.withLock { $0.append(s) } }
    var all: [String] { entries.withLock { $0 } }
  }

  @Test func nothingPendingIsSettledAtOnce() async {
    #expect(await MailGrantEnds().settled(within: .milliseconds(1)))
  }

  /// A deleted account's ending, then a wiped one's: one after the other, and a connect's
  /// wait returns only once both reached the provider.
  @Test func endingsRunInOrderAndAConnectWaitsForThem() async {
    let ends = MailGrantEnds()
    let log = Log()
    ends.enqueue {
      try? await Task.sleep(for: .milliseconds(80))
      log.add("deleted account: users.stop, revoke")
    }
    ends.enqueue { log.add("wiped account: revoke") }
    #expect(await ends.settled(within: .seconds(10)))
    log.add("connect")
    #expect(log.all == ["deleted account: users.stop, revoke", "wiped account: revoke", "connect"])
  }

  /// An ending that hangs (no network) holds a connect only for the limit.
  @Test func aHungEndingHoldsAConnectOnlyForTheLimit() async {
    let ends = MailGrantEnds()
    let release = Mutex<CheckedContinuation<Void, Never>?>(nil)
    ends.enqueue { await withCheckedContinuation { c in release.withLock { $0 = c } } }
    let start = ContinuousClock.now
    #expect(await ends.settled(within: .milliseconds(50)) == false)
    #expect(ContinuousClock.now - start < .seconds(5))
    // Let it go, so the queue's task ends with the test.
    while release.withLock({ $0 == nil }) { await Task.yield() }
    release.withLock { $0?.resume(); $0 = nil }
    #expect(await ends.settled(within: .seconds(10)))
  }

  /// A connect never signs in while an earlier ending may still reach the provider: past
  /// the wait it is refused, and once the ending is done it goes ahead.
  @Test func aConnectIsRefusedWhileAnEndingStillRuns() async {
    let ends = MailGrantEnds()
    let release = Mutex<CheckedContinuation<Void, Never>?>(nil)
    ends.enqueue { await withCheckedContinuation { c in release.withLock { $0 = c } } }
    #expect(await ends.connectGate(within: .milliseconds(50)) == .failed(.google))
    while release.withLock({ $0 == nil }) { await Task.yield() }
    release.withLock { $0?.resume(); $0 = nil }
    #expect(await ends.connectGate(within: .seconds(10)) == nil)
    #expect(await MailGrantEnds().connectGate(within: .milliseconds(1)) == nil)
  }

  /// One ending's worst case (every request at its limit, one after another) is inside a
  /// connect's wait, so in practice the connect waits for it rather than being refused.
  @Test func anEndingIsBoundedInsideTheConnectWait() {
    let worst = Duration.seconds(MailGrantEnds.requestLimit * Double(MailGrantEnds.requestsPerEnding))
    #expect(worst < MailGrantEnds.connectWait)
  }
}
