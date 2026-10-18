import CoreMailbox
import Foundation
import HasalaModels
import Testing

@testable import Hasala

@MainActor
@Suite("Mailbox disconnect: keep or remove")
struct MailboxDisconnectChoiceTests {
  func mailbox(_ mailboxes: [MailboxSnapshot]) -> MockMailbox {
    let m = MockMailbox(mailboxes: mailboxes)
    m.connectDelay = .zero
    return m
  }

  @Test func theImpactCountsTheMailboxsTransactions() async {
    let lane = mailbox([MockMailbox.gmail])
    #expect(await lane.disconnectImpact("gmail-1") == MailboxDisconnectImpact(transactions: 42, edited: 3))
    lane.imported["gmail-1"] = MailboxDisconnectImpact(transactions: 0, edited: 0)
    #expect(await lane.disconnectImpact("gmail-1") == nil)
  }

  @Test func keepLeavesTheTransactionsAndRemoveTakesThem() async throws {
    let lane = mailbox([MockMailbox.gmail, MockMailbox.outlook])
    try await lane.disconnect("outlook-1", removeTransactions: false)
    #expect(lane.removed.isEmpty && lane.mailboxes.last?.state == .disconnected)
    try await lane.disconnect("gmail-1", removeTransactions: true)
    #expect(lane.removed == ["gmail-1"])
    #expect(await lane.disconnectImpact("gmail-1") == nil)
    try await lane.disconnect("gmail-1")
    #expect(lane.removed == ["gmail-1"])
  }

  @Test func theCopyIsPlainAndCountsRight() {
    let many = MailboxDisconnectImpact(transactions: 42, edited: 3)
    let one = MailboxDisconnectImpact(transactions: 1, edited: 1)
    #expect(MailCopy.keepTransactions(many) == "Keep the 42 transactions from this inbox")
    #expect(MailCopy.keepTransactions(one) == "Keep the 1 transaction from this inbox")
    #expect(MailCopy.disconnectChoiceMessage(.gmail, many)
      == "Hasala stops reading this mailbox, ends its access at Google and deletes its sign-in from this iPhone. It brought in 42 transactions. Keep them, or remove them from your totals. Removing also takes the 3 you changed. To check on Google's side, visit myaccount.google.com/permissions.")
    #expect(MailCopy.disconnectChoiceMessage(.outlook, MailboxDisconnectImpact(transactions: 12, edited: 0))
      == "Hasala stops reading this mailbox and forgets its sign-in. It brought in 12 transactions. Keep them, or remove them from your totals. To remove the permission on Microsoft's side too, visit account.live.com/consent/Manage.")
    #expect(MailCopy.disconnectChoiceMessage(.outlook, one).contains("It brought in 1 transaction. Keep them") )
    #expect(MailCopy.disconnectChoiceMessage(.outlook, one).contains("Removing also takes the 1 you changed."))
    #expect(MailCopy.disconnected(.gmail, removed: nil) == "Gmail disconnected. Past transactions stay.")
    #expect(MailCopy.disconnected(.gmail, removed: 42) == "Gmail disconnected. 42 transactions removed.")
    #expect(MailCopy.disconnected(.outlook, removed: 1) == "Outlook disconnected. 1 transaction removed.")
  }

  @Test func theLiveOutcomeBecomesAFailureOnlyWhenSomethingDidNotHappen() throws {
    try LiveMailboxConnecting.disconnected(.disconnected, provider: .gmail)
    try LiveMailboxConnecting.disconnected(.removed(4), provider: .gmail)
    #expect(throws: MailConnectFailure.failed("Couldn't disconnect Gmail. Try again.")) {
      try LiveMailboxConnecting.disconnected(.failed, provider: .gmail)
    }
    #expect(throws: MailConnectFailure.failed("Outlook is disconnected, but its transactions couldn't be removed. They stay for now.")) {
      try LiveMailboxConnecting.disconnected(.disconnectedRemoveFailed, provider: .outlook)
    }
  }
}
