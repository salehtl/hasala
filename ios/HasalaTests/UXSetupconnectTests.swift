import Foundation
import HasalaMocks
import HasalaModels
import Testing

@testable import Hasala

@MainActor
@Suite("Setup connect and mailbox screens")
struct UXSetupconnectTests {
  func services(texts: MockBankTexts? = nil, mailbox: MockMailbox = MockMailbox()) -> AccountServices {
    let account = MockAccountService(existing: .passkey, signedIn: true)
    account.delay = .zero
    mailbox.connectDelay = .zero
    mailbox.step = .milliseconds(1)
    return AccountServices(
      account: account, mailbox: mailbox, setup: MockSetupAuthoring(), notifications: MockNotificationPermission(),
      bankTexts: texts)
  }

  func model(_ s: AccountServices) -> SetupModel {
    SetupModel(services: s, displayName: "Maya", facts: .init(hasSession: true, keysReady: true), onFinished: {})
  }

  @Test func aMissingPermissionHasItsOwnScreen() async throws {
    let s = services()
    let lane = try #require(s.mailbox as? MockMailbox)
    lane.gmailPermissionMissing = true
    let m = model(s)
    await m.continueWithBanks()
    #expect(m.path == [.connectError(.gmail)])
    #expect(SetupModel.showsErrorScreen(.permissionMissing(.gmail)))
    #expect(SetupModel.showsErrorScreen(.permissionMissing(.outlook)))
    let copy = MailConnectErrorView.copy(.permissionMissing(.gmail), .gmail)
    #expect(copy.title == "Gmail isn't connected.")
    #expect(copy.subtitle == "Hasala can't see your alerts without read access. Nothing was connected and nothing was read.")
    #expect(copy.reasons?.title == "What to do" && copy.reasons?.numbered == true)
    #expect(copy.reasons?.items.count == 1)
    #expect(copy.reasons?.items.first?.title == "Tick \u{201C}View your email messages and settings\u{201D}")
    #expect(copy.reasons?.items.first?.detail == "It's on Google's screen.")
    let outlook = MailConnectErrorView.copy(.permissionMissing(.outlook), .outlook)
    #expect(outlook.title == "Outlook isn't connected.")
    #expect(outlook.reasons?.items.first?.title == "Allow \u{201C}Read your mail\u{201D}")
    #expect(outlook.reasons?.items.first?.detail == "It's on Microsoft's screen.")
  }

  @Test func errorScreensOfferBankTextsInSetup() async throws {
    #expect(MailConnectErrorView.textsLead == "Only get texts from your bank?")
    #expect(MailConnectErrorView.textsLink == "Use bank texts instead")
    let mailbox = MockMailbox()
    mailbox.gmailPermissionMissing = true
    let m = model(services(texts: MockBankTexts(), mailbox: mailbox))
    m.chooseSource(.email)
    await m.continueWithBanks()
    #expect(m.path == [.connectError(.gmail)] && m.offersBankTexts)
    m.useBankTextsInstead()
    #expect(m.path.isEmpty && m.asksSource && m.source == nil && m.failure == nil)
    let noTexts = model(services())
    noTexts.useBankTextsInstead()
    #expect(!noTexts.offersBankTexts && !noTexts.asksSource)
  }

  @Test func bankNotListedPointsToTextsWhereTheyAreOffered() {
    #expect(AnotherBankCard.line(sent: false, sample: false, texts: true) == "Bank texts work with any bank.")
    #expect(AnotherBankCard.line(sent: false, sample: false, texts: false)
      == "Tell us yours. Meanwhile, Skip lets you add spending by hand.")
    #expect(AnotherBankCard.line(sent: false, sample: true, texts: false)
      == "Tell us, and look around with sample data meanwhile.")
    #expect(AnotherBankCard.line(sent: true, sample: false, texts: true) == "Thanks. We'll email you when it's ready.")
  }

  @Test func googleBriefingExplainsTheWidePermission() {
    #expect(GoogleBriefingCard.tickLine
      == "Tick \u{201C}View your email messages and settings\u{201D}. Google has no permission for bank alerts alone. Hasala asks Gmail only for mail from your banks\u{2019} alert addresses, and downloads only that.")
    #expect(!GoogleBriefingCard.tickLine.contains("narrower"))
  }

  @Test func useOutlookSwapsInPlace() async throws {
    let s = services()
    let lane = try #require(s.mailbox as? MockMailbox)
    let m = model(s)
    #expect(m.provider == .gmail)
    m.swapProvider(.outlook)
    #expect(m.provider == .outlook && !m.choosingEmail && m.connectRequest == nil && lane.connectCalls == 0)
    m.swapProvider(.gmail)
    #expect(m.provider == .gmail && lane.connectCalls == 0)
  }

  @Test func otherEmailServiceLinkSaysItLeavesTheApp() {
    #expect(TellUsWhichLink.label == "Use another email service? Email us.")
    #expect(TellUsWhichLink.lead + " " + TellUsWhichLink.link == TellUsWhichLink.label)
    #expect(TellUsWhichLink.mail.scheme == "mailto")
  }

  @Test func reasonsAreNumberedOnlyForSteps() {
    #expect(MailConnectErrorView.copy(.cancelled, .outlook).reasons?.numbered == false)
    #expect(MailConnectErrorView.copy(.permissionMissing(.gmail), .gmail).reasons?.numbered == true)
  }

  @Test func mailboxesFootnoteHasNoJargon() {
    let note = MailCopy.mailboxesFootnote
    #expect(note.contains("keeps only a code for each mailbox, made with a secret key"))
    #expect(!note.lowercased().contains("hash"))
    #expect(note.hasPrefix("Read on this iPhone, read-only. Only alerts from your banks are downloaded."))
  }

  @Test func keepRowNamesTheCount() {
    #expect(MailCopy.keepTransactions(MailboxDisconnectImpact(transactions: 12, edited: 0)) == "Keep the 12 transactions")
    #expect(MailCopy.keepTransactions(MailboxDisconnectImpact(transactions: 1, edited: 0)) == "Keep the 1 transaction")
    #expect(!MailCopy.keepTransactions(MailboxDisconnectImpact(transactions: 3, edited: 0)).contains("inbox"))
  }

  @Test func disconnectPageKeepsByDefault() {
    #expect(MailboxDisconnectChoice.initial == .keep)
    #expect(!MailboxDisconnectChoice.keep.removesTransactions)
    #expect(MailboxDisconnectChoice.remove.removesTransactions)
    #expect(MailboxDisconnectPage.title == "Disconnect this mailbox")
  }

  @Test func disconnectPageLinksToTheProvidersPermissions() {
    #expect(MailCopy.permissionsTitle(.gmail) == "Check Google's permissions")
    #expect(MailCopy.permissionsTitle(.outlook) == "Remove the permission at Microsoft")
    #expect(MailCopy.consentURL(.gmail).absoluteString == "https://myaccount.google.com/permissions")
    #expect(MailCopy.consentURL(.outlook).absoluteString == "https://account.live.com/consent/Manage")
    #expect(MailCopy.disconnectPlainMessage == "Hasala stops reading this mailbox and deletes its sign-in from this iPhone.")
  }

  @Test func yourBanksRowSaysHowManyArePicked() {
    #expect(SetupModel.banksSummary(3) == "3 picked")
    #expect(SetupModel.banksSummary(1) == "1 picked")
    #expect(SetupModel.banksSummary(0) == "None picked")
    #expect(YourBanksSheet.lead == "Only alerts from the banks you pick are downloaded.")
  }

  @Test func emptyBankPickStillBlocksTheConnect() async {
    let m = model(services())
    for bank in SupportedBank.allCases { m.toggle(bank) }
    #expect(m.chosenBanks.isEmpty)
    #expect(await m.saveBanks() == false)
  }

  @Test func offlineLinesFollowOnePattern() {
    #expect(SetupFailure.offline.message == "You're offline. Finish setup when you're back online.")
    #expect(RequestBankSheet.offlineNote == "You're offline. Check again when you're back online.")
    #expect(BankAlertsPage.unreadableLine(1) == "1 email Hasala couldn't read")
    #expect(BankAlertsPage.unreadableLine(3) == "3 emails Hasala couldn't read")
  }

  @Test func needsALookOpensWhereTheMailCanBeSorted() {
    #expect(BankAlertsPage.unreadableTarget(listed: true) == .bankEmails)
    #expect(BankAlertsPage.unreadableTarget(listed: false) == .addTransaction)
    #expect(BankAlertsPage.UnreadableTarget.bankEmails.detail == "Add each one by hand or dismiss it")
    #expect(BankAlertsPage.UnreadableTarget.addTransaction.detail == ReviewTabView.unreadableDetail)
  }
}
