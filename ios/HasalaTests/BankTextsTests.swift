import Foundation
import HasalaMocks
import HasalaModels
import Testing

@testable import Hasala

@MainActor
@Suite("Bank texts")
struct BankTextsTests {
  let now = Date(timeIntervalSince1970: 1_792_000_000)

  func services(texts: MockBankTexts?, mailbox: MockMailbox = MockMailbox()) -> AccountServices {
    let account = MockAccountService(existing: .passkey, signedIn: true)
    account.delay = .zero
    mailbox.connectDelay = .zero
    mailbox.step = .milliseconds(1)
    return AccountServices(
      account: account, mailbox: mailbox, setup: MockSetupAuthoring(), notifications: MockNotificationPermission(),
      bankTexts: texts)
  }

  func model(_ s: AccountServices, finished: @escaping () -> Void = {}) -> SetupModel {
    SetupModel(
      services: s, displayName: "Maya", facts: .init(hasSession: true, keysReady: true), onFinished: finished)
  }


  @Test func choosingTextsFinishesTheBankAndMailSteps() {
    var f = OnboardingStep.Facts(hasSession: true, keysReady: true)
    #expect(OnboardingStep.derive(f) == .bank)
    f.textsChosen = true
    #expect(OnboardingStep.derive(f) == .finished)
  }

  @Test func textsWithBanksChosenStillFinishWithoutAMailbox() {
    var f = OnboardingStep.Facts(hasSession: true, keysReady: true, banksChosen: true)
    #expect(OnboardingStep.derive(f) == .mail)
    f.textsChosen = true
    #expect(OnboardingStep.derive(f) == .finished)
  }

  @Test func theTextsFactIsKeptThroughAReconcile() {
    let m = model(services(texts: MockBankTexts()))
    m.finishTexts()
    m.reconcile(facts: .init(hasSession: true, keysReady: true), banks: [])
    #expect(m.facts.textsChosen && m.step == .finished)
    var relaunched = OnboardingStep.Facts(hasSession: true, keysReady: true)
    relaunched.textsChosen = true
    let other = model(services(texts: MockBankTexts(source: .texts)))
    other.reconcile(facts: relaunched, banks: [])
    #expect(other.step == .finished)
  }


  @Test func theChoiceIsOfferedOnlyWithALane() {
    #expect(model(services(texts: MockBankTexts())).asksSource)
    #expect(!model(services(texts: nil)).asksSource)
    #expect(!model(services(texts: nil)).offersBankTexts)
  }

  @Test func theReviewAccountKeepsItsSampleData() {
    let account = MockAccountService(existing: .passkey, signedIn: true)
    let s = AccountServices(
      account: account, mailbox: MockMailbox(offersSampleData: true), setup: MockSetupAuthoring(),
      notifications: MockNotificationPermission(), bankTexts: MockBankTexts())
    #expect(!model(s).offersBankTexts)
  }

  @Test func textsLeadToTheSetUpThenTheTestThenHome() async {
    let lane = MockBankTexts()
    var finished = 0
    let m = model(services(texts: lane)) { finished += 1 }
    await m.chooseSource(.texts)
    #expect(lane.source == .texts && lane.useTextsCalls == 1)
    #expect(m.path == [.textsSetUp] && m.asksSource && m.step == .bank && finished == 0)
    m.sendTestText()
    m.sendTestText()
    #expect(m.path == [.textsSetUp, .textsTest])
    m.finishTexts()
    #expect(finished == 1 && m.facts.textsChosen && m.step == .finished)
  }

  @Test func emailShowsTheBankStepAndBackReturnsToTheChoice() async {
    let lane = MockBankTexts()
    let m = model(services(texts: lane))
    await m.chooseSource(.texts)
    m.back()
    await m.chooseSource(.email)
    #expect(!m.asksSource && m.source == .email && lane.source == .email && m.path.isEmpty)
    m.backToSourceChoice()
    #expect(m.asksSource && m.source == nil)
  }

  @Test func aFailedChoiceStaysOnTheChoice() async {
    let lane = MockBankTexts()
    lane.switchFails = true
    let m = model(services(texts: lane))
    await m.chooseSource(.texts)
    #expect(m.path.isEmpty && m.failure != nil && lane.source == nil)
  }

  @Test func aConnectedMailboxSkipsTheChoice() {
    var facts = OnboardingStep.Facts(hasSession: true, keysReady: true, banksChosen: true)
    facts.mailbox = .linked
    let m = SetupModel(
      services: services(texts: MockBankTexts(), mailbox: MockMailbox(mailboxes: [MockMailbox.gmail])),
      displayName: "Maya", facts: facts, onFinished: {})
    #expect(!m.asksSource)
  }


  @Test func statusComesFromWhatWasObserved() {
    let lane = MockBankTexts()
    #expect(lane.status == .notSetUp)
    let waiting = MockBankTexts(source: .texts)
    #expect(waiting.status == .waitingForFirstText)
    let ran = now.addingTimeInterval(-240)
    let working = MockBankTexts(source: .texts, lastRan: ran)
    #expect(working.status == .working(lastRan: ran))
    #expect(BankTexts.statusLine(working.status, now: now) == "Ran 4 min ago")
    #expect(BankTexts.statusLine(waiting.status, now: now) == "Waiting for your first bank text")
  }

  @Test func relativeTimes() {
    #expect(BankTexts.ago(now, now: now) == "just now")
    #expect(BankTexts.ago(now.addingTimeInterval(-59 * 60), now: now) == "59 min ago")
    #expect(BankTexts.ago(now.addingTimeInterval(-2 * 3600), now: now) == "2 h ago")
    #expect(BankTexts.ago(now.addingTimeInterval(-3 * 86_400), now: now) == "3 days ago")
    #expect(BankTexts.ago(now.addingTimeInterval(60), now: now) == "just now")
  }

  @Test func onlyDIBIsReadAutomatically() {
    let dib = BankTextsBank(bank: .dib, lastText: now.addingTimeInterval(-7200))
    let enbd = BankTextsBank(bank: .enbd, lastText: nil)
    #expect(dib.readsAutomatically && !enbd.readsAutomatically)
    #expect(BankTexts.bankDetail(dib, now: now) == "Last text 2 h ago\nRead automatically")
    #expect(BankTexts.bankDetail(enbd, now: now) == "No text yet\nYou check each one in Review")
  }

  @Test func switchingToEmailNamesTheCutoff() async throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = BankTexts.clock
    let last = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 9)))
    let lane = MockBankTexts(source: .texts, lastRan: last, lastTexts: [.dib: last])
    #expect(BankTexts.switchToEmailMessage(cutoff: lane.lastTextAt).contains("after your last bank text (Tue 20 Oct)"))
    #expect(!BankTexts.switchToEmailMessage(cutoff: nil).contains("after your last"))
    let cutoff = try await lane.useEmail()
    #expect(cutoff == last && lane.source == .email && lane.status == .notSetUp)
  }

  @Test func switchingToTextsDisconnectsTheMailbox() async {
    let mailbox = MockMailbox(mailboxes: [MockMailbox.gmail])
    mailbox.connectDelay = .zero
    let lane = MockBankTexts(source: .email)
    #expect(await SourceSwitch.toTexts(mailbox: mailbox, texts: lane) == .switched)
    #expect(mailbox.mailboxes.allSatisfy { $0.state == .disconnected } && lane.source == .texts)
    #expect(mailbox.imported[MockMailbox.gmail.id] != nil)
  }

  @Test func aFailedSwitchSaysSo() async {
    let lane = MockBankTexts(source: .texts)
    lane.switchFails = true
    #expect(await SourceSwitch.toEmail(texts: lane) != .switched)
    #expect(lane.source == .texts)
  }

  @Test func theTestTextIsWaitedFor() async throws {
    let lane = MockBankTexts(source: .texts)
    lane.testDelay = .milliseconds(10)
    lane.startTest()
    #expect(lane.test.isWaiting)
    for _ in 0..<200 where lane.test.isWaiting { try await Task.sleep(for: .milliseconds(5)) }
    guard case .received = lane.test else {
      Issue.record("the test text was not received: \(lane.test)")
      return
    }
    lane.testOutcome = .nothing
    lane.startTest()
    for _ in 0..<200 where lane.test.isWaiting { try await Task.sleep(for: .milliseconds(5)) }
    #expect(lane.test == .nothingYet)
  }


  @Test func aPastedTextIsReadAndAddedOnce() async {
    let lane = MockBankTexts(source: .texts)
    lane.readDelay = .zero
    let m = PasteBankTextModel(lane: lane)
    #expect(!m.canAdd)
    await m.paste(MockBankTexts.sampleText)
    guard case .read(let preview)? = m.reading else {
      Issue.record("the sample was not read")
      return
    }
    #expect(preview.amount == .aed(64_00) && preview.direction == .out && preview.merchant == "Sample Grocer")
    #expect(PasteBankTextModel.amountLine(preview) == "AED 64.00 out")
    #expect(PasteBankTextModel.cardLine(preview) == "Card \u{00B7}\u{00B7}\u{00B7}0000")
    #expect(m.canAdd)
    let first = await m.add()
    let second = await m.add()
    #expect(first && second)
    #expect(lane.added.count == 1)
  }

  @Test func anUnreadableTextStillGoesToReview() async {
    let lane = MockBankTexts(source: .texts)
    lane.readDelay = .zero
    let m = PasteBankTextModel(lane: lane)
    await m.paste(MockBankTexts.unreadableText)
    #expect(m.reading == .unreadable && m.canAdd)
  }

  @Test func aTextThatIsNotAPaymentIsNotKept() async {
    let lane = MockBankTexts(source: .texts)
    lane.readDelay = .zero
    let m = PasteBankTextModel(lane: lane)
    await m.paste(MockBankTexts.codeText)
    #expect(m.reading == .notAPayment && !m.canAdd)
    let added = await m.add()
    #expect(!added)
    await m.paste("   ")
    #expect(m.text == MockBankTexts.codeText)
    #expect(lane.added.isEmpty)
  }


  @Test func textsTakeTheMailOfferAway() {
    let app = AppModel(store: InMemoryLedger(), mailbox: MockMailbox())
    #expect(app.mailOffer == .connect)
    app.bankTextsLane = MockBankTexts(source: .texts)
    #expect(app.mailOffer == nil && app.usesBankTexts)
    app.bankTextsLane = MockBankTexts(source: .email)
    #expect(app.mailOffer == .connect && !app.usesBankTexts)
  }

  @Test func finishSettingUpDoesNotAskForEmailWithTexts() {
    let m = FinishSetupModel(services: services(texts: MockBankTexts(source: .texts)))
    #expect(!m.needsEmail && !m.items.contains(.connectEmail))
    let email = FinishSetupModel(services: services(texts: MockBankTexts(source: .email)))
    #expect(email.needsEmail)
  }

  @Test func theReleaseSurfaceHasNoTextsLane() {
    #expect(AuthScenario.session(for: .textsWorking, releaseSurface: true).services.bankTexts == nil)
    #expect(AuthScenario.session(for: .setupTexts, releaseSurface: true).services.bankTexts == nil)
    #expect(AuthScenario.session(for: .textsWorking, releaseSurface: false).services.bankTexts != nil)
    #expect(AuthScenario.session(for: .setupBank, releaseSurface: false).services.bankTexts == nil)
  }

  @Test func theTextsSummary() {
    let s = MailboxesSummary.texts(.working(lastRan: now.addingTimeInterval(-240)), now: now)
    #expect(s.title == "Bank texts are working" && s.detail == "Ran 4 min ago" && !s.needsYou)
    #expect(MailboxesSummary.texts(.waitingForFirstText, now: now).detail == "Waiting for your first bank text")
  }
}
