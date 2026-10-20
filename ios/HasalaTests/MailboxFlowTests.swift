import Foundation
import HasalaDesign
import HasalaModels
import Testing
import UIKit

@testable import Hasala

/// Connecting a mailbox, in setup and after it, on the in-memory mock (plan B4).
@MainActor
@Suite("Mailbox flows")
struct MailboxFlowTests: AccountSuite {
  func mailbox(_ mailboxes: [MailboxSnapshot] = []) -> MockMailbox {
    let m = MockMailbox(mailboxes: mailboxes)
    m.connectDelay = .zero
    m.step = .milliseconds(1)
    return m
  }

  /// Gmail then Outlook: two mailboxes, each syncing until the first scan finishes.
  @Test func connectingGmailThenOutlookGivesTwoMailboxes() async throws {
    let lane = mailbox()
    #expect(lane.offer == .connect)
    let gmail = MailConnectCoordinator(mailbox: lane, context: .setup(stepOf: (2, 4)))
    await gmail.connect(.gmail)
    #expect(gmail.outcome == .connected(mailboxID: "gmail-1"))
    #expect(await lane.linkState() == .scanning && lane.offer == nil)
    let outlook = MailConnectCoordinator(mailbox: lane, context: .addMailbox)
    await outlook.connect(.outlook)
    #expect(lane.mailboxes.map(\.address) == ["maya@example.com", "maya.k@example.com"])
    #expect(lane.mailboxes.allSatisfy { $0.state == .syncing })
    var counts: [String] = []
    for await _ in lane.firstScan() { if let c = lane.importing?.count { counts.append(c) } }
    #expect(!counts.isEmpty && counts.allSatisfy { $0.hasSuffix(" of 268") })
    #expect(lane.importing == nil)
    #expect(lane.mailboxes.allSatisfy { $0.state == .connected })
    #expect(await lane.linkState() == .linked && lane.connectCalls == 2)
  }

  /// A work account its admin hasn't approved, a closed Microsoft sign-in, and a closed
  /// Google sign-in (not an error: the screen stays as it was).
  @Test func outlookFailuresAreOutcomes() async {
    let lane = mailbox()
    lane.outlookAdmin = true
    let c = MailConnectCoordinator(mailbox: lane, context: .setup(stepOf: (2, 4)))
    await c.connect(.outlook)
    #expect(c.outcome == .failed(.adminApprovalNeeded(address: "maya@contoso.com")))
    #expect(MailConnectFailure.adminApprovalNeeded(address: "maya@contoso.com").message(for: .outlook)
      == "Your organisation needs to approve Hasala.")
    lane.outlookAdmin = false
    lane.outlookCancelled = true
    c.reset()
    await c.connect(.outlook)
    #expect(c.outcome == .failed(.cancelled))
    #expect(lane.mailboxes.isEmpty)
    #expect(MailConnectFailure.cancelled.message(for: .gmail) == nil)
  }

  @Test func theSameMailboxTwiceIsAlreadyConnected() async {
    let lane = mailbox([MockMailbox.outlook])
    let c = MailConnectCoordinator(mailbox: lane, context: .addMailbox)
    await c.connect(.outlook)
    #expect(c.outcome == .failed(.alreadyConnected(address: "maya.k@example.com")))
    #expect(MailConnectFailure.alreadyConnected(address: "maya.k@example.com").message(for: .outlook)
      == "maya.k@example.com is already connected.")
  }

  /// Sign in again turns the mailbox connected; disconnect keeps a grey row.
  @Test func signInAgainAndDisconnect() async throws {
    let lane = mailbox([MockMailbox.gmail, MockMailbox.needingSignIn(MockMailbox.outlook)])
    #expect(lane.offer == .signInAgain(mailboxID: "outlook-1", provider: .outlook))
    let c = MailConnectCoordinator(mailbox: lane, context: .signInAgain(mailboxID: "outlook-1"))
    await c.connect(.outlook)
    #expect(c.outcome == .connected(mailboxID: "outlook-1"))
    #expect(lane.mailboxes.last?.state == .connected && lane.offer == nil)
    try await lane.disconnect("outlook-1")
    #expect(lane.mailboxes.last?.state == .disconnected && lane.mailboxes.last?.meta == "Off since 10 Oct")
    #expect(lane.mailboxes.count == 2 && lane.offer == nil)
  }

  func answering(
    _ c: MailConnectCoordinator, _ choice: MailSwitchChoice, _ attempt: @escaping @MainActor () async -> Void
  ) async -> MailSwitchQuestion? {
    if c.presenters == 0 { c.attachPresenter() }
    let task = Task { await attempt() }
    var asked: MailSwitchQuestion?
    for _ in 0..<2_000 {
      if let q = c.question {
        asked = q
        break
      }
      if !c.busy, c.outcome != nil { break }
      try? await Task.sleep(for: .milliseconds(1))
    }
    if asked != nil { c.answer(choice) }
    await task.value
    return asked
  }

  func otherAddress(imported: Int? = 12) -> MockMailbox {
    let lane = mailbox([MockMailbox.needingSignIn(MockMailbox.outlook)])
    lane.signInAgainReads = "maya.other@example.com"
    if let imported { lane.imported["outlook-1"] = MailboxDisconnectImpact(transactions: imported, edited: 0) }
    return lane
  }

  @Test func aSignInAgainToTheSameAddressAsksNothing() async {
    let lane = mailbox([MockMailbox.needingSignIn(MockMailbox.outlook)])
    let same = MailConnectCoordinator(mailbox: lane, context: .signInAgain(mailboxID: "outlook-1"))
    await same.connect(.outlook)
    #expect(same.nowReading == nil && same.question == nil && lane.questions.isEmpty)
    #expect(same.signedInAgainLine == "Outlook connected again. Catching up from the last check.")
    #expect(MailCopy.signedInAgain(.gmail) == "Gmail connected again. Catching up from the last check.")
  }

  @Test func anotherAddressAsksFirstAndKeepSaysWhatItReads() async {
    let lane = otherAddress()
    let c = MailConnectCoordinator(mailbox: lane, context: .signInAgain(mailboxID: "outlook-1"))
    let asked = await answering(c, .keep) { await c.connect(.outlook) }
    #expect(asked == MailSwitchQuestion(
      provider: .outlook, oldAddress: "maya.k@example.com", newAddress: "maya.other@example.com",
      impact: MailboxDisconnectImpact(transactions: 12, edited: 0)))
    #expect(c.question == nil)
    #expect(c.outcome == .connected(mailboxID: "outlook-1") && c.nowReading == "maya.other@example.com")
    #expect(c.signedInAgainLine == "Now reading maya.other@example.com.")
    #expect(lane.mailboxes.first?.address == "maya.other@example.com" && lane.removed.isEmpty)
    c.reset()
    #expect(c.nowReading == nil && c.signedInAgainLine == nil)
  }

  @Test func anotherAddressRemoveSaysWhatWasRemoved() async {
    let lane = otherAddress()
    let c = MailConnectCoordinator(mailbox: lane, context: .signInAgain(mailboxID: "outlook-1"))
    #expect(await answering(c, .remove) { await c.connect(.outlook) } != nil)
    #expect(c.signedInAgainLine == "Now reading maya.other@example.com. 12 transactions removed.")
    #expect(lane.removed == ["outlook-1"])

    let failing = otherAddress(imported: 1)
    failing.switchRemoveFails = true
    let f = MailConnectCoordinator(mailbox: failing, context: .signInAgain(mailboxID: "outlook-1"))
    #expect(await answering(f, .remove) { await f.connect(.outlook) } != nil)
    #expect(f.outcome == .connected(mailboxID: "outlook-1"))
    #expect(f.signedInAgainLine
      == "Now reading maya.other@example.com. The transactions from maya.k@example.com couldn't be removed. They stay.")
    #expect(failing.removed.isEmpty && failing.mailboxes.first?.state == .connected)
  }

  @Test func tryAgainChangesNothingAndSaysNothing() async {
    let lane = otherAddress()
    let c = MailConnectCoordinator(mailbox: lane, context: .signInAgain(mailboxID: "outlook-1"))
    #expect(await answering(c, .cancel) { await c.connect(.outlook) } != nil)
    #expect(c.outcome == nil && c.failureLine == nil && c.inlineMessage == nil && c.errorScreen == nil)
    #expect(lane.mailboxes.first?.address == "maya.k@example.com" && lane.mailboxes.first?.state == .needsSignIn)
    #expect(lane.imported["outlook-1"]?.transactions == 12 && lane.removed.isEmpty)
    #expect(await answering(c, .keep) { await c.connect(.outlook) } != nil)
    #expect(c.outcome == .connected(mailboxID: "outlook-1"))
    #expect(MailConnectFailure.switchDeclined.message(for: .outlook) == nil)
    #expect(!MailConnectCoordinator.hasScreen(.switchDeclined, provider: .outlook))
  }

  @Test func aQuestionLeftOpenIsAnsweredCancel() async {
    let lane = otherAddress()
    let c = MailConnectCoordinator(mailbox: lane, context: .signInAgain(mailboxID: "outlook-1"))
    c.attachPresenter()
    let task = Task { await c.connect(.outlook) }
    while c.question == nil { await Task.yield() }
    let next = Task { await c.ask(MailSwitchQuestion(provider: .outlook, oldAddress: "a", newAddress: "b")) }
    await task.value
    #expect(c.outcome == nil && lane.mailboxes.first?.address == "maya.k@example.com")
    c.answer(.keep)
    #expect(await next.value == .keep && c.question == nil)
  }

  @Test func aQuestionWithNoPresenterIsAnsweredCancelAtOnce() async {
    let lane = otherAddress()
    let c = MailConnectCoordinator(mailbox: lane, context: .signInAgain(mailboxID: "outlook-1"))
    await c.connect(.outlook)
    #expect(lane.questions.count == 1 && c.question == nil && c.outcome == nil)
    #expect(lane.mailboxes.first?.address == "maya.k@example.com" && lane.mailboxes.first?.state == .needsSignIn)
    #expect(lane.removed.isEmpty && lane.imported["outlook-1"]?.transactions == 12)
  }

  @Test func leavingTheForegroundOrThePresenterAnswersCancel() async {
    for leave in [0, 1] {
      let lane = otherAddress()
      let c = MailConnectCoordinator(mailbox: lane, context: .signInAgain(mailboxID: "outlook-1"))
      c.attachPresenter()
      let task = Task { await c.connect(.outlook) }
      for _ in 0..<2_000 where c.question == nil { try? await Task.sleep(for: .milliseconds(1)) }
      #expect(c.question != nil)
      if leave == 0 {
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
      } else {
        c.detachPresenter()
      }
      await task.value
      #expect(c.question == nil && c.outcome == nil)
      #expect(lane.mailboxes.first?.address == "maya.k@example.com" && lane.mailboxes.first?.state == .needsSignIn)
      #expect(lane.removed.isEmpty)
    }
  }

  @Test func anUnknownCountOffersRemoveWithoutANumber() {
    let q = MailSwitchQuestion(
      provider: .gmail, oldAddress: "maya@example.com", newAddress: "maya.home@example.com", oldHasNoMailbox: true,
      countUnknown: true)
    #expect(q.offersRemove)
    #expect(MailCopy.switchAddressMessage(q)
      == "maya@example.com has no mailbox Hasala can read. Switch to maya.home@example.com? Keep the transactions from maya@example.com, or remove them from your totals.")
    #expect(!MailSwitchQuestion(provider: .gmail, oldAddress: "a", newAddress: "b").offersRemove)
    #expect(MailCopy.signedInAgain(.gmail, nowReading: "maya.home@example.com", removal: .removed(nil))
      == "Now reading maya.home@example.com. The old transactions were removed.")
  }

  @Test func anotherAddressWithNothingImportedOffersOnlyTheSwitch() async {
    let lane = otherAddress(imported: 0)
    let c = MailConnectCoordinator(mailbox: lane, context: .signInAgain(mailboxID: "outlook-1"))
    let asked = await answering(c, .keep) { await c.connect(.outlook) }
    #expect(asked?.impact == nil)
    #expect(c.signedInAgainLine == "Now reading maya.other@example.com.")

    var noMailbox = MockMailbox.needingSignIn(MockMailbox.outlook)
    noMailbox.note = MailConnectFailure.noMailboxLine(.outlook)
    let quiet = mailbox([noMailbox])
    quiet.signInAgainReads = "maya.other@example.com"
    quiet.imported["outlook-1"] = nil
    let q = MailConnectCoordinator(mailbox: quiet, context: .signInAgain(mailboxID: "outlook-1"))
    await q.connect(.outlook)
    #expect(quiet.questions.isEmpty && q.outcome == .connected(mailboxID: "outlook-1"))
  }

  @Test func theSwitchQuestionSaysWhatHappens() {
    let impact = MailboxDisconnectImpact(transactions: 12, edited: 2)
    let q = MailSwitchQuestion(
      provider: .gmail, oldAddress: "maya@example.com", newAddress: "maya.home@example.com", impact: impact)
    #expect(MailCopy.switchAddressTitle(q) == "You signed in as maya.home@example.com.")
    #expect(MailCopy.switchAddressMessage(q)
      == "Hasala reads maya@example.com. Switch to maya.home@example.com? maya@example.com brought in 12 transactions. Keep them, or remove them from your totals. Removing also takes the 2 you changed.")
    var none = q
    none.impact = nil
    #expect(MailCopy.switchAddressMessage(none) == "Hasala reads maya@example.com. Switch to maya.home@example.com?")
    var halted = q
    halted.oldHasNoMailbox = true
    halted.impact = MailboxDisconnectImpact(transactions: 1, edited: 0)
    #expect(MailCopy.switchAddressMessage(halted)
      == "maya@example.com has no mailbox Hasala can read. Switch to maya.home@example.com? maya@example.com brought in 1 transaction. Keep them, or remove them from your totals.")
    #expect(MailCopy.keepOnSwitch("Switch", impact) == "Switch, keep the 12 transactions")
    #expect(MailCopy.keepOnSwitch("Use Outlook", MailboxDisconnectImpact(transactions: 1, edited: 0))
      == "Use Outlook, keep the 1 transaction")
    #expect(MailCopy.switchMessage(from: .gmail, to: .outlook, impact: impact)
      == "This replaces your Gmail connection. Hasala reads your bank alerts from Outlook instead. It brought in 12 transactions. Keep them, or remove them from your totals. Removing also takes the 2 you changed.")
    #expect(MailCopy.switchMessage(from: .gmail, to: .outlook).hasSuffix("Past transactions stay."))
    #expect(MailCopy.added(.outlook, removal: .removed(1)) == "Outlook connected. Checking for alerts. 1 transaction removed.")
    #expect(MailCopy.disconnected(.gmail, removed: 42) == "Gmail disconnected. 42 transactions removed.")
  }

  @Test func aProviderSwitchCanRemoveTheOldTransactions() async throws {
    let lane = try #require(AuthScenario.session(for: .gmailLinked, releaseSurface: true).services.mailbox as? MockMailbox)
    lane.connectDelay = .zero
    #expect(await lane.disconnectImpact("gmail-1") == MailboxDisconnectImpact(transactions: 42, edited: 3))
    let c = MailConnectCoordinator(mailbox: lane, context: .addMailbox)
    await c.connect(.outlook, replacing: true, removingOld: true)
    #expect(c.outcome == .connected(mailboxID: "outlook-1"))
    #expect(c.addedLine == "Outlook connected. Checking for alerts. 42 transactions removed.")
    #expect(lane.removed == ["gmail-1"] && lane.mailboxes.map(\.provider) == [.outlook])

    let keep = try #require(AuthScenario.session(for: .gmailLinked, releaseSurface: true).services.mailbox as? MockMailbox)
    keep.connectDelay = .zero
    let k = MailConnectCoordinator(mailbox: keep, context: .addMailbox)
    await k.connect(.outlook, replacing: true)
    #expect(k.addedLine == "Outlook connected. Checking for alerts." && keep.removed.isEmpty)
    let unconfirmed = MailConnectCoordinator(mailbox: keep, context: .addMailbox)
    await unconfirmed.connect(.gmail, removingOld: true)
    #expect(!unconfirmed.removingOld)
  }

  /// The same mailbox added again after a disconnect brings its grey row back, syncing:
  /// Bank alerts never lists one address twice.
  @Test func reconnectingADisconnectedMailboxRevivesItsRow() async throws {
    let lane = mailbox([MockMailbox.gmail])
    try await lane.disconnect("gmail-1")
    let c = MailConnectCoordinator(mailbox: lane, context: .addMailbox)
    await c.connect(.gmail)
    #expect(c.outcome == .connected(mailboxID: "gmail-1"))
    #expect(lane.mailboxes.map(\.id) == ["gmail-1"])
    #expect(lane.mailboxes.first?.state == .syncing && lane.mailboxes.first?.meta == "Checking now")
    #expect(lane.mailboxes.first?.address == MockMailbox.gmailAddress)
  }

  /// Which failures get a screen of their own and which show on the screen that tried:
  /// a closed Google sheet says nothing; a closed or declined Microsoft sign-in and an
  /// admin's approval have their screens; the rest are a line.
  @Test func failuresShowWhereThePlanSays() async {
    let lane = mailbox()
    lane.outlookCancelled = true
    let c = MailConnectCoordinator(mailbox: lane, context: .addMailbox)
    await c.connect(.outlook)
    #expect(c.errorScreen == .cancelled && c.inlineMessage == nil)
    lane.outlookCancelled = false
    lane.outlookAdmin = true
    await c.connect(.outlook)
    #expect(c.errorScreen == .adminApprovalNeeded(address: "maya@contoso.com") && c.inlineMessage == nil)
    lane.outlookAdmin = false
    lane.offline = true
    await c.connect(.gmail)
    #expect(c.errorScreen == nil && c.inlineMessage == "You're offline. Connect Gmail when you're back online.")
    lane.offline = false
    lane.alreadyConnected = true
    await c.connect(.outlook)
    #expect(c.errorScreen == nil && c.inlineMessage == "maya.k@example.com is already connected.")
    #expect(MailConnectCoordinator.hasScreen(.cancelled, provider: .gmail) == false)
    #expect(MailConnectCoordinator.hasScreen(.adminApprovalNeeded(address: "a@example.com"), provider: .gmail))
    #expect(ConnectProviderView.tone(.alreadyConnected(address: "a@example.com")) == .accent)
    #expect(ConnectProviderView.tone(.offline) == .warning && ConnectProviderView.tone(.failed("x")) == .error)
  }

  @Test func aMicrosoftAccountWithNoMailboxHasItsScreenAndAnotherAccountConnects() async {
    let lane = mailbox([MockMailbox.gmail])
    lane.outlookNoMailbox = true
    let c = MailConnectCoordinator(mailbox: lane, context: .addMailbox)
    await c.connect(.outlook)
    #expect(c.outcome == .failed(.noMailbox(.outlook)))
    #expect(c.errorScreen == .noMailbox(.outlook) && c.inlineMessage == nil)
    #expect(MailConnectCoordinator.hasScreen(.noMailbox(.gmail), provider: .gmail))
    #expect(ConnectProviderView.tone(.noMailbox(.outlook)) == .error)
    c.reset()
    await c.connect(.outlook)
    #expect(c.outcome == .connected(mailboxID: "outlook-1") && c.errorScreen == nil)
    #expect(lane.connectCalls == 2)

    let broken = mailbox([MockMailbox.needingSignIn(MockMailbox.outlook)])
    broken.outlookNoMailbox = true
    let again = MailConnectCoordinator(mailbox: broken, context: .signInAgain(mailboxID: "outlook-1"))
    await again.connect(.outlook)
    #expect(again.errorScreen == .noMailbox(.outlook))
    await again.connect(.outlook)
    #expect(again.outcome == .connected(mailboxID: "outlook-1") && broken.signInCalls == 2)
  }

  @Test func aRetryAfterAConfirmedSwitchStillReplaces() async {
    let lane = mailbox([MockMailbox.gmail])
    lane.holdOneLink()
    lane.outlookNoMailbox = true
    let c = MailConnectCoordinator(mailbox: lane, context: .addMailbox)
    #expect(c.replaced(by: .outlook)?.id == "gmail-1")
    await c.connect(.outlook, replacing: true)
    #expect(c.errorScreen == .noMailbox(.outlook))
    #expect(lane.mailboxes.map(\.id) == ["gmail-1"])
    c.reset()
    await c.retry(.outlook)
    #expect(lane.replacingCalls == [true, true])
    #expect(c.outcome == .connected(mailboxID: "outlook-1"))
    #expect(lane.mailboxes.map(\.id) == ["outlook-1"])

    let unconfirmed = mailbox([MockMailbox.gmail])
    unconfirmed.holdOneLink()
    let u = MailConnectCoordinator(mailbox: unconfirmed, context: .addMailbox)
    await u.connect(.outlook)
    await u.retry(.outlook)
    #expect(unconfirmed.replacingCalls == [false, false])
    #expect(u.outcome == .failed(.failed("Disconnect Gmail first, then connect Outlook.")))

    let other = mailbox([MockMailbox.gmail])
    other.holdOneLink()
    other.outlookNoMailbox = true
    let o = MailConnectCoordinator(mailbox: other, context: .addMailbox)
    await o.connect(.outlook, replacing: true)
    await o.retry(.gmail)
    #expect(other.replacingCalls == [true, false])
  }

  @Test func aGoogleAccountWithNoGmailHasItsScreenAndAnotherAccountConnects() async {
    let lane = mailbox()
    lane.gmailNoMailbox = true
    let c = MailConnectCoordinator(mailbox: lane, context: .addMailbox)
    await c.connect(.gmail)
    #expect(c.outcome == .failed(.noMailbox(.gmail)))
    #expect(c.errorScreen == .noMailbox(.gmail) && c.inlineMessage == nil && c.failedWithNoMailbox)
    c.reset()
    await c.retry(.gmail)
    #expect(c.outcome == .connected(mailboxID: "gmail-1") && c.errorScreen == nil && !c.failedWithNoMailbox)
  }

  @Test func aSignInAgainWithNoMailboxIsHandedToTheErrorScreen() async {
    let lane = mailbox([MockMailbox.needingSignIn(MockMailbox.outlook)])
    lane.outlookNoMailbox = true
    let c = MailConnectCoordinator(mailbox: lane, context: .signInAgain(mailboxID: "outlook-1"))
    await c.connect(.outlook)
    #expect(c.failedWithNoMailbox)
    let router = AppRouter()
    router.open(.profile, profile: [.bankAlerts])
    MailConnectCoordinator.hand(c, to: router)
    #expect(router.profile == [.bankAlerts, .connectMail(.outlook)])
    #expect(MailConnectCoordinator.handed(.gmail) == nil)
    #expect(MailConnectCoordinator.handed(.outlook) === c)
    #expect(MailConnectCoordinator.handed(.outlook) == nil)

    MailConnectCoordinator.hand(c, to: router)
    router.sheet = nil
    router.sheetDismissed()
    #expect(MailConnectCoordinator.handed(.outlook) == nil)

    MailConnectCoordinator.hand(c, to: router)
    #expect(router.profile.isEmpty)
    #expect(MailConnectCoordinator.handed(.outlook) == nil)

    let cancelled = mailbox([MockMailbox.needingSignIn(MockMailbox.outlook)])
    cancelled.outlookCancelled = true
    let k = MailConnectCoordinator(mailbox: cancelled, context: .signInAgain(mailboxID: "outlook-1"))
    await k.connect(.outlook)
    #expect(!k.failedWithNoMailbox && k.failureLine == "Microsoft sign-in didn't finish. Nothing changed.")
  }

  @Test func theNoMailboxScreenSaysWhatToDo() {
    let copy = MailConnectErrorView.copy(.noMailbox(.outlook), .outlook)
    #expect(copy.title == "Outlook isn't connected.")
    #expect(copy.subtitle == "This Microsoft account has no Outlook mailbox. Sign in with the account your bank alerts go to, such as you@outlook.com or you@hotmail.com. Nothing was connected and nothing was read.")
    #expect(copy.reasons == nil)
    #expect(MailConnectErrorView.otherAccountTitle(.outlook) == "Use another Microsoft account")
    let google = MailConnectErrorView.copy(.noMailbox(.gmail), .gmail)
    #expect(google.title == "Gmail isn't connected.")
    #expect(google.subtitle == "This Google account has no Gmail. Sign in with the account your bank alerts go to. Nothing was connected and nothing was read.")
    #expect(MailConnectErrorView.otherAccountTitle(.gmail) == "Use another Google account")
  }

  /// Setup's connect screen after Back from the first scan shows the mailbox it connected
  /// (from the service, so a new screen or a relaunch shows it too) and no second sign-in;
  /// Add a mailbox never treats an earlier mailbox as this attempt's.
  @Test func theConnectedStateComesFromTheService() async {
    let lane = mailbox()
    let first = MailConnectCoordinator(mailbox: lane, context: .setup(stepOf: (2, 4)))
    #expect(first.connectedMailbox(.outlook) == nil)
    await first.connect(.outlook)
    #expect(first.connectedMailbox(.outlook)?.address == "maya.k@example.com")
    let back = MailConnectCoordinator(mailbox: lane, context: .setup(stepOf: (2, 4)))
    #expect(back.connectedMailbox(.outlook)?.id == "outlook-1")
    #expect(back.connectedMailbox(.gmail) == nil)
    #expect(lane.connectCalls == 1)
    let add = MailConnectCoordinator(mailbox: lane, context: .addMailbox)
    #expect(add.connectedMailbox(.outlook) == nil)
  }

  /// The two error screens in the boards' words for Microsoft, and the same pattern for
  /// Google, which names no Outlook.
  @Test func theErrorScreensSayWhatHappened() {
    let admin = MailConnectErrorView.copy(.adminApprovalNeeded(address: "maya@contoso.com"), .outlook)
    #expect(admin.title == "Your organisation needs to approve Hasala.")
    #expect(admin.subtitle == "maya@contoso.com is a work or school account. Its admin has to allow Hasala to read mail before it can connect. Nothing was connected.")
    #expect(admin.reasons?.title == "What you can do" && admin.reasons?.numbered == true)
    #expect(admin.reasons?.items.map(\.title) == ["Ask your IT admin", "Use another mailbox"])
    #expect(admin.reasons?.items.first?.detail == "They approve Hasala once in Microsoft Entra. Then come back and try again.")
    let cancelled = MailConnectErrorView.copy(.cancelled, .outlook)
    #expect(cancelled.title == "Outlook isn't connected.")
    #expect(cancelled.subtitle == "Microsoft sign-in was cancelled or didn't finish. Nothing was connected and nothing was read.")
    #expect(cancelled.reasons?.items.map(\.title) == ["Cancel or Back on Microsoft's screen", "Permissions not accepted"])
    #expect(cancelled.reasons?.numbered == false)
    let google = MailConnectErrorView.copy(.adminApprovalNeeded(address: "maya@example.org"), .gmail)
    let words = [google.title, google.subtitle] + (google.reasons?.items.flatMap { [$0.title, $0.detail] } ?? [])
    #expect(!words.contains { $0.contains("Outlook") || $0.contains("Microsoft") })
    #expect(MailConnectErrorView.copy(.cancelled, .gmail).title == "Gmail isn't connected.")
    #expect(MailConnectErrorView.copy(.offline, .gmail).subtitle
      == "You're offline. Connect Gmail when you're back online. Nothing was connected.")
  }

  /// "Choose your email" names a connected mailbox's address and offers another account.
  @Test func aConnectedProviderNamesItsAddress() {
    #expect(ChooseEmailSheet.subtitle(.gmail, mailboxes: [MockMailbox.gmail])
      == "maya@example.com is connected. Add another Google account.")
    #expect(ChooseEmailSheet.subtitle(.outlook, mailboxes: [MockMailbox.gmail]) == nil)
    var off = MockMailbox.outlook
    off.state = .disconnected
    #expect(ChooseEmailSheet.subtitle(.outlook, mailboxes: [off]) == nil)
    // A first import reads already.
    var syncing = MockMailbox.outlook
    syncing.state = .syncing
    #expect(ChooseEmailSheet.subtitle(.outlook, mailboxes: [syncing])
      == "maya.k@example.com is connected. Add another Microsoft account.")
    // One link held: no second account of the same provider is offered.
    #expect(ChooseEmailSheet.subtitle(.gmail, mailboxes: [MockMailbox.gmail], oneLink: true)
      == "maya@example.com is connected.")
  }

  /// The chooser's copy with one link held promises no second mailbox (Release, live); the
  /// Debug copy offers one; "Use another email" says its pick replaces the mailbox read now.
  @Test func theChooserPromisesOneMailboxWhereOneIsHeld() {
    #expect(ChooseEmailTitle.setup.footnote(oneLink: true) == "You can change it later in Profile › Bank alerts.")
    #expect(ChooseEmailTitle.setup.footnote(oneLink: false).contains("add another mailbox"))
    #expect(ChooseEmailTitle.addMailbox.subtitle(oneLink: true) == ChooseEmailTitle.setup.subtitle(oneLink: true))
    #expect(!ChooseEmailTitle.addMailbox.subtitle(oneLink: true).contains("also"))
    #expect(ChooseEmailTitle.addMailbox.footnote(oneLink: true) == "You can disconnect it at any time.")
    #expect(ChooseEmailTitle.change.title == "Use another email")
    #expect(ChooseEmailTitle.change.footnote(oneLink: true).contains("replaces"))
    #expect(MailProviderKind.outlook.chooserSubtitle == "Outlook.com, Hotmail or Live")
    for title in [ChooseEmailTitle.setup, .addMailbox, .change] {
      for oneLink in [true, false] {
        #expect(title.subtitle(oneLink: oneLink).contains("different from the email you sign in to Hasala with"))
      }
    }
  }

  /// A mailbox that needs a new sign-in isn't connected (scenario `outlookSignIn`): Add a
  /// mailbox's Outlook row says so and where it leads, the sign-in again that the profile's
  /// connect of Outlook runs; Gmail still adds a mailbox. Setup's chooser (no offer) names
  /// the state alone.
  @Test func aMailboxThatNeedsASignInSaysSo() {
    let broken = MockMailbox.needingSignIn(MockMailbox.outlook)
    let lane = mailbox([MockMailbox.gmail, broken])
    let offer = lane.offer
    #expect(offer == .signInAgain(mailboxID: "outlook-1", provider: .outlook))
    #expect(ChooseEmailSheet.subtitle(.outlook, mailboxes: lane.mailboxes, offer: offer)
      == "maya.k@example.com needs a new sign-in. Sign in to Outlook again.")
    #expect(ConnectMailPage.context(.outlook, offer: offer) == .signInAgain(mailboxID: "outlook-1"))
    #expect(ChooseEmailSheet.subtitle(.gmail, mailboxes: lane.mailboxes, offer: offer)
      == "maya@example.com is connected. Add another Google account.")
    #expect(ConnectMailPage.context(.gmail, offer: offer) == .addMailbox)
    #expect(ChooseEmailSheet.subtitle(.outlook, mailboxes: [broken]) == "maya.k@example.com needs a new sign-in.")
    #expect(ConnectMailPage.context(.outlook, offer: .connect) == .addMailbox)
  }

  /// A connect or a new sign-in on a screen that goes as it ends hands its moment to Bank
  /// alerts, which takes it once.
  @Test func bankAlertsTakesTheMomentOnce() {
    MailboxMoment.hand(.added(mailboxID: "outlook-2"))
    #expect(MailboxMoment.pendingAddition == "outlook-2")
    #expect(MailboxMoment.take() == .added(mailboxID: "outlook-2"))
    #expect(MailboxMoment.take() == nil)
    MailboxMoment.hand(.signedInAgain(mailboxID: "outlook-1"))
    #expect(MailboxMoment.pendingAddition == nil)
    #expect(MailboxMoment.take() == .signedInAgain(mailboxID: "outlook-1"))
    #expect(MailboxMoment.pending == nil)
  }

  /// The success haptic waits for the motion it marks to come to rest: the celebrate
  /// spring, the Reduce Motion fade, nothing when motion is settled.
  @Test func theHapticWaitsForTheMotionToSettle() {
    #expect(MotionPolicy().settleDelay(.celebrate) == .seconds(HMotion.celebrateResponse))
    #expect(MotionPolicy(reduceMotion: true).settleDelay(.celebrate) == .seconds(HMotion.reduceMotionFade))
    #expect(MotionPolicy(settled: true).settleDelay(.celebrate) == .zero)
    #expect(MotionPolicy().settleDelay(.stateSwap) == .seconds(HMotion.fade))
    #expect(BankAlertsPage.popSettle(MotionPolicy(settled: true)) == .zero)
    #expect(BankAlertsPage.popSettle(MotionPolicy()) == .milliseconds(200))
  }

  /// Bank alerts' hero in a word, from the same summary as the Profile card: Working (one
  /// mailbox still syncing beside a working one keeps it, Paper 1NYL), Importing, Sign in
  /// again aimed at the first mailbox that needs it, Needs you, Not connected.
  @Test func theHeroSaysItInAWord() {
    func hero(
      _ m: [MailboxSnapshot], _ status: MailboxHealth.Status = .working, offer: MailOffer? = nil, read: MonthRead? = nil
    ) -> BankAlertsPage.Hero {
      let health = MailboxHealth(status: status, lastEmail: "4 min ago", banks: "Emirates NBD and DIB")
      return BankAlertsPage.Hero(summary: MailboxesSummary(m, health: health, offer: offer), health: health,
                                 mailboxes: m, offer: offer, read: read)
    }
    var syncing = MockMailbox.outlook
    syncing.state = .syncing
    let working = hero([MockMailbox.gmail, syncing], read: MonthRead(count: 214, month: "October"))
    #expect(working.kind == .working && working.title == "Working" && working.hue == .mint)
    #expect(working.detail == "Last email 4 min ago\n214 read in October")
    // Before the month's count is known, the banks.
    #expect(hero([MockMailbox.gmail]).detail == "Last email 4 min ago\nEmirates NBD and DIB")
    #expect(hero([syncing], .importing).title == "Importing")
    let broken = hero([MockMailbox.gmail, MockMailbox.needingSignIn(MockMailbox.outlook)],
                      offer: .signInAgain(mailboxID: "outlook-1", provider: .outlook))
    #expect(broken.kind == .signInAgain(mailboxID: "outlook-1", provider: .outlook) && broken.hue == .sand)
    #expect(broken.detail == "Microsoft ended access to maya.k@example.com on Wed\u{00A0}7\u{00A0}Oct. Your Gmail still works.")
    // Google's own, alone: no other mailbox to name.
    let gmail = hero([MockMailbox.needingSignIn(MockMailbox.gmail)],
                     offer: .signInAgain(mailboxID: "gmail-1", provider: .gmail))
    #expect(gmail.detail == "Google ended access to maya@example.com on Wed\u{00A0}7\u{00A0}Oct.")
    #expect(hero([MockMailbox.gmail], .quiet).title == "Needs you")
    #expect(hero([MockMailbox.gmail], .quiet).stoppedID == nil)
    #expect(working.stoppedID == nil && broken.stoppedID == nil)
    var halted = MockMailbox.outlook
    halted.note = "Reading your bank alerts stopped."
    let stopped = hero([MockMailbox.gmail, halted], .reconnect)
    #expect(stopped.kind == .needsYou && stopped.stoppedID == "outlook-1")
    #expect(stopped.detail == "Hasala stopped reading maya.k@example.com. Your Gmail still works.")
    let none = hero([], .notConnected, offer: .connect)
    #expect(none.kind == .notConnected && none.detail == "Add a mailbox so Hasala can read your bank alerts.")
  }

  /// Before the mailbox state is read, the hero, the Profile card and the Settings row say
  /// they are checking: never "Not connected" with "Add a mailbox" over a mailbox that is.
  @Test func beforeTheStateIsReadItSaysChecking() {
    let health = MailboxHealth(status: .notConnected, lastEmail: "", banks: "")
    let summary = MailboxesSummary([], health: health, offer: .connect, known: false)
    #expect(summary.title == "Checking your email" && !summary.needsYou)
    let hero = BankAlertsPage.Hero(summary: summary, health: health, mailboxes: [], offer: .connect, known: false)
    #expect(hero.kind == .checking && hero.title == "Checking" && hero.detail == summary.detail)
    #expect(ProfileSheet.mailboxesValue([], known: false) == ("Checking", nil))
  }

  /// Profile › Settings › Mailboxes says what the mailbox is doing: none, the provider
  /// read, or a sign-in needed.
  /// A connect while another iPhone holds the account's link asks first ("Read your email
  /// on this iPhone?"), with the link's provider; a new sign-in, which takes nothing over,
  /// never does, and neither does a connect with no link held elsewhere.
  @Test func aConnectAsksBeforeItTakesTheLinkOver() {
    let lane = CountingMailbox(MockMailbox(mailboxes: []))
    #expect(MailConnectCoordinator(mailbox: lane, context: .addMailbox).takesOver == nil)
    lane.heldElsewhere = .outlook
    #expect(MailConnectCoordinator(mailbox: lane, context: .addMailbox).takesOver == .outlook)
    #expect(MailConnectCoordinator(mailbox: lane, context: .setup(stepOf: nil)).takesOver == .outlook)
    #expect(MailConnectCoordinator(mailbox: lane, context: .signInAgain(mailboxID: "outlook")).takesOver == nil)
    // Setup's link passes it through.
    #expect(SetupMailLink(base: lane).heldElsewhere == .outlook)
  }

  @Test func theSettingsRowNamesTheMailbox() {
    #expect(ProfileSheet.mailboxesValue([], known: true) == ("Not connected", nil))
    var gone = MockMailbox.gmail
    gone.state = .disconnected
    #expect(ProfileSheet.mailboxesValue([gone], known: true) == ("Not connected", nil))
    #expect(ProfileSheet.mailboxesValue([MockMailbox.gmail], known: true) == ("Gmail", nil))
    #expect(ProfileSheet.mailboxesValue([MockMailbox.gmail, MockMailbox.outlook], known: true) == ("Gmail and Outlook", nil))
    #expect(ProfileSheet.mailboxesValue([MockMailbox.needingSignIn(MockMailbox.gmail)], known: true)
      == ("Sign in again", .warning))
  }

  @Test func bankAlertsCountsUnreadableMail() {
    #expect(BankAlertsPage.unreadableLine(1) == "1 email we couldn't read")
    #expect(BankAlertsPage.unreadableLine(4) == "4 emails we couldn't read")
    #expect(BankAlertsPage.unreadableDetail == "Kept for you to sort by hand")
    #expect(!mailbox().connectRefused)
  }

  /// A bank says where its alerts are read; a mailbox page explains a lost sign-in.
  @Test func banksAndMailboxesSayWhereAndWhy() {
    #expect(BankAlertsPage.bankDetail(.enbd, lastEmail: "4 min ago", checking: false) == "Last email 4 min ago")
    #expect(BankAlertsPage.bankDetail(.dib, lastEmail: "2 h ago", checking: false)
      == "Last email 2 h ago · Arabic alerts")
    #expect(BankAlertsPage.bankDetail(.enbd, lastEmail: nil, checking: true) == "Checking now")
    #expect(BankAlertsPage.bankDetail(.dib, lastEmail: nil, checking: false) == "No alerts read yet · Arabic alerts")
    // The mock knows Paper's numbers once a mailbox has read, and none on a first import.
    let lane = mailbox([MockMailbox.gmail])
    #expect(lane.lastEmail(.enbd) == "4 min ago" && lane.lastEmail(.dib) == "2 h ago")
    #expect(lane.readThisMonth == MonthRead(count: 214, month: "October"))
    var syncing = MockMailbox.outlook
    syncing.state = .syncing
    let fresh = mailbox([syncing])
    #expect(fresh.lastEmail(.dib) == nil && fresh.readThisMonth == nil)
    #expect(MailboxDetailPage.signInBody(MockMailbox.needingSignIn(MockMailbox.outlook))
      == "This happens after a password change, a long time signed out, or a work policy. No new Outlook alerts since Wed 7 Oct. Sign in again and the iPhone catches up. Nothing else changes.")
    // Live's no-mailbox halt: a sign-in the provider didn't end, said in the row's words.
    var noMailbox = MockMailbox.needingSignIn(MockMailbox.outlook)
    noMailbox.note = MailConnectFailure.noMailboxLine(.outlook)
    #expect(MailboxDetailPage.signInBody(noMailbox) == noMailbox.note)
    #expect(MailboxDetailPage.signInHeading(noMailbox) == "Sign in with another account")
    #expect(MailboxDetailPage.signInHeading(MockMailbox.needingSignIn(MockMailbox.outlook))
      == "Microsoft ended Hasala's access")
    #expect(MailCopy.disconnectMessage(.outlook)
      == "Hasala stops reading this mailbox and forgets its sign-in. Past transactions stay. To remove the permission on Microsoft's side too, visit account.live.com/consent/Manage.")
    // Disconnect revokes Hasala's access at Google, and the alert says so (Microsoft has no
    // revoke, so its alert sends the person to Microsoft's page).
    #expect(MailCopy.disconnectMessage(.gmail)
      == "Hasala stops reading this mailbox, ends its access at Google and deletes its sign-in from this iPhone. Past transactions stay. To check on Google's side, visit myaccount.google.com/permissions.")
    #expect(MailboxDetailPage.readElsewhereFootnote(.gmail)
      == "Your other iPhone reads this mailbox and holds its sign-in. Disconnect it there, or remove Hasala at myaccount.google.com/permissions.")
    #expect(MailCopy.banks([.enbd, .dib]) == "Emirates NBD and DIB")
  }

  /// A sign-in again that didn't finish is a line, not a screen: nothing changed.
  @Test func aSignInAgainThatDidNotFinishIsALine() async {
    let lane = mailbox([MockMailbox.gmail, MockMailbox.needingSignIn(MockMailbox.outlook)])
    lane.outlookCancelled = true
    let c = MailConnectCoordinator(mailbox: lane, context: .signInAgain(mailboxID: "outlook-1"))
    await c.connect(.outlook)
    #expect(c.failureLine == "Microsoft sign-in didn't finish. Nothing changed.")
    #expect(lane.mailboxes.last?.state == .needsSignIn && lane.signInCalls == 1)
    lane.outlookCancelled = false
    await c.connect(.outlook)
    #expect(c.failureLine == nil && lane.mailboxes.last?.state == .connected)
  }

  /// Maya's Gmail has the one alert Paper shows it couldn't read; a new account has none.
  @Test func theMockKnowsWhatItCouldNotRead() {
    #expect(MockMailbox(mailboxes: [MockMailbox.gmail]).unreadableMail == [MockMailbox.unreadable])
    #expect(MockMailbox().unreadableMail.isEmpty)
  }

  /// Main's `connectingOutlookAfterSkippingScans`: the email step skipped, Add a mailbox
  /// connects Outlook with no confirmation (nothing to replace), its first scan finishes,
  /// and the account reads one Outlook mailbox.
  @Test func connectingOutlookAfterSkippingScans() async throws {
    let lane = try #require(AuthScenario.session(for: .gmailSkipped, releaseSurface: true).services.mailbox as? MockMailbox)
    lane.connectDelay = .zero
    lane.step = .milliseconds(1)
    #expect(lane.offer == .connect && lane.replaced(by: .outlook) == nil)
    let c = MailConnectCoordinator(mailbox: lane, context: .addMailbox)
    #expect(c.replaced(by: .outlook) == nil)
    await c.connect(.outlook)
    #expect(c.outcome == .connected(mailboxID: "outlook-1") && c.inlineMessage == nil && c.errorScreen == nil)
    var last: ScanProgress?
    for await p in lane.firstScan() { last = p }
    #expect(last?.phase == .finished)
    // Outlook's trust gate is closed: every alert waits for review, as live.
    #expect(last?.summary?.sortedThemselves == 0 && last?.summary?.toReview == last?.summary?.total)
    #expect(lane.mailboxes.map(\.provider) == [.outlook] && lane.mailboxes.first?.state == .connected)
    #expect(lane.linkedProvider == .outlook)
  }

  /// Main's `switchingFromGmailToOutlookIsConfirmed`, on the one-link (Release) mock: Gmail
  /// is linked, so Outlook's connect replaces it, which the screen confirms first. Without
  /// the confirmation the connect is refused and Gmail stays; confirmed, the account reads
  /// one mailbox, Outlook's. Disconnect then connect replaces nothing.
  /// A mailbox read on the account's other iPhone is not this iPhone's to switch: with one
  /// link held, no connect of the other provider offers to replace it.
  @Test func aMailboxReadElsewhereIsNotReplaced() {
    var elsewhere = MockMailbox.gmail
    elsewhere.readElsewhere = true
    let lane = mailbox([elsewhere])
    lane.holdOneLink()
    #expect(lane.holdsOneLink && lane.replaced(by: .outlook) == nil)
    let c = MailConnectCoordinator(mailbox: lane, context: .addMailbox)
    #expect(c.replaced(by: .outlook) == nil)
  }

  @Test func switchingFromGmailToOutlookIsConfirmed() async throws {
    let lane = try #require(AuthScenario.session(for: .gmailLinked, releaseSurface: true).services.mailbox as? MockMailbox)
    lane.connectDelay = .zero
    let c = MailConnectCoordinator(mailbox: lane, context: .addMailbox)
    #expect(c.replaced(by: .outlook)?.id == "gmail-1")
    #expect(c.replaced(by: .gmail) == nil)
    #expect(MailCopy.switchMessage(from: .gmail, to: .outlook)
      .hasPrefix("This replaces your Gmail connection. Hasala reads your bank alerts from Outlook instead."))
    await c.connect(.outlook)
    #expect(c.outcome == .failed(.failed("Disconnect Gmail first, then connect Outlook.")))
    #expect(lane.mailboxes.map(\.id) == ["gmail-1"] && lane.linkedProvider == .gmail)
    c.reset()
    await c.connect(.outlook, replacing: true)
    #expect(c.outcome == .connected(mailboxID: "outlook-1"))
    #expect(lane.mailboxes.map(\.provider) == [.outlook] && lane.linkedProvider == .outlook)
    // Back to Gmail the long way: a disconnect leaves nothing to replace.
    try await lane.disconnect("outlook-1")
    #expect(lane.replaced(by: .gmail) == nil)
    let back = MailConnectCoordinator(mailbox: lane, context: .addMailbox)
    await back.connect(.gmail)
    #expect(back.outcome == .connected(mailboxID: "gmail-1"))
    #expect(lane.mailboxes.filter { $0.state != .disconnected }.map(\.provider) == [.gmail])
  }

  /// Ported from main under its name: Microsoft ended access to the account's one
  /// mailbox, so the offer is Outlook's sign-in again, and it reads Outlook again.
  @Test func reconnectingOutlookOffersItFirst() async throws {
    let lane = try #require(
      AuthScenario.session(for: .outlookReconnect, releaseSurface: true).services.mailbox as? MockMailbox)
    lane.connectDelay = .zero
    #expect(lane.offer == .signInAgain(mailboxID: "outlook-1", provider: .outlook))
    #expect(lane.linkedProvider == .outlook && lane.replaced(by: .outlook) == nil)
    // Gmail instead would replace the Outlook link: that asks first.
    #expect(lane.replaced(by: .gmail)?.id == "outlook-1")
    let c = MailConnectCoordinator(mailbox: lane, context: .signInAgain(mailboxID: "outlook-1"))
    #expect(c.replaced(by: .outlook) == nil)
    await c.connect(.outlook)
    #expect(c.outcome == .connected(mailboxID: "outlook-1"))
    #expect(lane.mailboxes.map(\.state) == [.connected] && lane.offer == nil)
  }

  /// The one summary the Profile card, Bank alerts and the bell draw from.
  @Test func theSummarySaysWhatIsTrue() {
    let working = MailboxHealth(status: .working, lastEmail: "4 min ago", banks: "Emirates NBD and DIB")
    let ok = MailboxesSummary([MockMailbox.gmail], health: working, offer: nil)
    #expect(ok.title == "Bank alerts are working" && ok.detail == "Last email 4 min ago\nEmirates NBD and DIB")
    #expect(ok.hue == .mint && !ok.needsYou)
    let broken = MailboxesSummary(
      [MockMailbox.gmail, MockMailbox.needingSignIn(MockMailbox.outlook)], health: working,
      offer: .signInAgain(mailboxID: "outlook-1", provider: .outlook))
    #expect(broken.title == "Sign in again")
    #expect(broken.detail == "Microsoft ended access to maya.k@example.com. Your Gmail still works.")
    #expect(broken.hue == .sand && broken.needsYou)
    // A sign-in the provider didn't end (live: no Outlook mailbox on that account) says why.
    var noMailbox = MockMailbox.needingSignIn(MockMailbox.outlook)
    noMailbox.note = MailConnectFailure.noMailboxLine(.outlook)
    let empty = MailboxesSummary(
      [noMailbox], health: working, offer: .signInAgain(mailboxID: "outlook-1", provider: .outlook))
    #expect(empty.title == "Sign in again" && empty.detail == noMailbox.note)
    #expect(BankAlertsPage.Hero.signInDetail(noMailbox, live: [noMailbox]) == noMailbox.note)
    let none = MailboxesSummary([], health: MailboxHealth(status: .notConnected, lastEmail: "", banks: ""), offer: .connect)
    #expect(none.title == "Your email isn't connected" && none.hue == .sky && none.needsYou)
    var syncing = MockMailbox.gmail
    syncing.state = .syncing
    let importing = MailboxesSummary([syncing], health: MailboxHealth(status: .importing, lastEmail: "", banks: ""),
                                     offer: nil)
    #expect(importing.title == "Importing your bank alerts" && importing.detail == "Checking now" && !importing.needsYou)
    // Reading stopped on a mailbox that still reads connected (a halt a sign-in doesn't fix).
    var halted = MockMailbox.gmail
    halted.note = "Reading your bank alerts stopped."
    let stopped = MailboxesSummary(
      [halted, MockMailbox.outlook], health: MailboxHealth(status: .reconnect, lastEmail: "", banks: ""), offer: nil)
    #expect(stopped.title == "Bank alerts stopped")
    #expect(stopped.detail == "Hasala stopped reading maya@example.com. Your Outlook still works.")
    #expect(stopped.hue == .sand && stopped.needsYou)
  }

  /// On the Release surface the scenario's mock reads like the live lane: the providers the
  /// build has a client for (Gmail and Outlook), one mailbox, replaced only on a confirmed
  /// switch, through the same `AuthScenario.session` the app launches with. Off it, every
  /// provider and a second mailbox.
  @Test func theReleaseSurfaceListsTheBuildsProviders() throws {
    for scenario in [AuthScenario.mailboxes2, .setupEmail, .outlookSignIn, .noMailbox, .outlookReconnect, .gmailLinked, nil] {
      let release = try #require(AuthScenario.session(for: scenario, releaseSurface: true).services.mailbox as? MockMailbox)
      #expect(release.connectable == [.gmail, .outlook])
      #expect(!release.capabilities.contains(.addSecond) && release.capabilities.contains(.replace))
      #expect(release.holdsOneLink && !release.sortsWithModel)
      #expect(release.mailboxes.filter { $0.state != .disconnected }.count <= 1)
      let debug = try #require(AuthScenario.session(for: scenario, releaseSurface: false).services.mailbox as? MockMailbox)
      #expect(debug.connectable == [.gmail, .outlook] && debug.capabilities == .all && !debug.holdsOneLink)
    }
  }
}
