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
      let debug = try #require(AuthScenario.session(for: scenario, releaseSurface: false).services.mailbox as? MockMailbox)
      #expect(debug.connectable == [.gmail, .outlook] && debug.capabilities == .all)
    }
  }
}
