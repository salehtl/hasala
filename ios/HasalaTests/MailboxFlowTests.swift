import Foundation
import HasalaModels
import Testing

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
    for await _ in lane.firstScan() {}
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
    let none = hero([], .notConnected, offer: .connect)
    #expect(none.kind == .notConnected && none.detail == "Add a mailbox so Hasala can read your bank alerts.")
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
    #expect(MailCopy.disconnectMessage(.outlook)
      == "Hasala stops reading this mailbox and forgets its sign-in. Past transactions stay. To remove the permission on Microsoft's side too, visit account.live.com/consent/Manage.")
    #expect(MailCopy.disconnectMessage(.gmail).hasSuffix("on Google's side too, visit myaccount.google.com/permissions."))
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

  /// On the Release surface the scenario's mock reads like the live lane: Gmail only, one
  /// mailbox (plan B4.5), through the same `AuthScenario.session` the app launches with.
  /// Off it, every provider and a second mailbox.
  @Test func theReleaseSurfaceListsGmailOnly() throws {
    for scenario in [AuthScenario.mailboxes2, .setupEmail, .outlookSignIn, .noMailbox, nil] {
      let release = try #require(AuthScenario.session(for: scenario, releaseSurface: true).services.mailbox as? MockMailbox)
      #expect(release.connectable == [.gmail] && !release.capabilities.contains(.addSecond))
      #expect(!release.sortsWithModel)
      // A scenario's Outlook mailbox can't exist where Outlook can't connect.
      #expect(release.mailboxes.allSatisfy { $0.provider == .gmail })
      let debug = try #require(AuthScenario.session(for: scenario, releaseSurface: false).services.mailbox as? MockMailbox)
      #expect(debug.connectable == [.gmail, .outlook] && debug.capabilities == .all)
    }
  }
}
