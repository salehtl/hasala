import CoreMailbox
import Foundation
import HasalaModels
import Testing

@testable import Hasala

@MainActor
@Suite("Past mail choice")
struct PastMailChoiceAppTests: AccountSuite {
  func mailbox(_ mailboxes: [MailboxSnapshot] = []) -> MockMailbox {
    let m = MockMailbox(mailboxes: mailboxes)
    m.connectDelay = .zero
    m.step = .milliseconds(1)
    return m
  }

  @Test func aNewConnectImportsThePastUnlessThePersonSaysOtherwise() async {
    for provider in [MailProviderKind.gmail, .outlook] {
      let lane = mailbox()
      let c = MailConnectCoordinator(mailbox: lane, context: .addMailbox)
      #expect(c.pastMailChoice == .importPast)
      await c.connect(provider)
      #expect(lane.pastMailChoices == [.importPast])
      #expect(lane.mailboxes.first?.state == .syncing)
      #expect(lane.mailboxes.first?.pastMailSkipped == false)
    }
  }

  @Test func onlyNewEmailReachesTheLaneForBothProviders() async {
    for provider in [MailProviderKind.gmail, .outlook] {
      let lane = mailbox()
      let c = MailConnectCoordinator(mailbox: lane, context: .addMailbox)
      c.pastMail = .newOnly
      await c.connect(provider)
      #expect(lane.pastMailChoices == [.newOnly])
      #expect(lane.mailboxes.first?.state == .connected)
      #expect(lane.mailboxes.first?.pastMailSkipped == true)
    }
  }

  @Test func aTryAgainKeepsTheChoice() async {
    let lane = mailbox()
    lane.offline = true
    let c = MailConnectCoordinator(mailbox: lane, context: .addMailbox)
    c.pastMail = .newOnly
    await c.connect(.gmail)
    lane.offline = false
    await c.retry(.gmail)
    #expect(lane.pastMailChoices == [.newOnly, .newOnly])
  }

  @Test func aTakeoverStartsOnOnlyNewEmail() {
    let held = CountingMailbox(mailbox())
    held.heldElsewhere = .gmail
    #expect(held.defaultPastMail == .newOnly)
    let c = MailConnectCoordinator(mailbox: held, context: .addMailbox)
    #expect(c.pastMailChoice == .newOnly)
    c.pastMail = .importPast
    #expect(c.pastMailChoice == .importPast)
  }

  @Test func theSetupStepsConnectCarriesTheAnswer() async {
    let lane = mailbox()
    let m = SetupModel(
      services: AccountServices(
        account: MockAccountService(existing: .passkey, signedIn: true), mailbox: lane, setup: MockSetupAuthoring(),
        notifications: MockNotificationPermission()),
      displayName: "Maya Rahman", facts: .init(hasSession: true, keysReady: true), onFinished: {})
    m.coordinator(.outlook).pastMail = .newOnly
    await m.connectMail(.outlook)
    #expect(lane.pastMailChoices == [.newOnly])
  }

  @Test func whoIsAsked() {
    let empty = MailConnectCoordinator(mailbox: mailbox(), context: .addMailbox)
    #expect(empty.asksPastMail(.gmail) && empty.asksPastMail(.outlook))

    let held = CountingMailbox(mailbox())
    held.heldElsewhere = .gmail
    #expect(!MailConnectCoordinator(mailbox: held, context: .addMailbox).asksPastMail(.gmail))

    let again = MailConnectCoordinator(mailbox: mailbox(), context: .signInAgain(mailboxID: "gmail-1"))
    #expect(!again.asksPastMail(.gmail))

    var broken = MockMailbox.outlook
    broken.state = .needsSignIn
    let reconnect = MailConnectCoordinator(mailbox: mailbox([broken]), context: .addMailbox)
    #expect(!reconnect.asksPastMail(.outlook))
    #expect(reconnect.asksPastMail(.gmail))
  }

  @Test func theFirstScanOfASkippedMailboxEndsAtOnceWithNothingRead() async {
    let lane = mailbox()
    let c = MailConnectCoordinator(mailbox: lane, context: .addMailbox)
    c.pastMail = .newOnly
    await c.connect(.gmail)
    var last: ScanProgress?
    for await p in lane.firstScan() { last = p }
    #expect(last?.phase == .finished && last?.total == 0)
    #expect(!lane.firstScanFinished)
  }

  @Test func aSkippedMailboxImportsLaterAndStopsOffering() async throws {
    let lane = mailbox()
    let c = MailConnectCoordinator(mailbox: lane, context: .addMailbox)
    c.pastMail = .newOnly
    await c.connect(.outlook)
    let id = try #require(lane.mailboxes.first?.id)
    #expect(await lane.importPastMail(id) == .finished(lane.total))
    #expect(lane.mailboxes.first?.pastMailSkipped == false)
    #expect(lane.firstScanFinished)
  }

  @Test func theLiveRowOffersTheImportOnlyWhileActive() {
    func row(_ phase: MailboxPhase, skipped: Bool) -> MailboxSnapshot? {
      LiveMailboxConnecting.mailboxes(
        phase: phase, halt: nil, address: "maya@example.com", lastSuccessAtMs: nil, bankDomains: [], nowMs: 0,
        pastMailSkipped: skipped
      ).first
    }
    #expect(row(.active, skipped: true)?.pastMailSkipped == true)
    #expect(row(.active, skipped: false)?.pastMailSkipped == false)
    #expect(row(.reconnectRequired, skipped: true)?.pastMailSkipped == false)
    #expect(row(.otherDevice, skipped: true)?.pastMailSkipped == false)
  }

  @Test func theChoiceBecomesTheEnginesPlan() {
    #expect(LiveMailboxConnecting.pastMail(.importPast, takesOver: true, newestImportMs: 5) == .read)
    #expect(LiveMailboxConnecting.pastMail(.newOnly, takesOver: false, newestImportMs: 5) == .skip(catchUpFromMs: nil))
    #expect(LiveMailboxConnecting.pastMail(.newOnly, takesOver: true, newestImportMs: 5) == .skip(catchUpFromMs: 5))
    #expect(LiveMailboxConnecting.pastMail(.newOnly, takesOver: true, newestImportMs: nil) == .skip(catchUpFromMs: nil))
  }

  @Test func theCopyNamesTheWindow() {
    #expect(MailCopy.pastMailMessage(days: 90).contains("the last 90 days"))
    #expect(MailCopy.pastMailMessage(days: 365).contains("the last year"))
    #expect(MailCopy.pastMailSkippedDetail(days: 365).contains("the year before"))
    #expect(MailCopy.pastImported(1) == "1 past transaction added.")
  }
}
