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

  @Test func theTextsFactIsKeptThroughAReconcile() async {
    let m = model(services(texts: MockBankTexts()))
    await m.finishTexts()
    m.reconcile(facts: .init(hasSession: true, keysReady: true), banks: [])
    #expect(m.facts.textsChosen && m.step == .finished)
  }

  @Test func aRelaunchMidSetupDoesNotSkipSetup() async {
    let lane = MockBankTexts()
    let before = model(services(texts: lane))
    before.chooseSource(.texts)
    await before.continueWithTextBanks()
    #expect(!lane.isSetUp && before.step == .mail)
    var finished = 0
    let relaunched = model(services(texts: lane)) { finished += 1 }
    var facts = AuthScenario.setupFacts(for: .setupTexts, texts: lane)
    facts.banksChosen = true
    relaunched.reconcile(facts: facts, banks: [.dib])
    relaunched.resume()
    #expect(!relaunched.facts.textsChosen && relaunched.step == .mail && relaunched.asksSource && finished == 0)
  }

  @Test func aRelaunchAfterFinishingTheTextsSetUpGoesHome() async {
    let lane = MockBankTexts()
    let before = model(services(texts: lane))
    before.chooseSource(.texts)
    await before.continueWithTextBanks()
    await before.finishTexts()
    #expect(lane.isSetUp && lane.finishCalls == 1)
    var finished = 0
    let relaunched = model(services(texts: lane)) { finished += 1 }
    let facts = AuthScenario.setupFacts(for: .setupTexts, texts: lane)
    #expect(facts.textsChosen)
    relaunched.reconcile(facts: facts, banks: [])
    relaunched.resume()
    #expect(relaunched.step == .finished && finished == 1)
  }

  @Test func skippingAfterBackFromTheTextsSetUpChangesNothing() {
    let lane = MockBankTexts()
    var finished = 0
    let m = model(services(texts: lane)) { finished += 1 }
    m.chooseSource(.texts)
    m.navigationPath = []
    #expect(m.asksSource && !lane.usesTexts)
    m.skipSource()
    #expect(!lane.usesTexts && lane.finishCalls == 0 && finished == 1 && m.facts.bankSkipped && !m.facts.textsChosen)
  }

  @Test func skippingTheBanksLeavesSetUp() {
    var finished = 0
    let lane = MockBankTexts()
    let m = model(services(texts: lane)) { finished += 1 }
    m.chooseSource(.texts)
    m.skipSource()
    #expect(finished == 1 && m.facts.bankSkipped && !lane.isSetUp)
  }

  @Test func aFinishThatCannotBeSavedStaysOnTheStep() async {
    let lane = MockBankTexts()
    lane.finishFails = true
    var finished = 0
    let m = model(services(texts: lane)) { finished += 1 }
    m.chooseSource(.texts)
    await m.continueWithTextBanks()
    await m.finishTexts()
    #expect(!lane.isSetUp && finished == 0 && m.failure != nil && !m.facts.textsChosen && m.path == [.textsBanks, .textsSetUp])
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

  @Test func textsLeadToTheBanksThenTheSetUpThenTheTestThenHome() async {
    let lane = MockBankTexts()
    let setup = MockSetupAuthoring()
    let s = AccountServices(
      account: MockAccountService(existing: .passkey, signedIn: true), mailbox: MockMailbox(), setup: setup,
      notifications: MockNotificationPermission(), bankTexts: lane)
    var finished = 0
    let m = model(s) { finished += 1 }
    m.chooseSource(.texts)
    #expect(m.path == [.textsBanks] && m.asksSource && m.step == .bank && finished == 0 && !lane.isSetUp)
    m.toggle(.adib)
    await m.continueWithTextBanks()
    #expect(m.path == [.textsBanks, .textsSetUp] && setup.banks == [.enbd, .dib] && m.facts.banksChosen)
    m.sendTestText()
    m.sendTestText()
    #expect(m.path == [.textsBanks, .textsSetUp, .textsTest] && lane.testsStarted == 1 && lane.test.isWaiting)
    await m.finishTexts()
    #expect(finished == 1 && m.facts.textsChosen && m.step == .finished && lane.isSetUp && lane.usesTexts)
  }

  @Test func noBankPickedDoesNotGoOn() async {
    let m = model(services(texts: MockBankTexts()))
    m.chooseSource(.texts)
    for bank in SupportedBank.allCases { m.toggle(bank) }
    await m.continueWithTextBanks()
    #expect(m.path == [.textsBanks] && !m.facts.banksChosen)
  }

  @Test func theAutomationStepCanBeSkipped() async {
    let lane = MockBankTexts()
    var finished = 0
    let m = model(services(texts: lane)) { finished += 1 }
    m.chooseSource(.texts)
    await m.continueWithTextBanks()
    await m.finishTexts()
    #expect(finished == 1 && lane.testsStarted == 0 && lane.isSetUp)
  }

  @Test func theTextsBanksSayHowEachIsRead() {
    #expect(TextsBanksStep.note(.dib) == "Read automatically")
    #expect(TextsBanksStep.note(.enbd) == "You check each one in Review")
  }

  @Test func emailShowsTheBankStepAndBackReturnsToTheChoice() {
    let lane = MockBankTexts()
    let m = model(services(texts: lane))
    m.chooseSource(.texts)
    m.back()
    m.chooseSource(.email)
    #expect(!m.asksSource && m.source == .email && lane.source == nil && m.path.isEmpty && lane.finishCalls == 0)
    m.backToSourceChoice()
    #expect(m.asksSource && m.source == nil)
  }

  @Test func aConnectedMailboxSkipsTheChoice() {
    var facts = OnboardingStep.Facts(hasSession: true, keysReady: true, banksChosen: true)
    facts.mailbox = .linked
    let m = SetupModel(
      services: services(texts: MockBankTexts(), mailbox: MockMailbox(mailboxes: [MockMailbox.gmail])),
      displayName: "Maya", facts: facts, onFinished: {})
    #expect(!m.asksSource)
  }

  @Test func theSourceFollowsTheMailboxLink() {
    let mailbox = MockMailbox(mailboxes: [MockMailbox.gmail])
    let lane = MockBankTexts(setUp: true, mailbox: mailbox)
    #expect(lane.link == .linked && lane.source == .email && !lane.usesTexts && lane.status == .notSetUp)
    #expect(MockBankTexts(setUp: true, link: .unknown).usesTexts)
    #expect(MockBankTexts(setUp: false, link: .notLinked).source == nil)
    #expect(MockBankTexts(setUp: true, link: .notLinked).source == .texts)
  }

  @Test func statusComesFromWhatWasObserved() {
    let lane = MockBankTexts()
    #expect(lane.status == .notSetUp)
    let waiting = MockBankTexts(setUp: true)
    #expect(waiting.status == .waitingForFirstText)
    let ran = now.addingTimeInterval(-240)
    let working = MockBankTexts(setUp: true, lastRan: ran)
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
    #expect(BankTexts.ago(now.addingTimeInterval(-240), now: now) == RelativeTime.ago(ms: 240_000))
  }

  @Test func onlyDIBIsReadAutomatically() {
    let dib = BankTextsBank(bank: .dib, lastText: now.addingTimeInterval(-7200))
    let enbd = BankTextsBank(bank: .enbd, lastText: nil)
    #expect(dib.readsAutomatically && !enbd.readsAutomatically)
    #expect(BankTexts.bankDetail(dib, now: now) == "Last text 2 h ago\nRead automatically")
    #expect(BankTexts.bankDetail(enbd, now: now) == "No text yet\nYou check each one in Review")
  }

  @Test func sendingTheTestAgainStartsANewTest() async throws {
    let lane = MockBankTexts()
    lane.testOutcome = .nothing
    lane.testDelay = .zero
    let m = model(services(texts: lane))
    m.chooseSource(.texts)
    await m.continueWithTextBanks()
    m.sendTestText()
    for _ in 0..<200 where lane.test.isWaiting { try await Task.sleep(for: .milliseconds(5)) }
    #expect(lane.test == .nothingYet)
    m.navigationPath = [.textsBanks, .textsSetUp]
    lane.testDelay = .seconds(60)
    m.sendTestText()
    #expect(lane.testsStarted == 2 && lane.test.isWaiting && m.path == [.textsBanks, .textsSetUp, .textsTest])
  }

  @Test func theWorksLineDoesNotPromiseEveryTextFiles() {
    #expect(BankTextsTestScreen.worksLine.contains("filed or to Review"))
    #expect(!BankTextsTestScreen.worksLine.contains("adds a payment"))
  }

  @Test func switchingToEmailCompletesOnlyWhenAMailboxConnects() async throws {
    let message = BankTexts.switchToEmailMessage
    #expect(message.contains("Once it connects") && message.contains("all the bank mail it finds") && message.contains("waits in Review"))
    #expect(!message.contains("only payments after") && !message.contains("nothing counts twice"))
    #expect(!BankTexts.oneSourceNote.contains("no payment counts twice"))
    let mailbox = MockMailbox()
    mailbox.connectDelay = .zero
    let last = now.addingTimeInterval(-3600)
    let lane = MockBankTexts(setUp: true, mailbox: mailbox, lastRan: last, lastTexts: [.dib: last])
    #expect(lane.usesTexts)
    _ = try await mailbox.connect(.gmail, replacing: false, removingOld: false) { _ in .keep }
    #expect(lane.source == .email && lane.status == .notSetUp && lane.readsEmail)
    #expect(UseBankTextsSection.footnote(mailbox, lane: lane).hasPrefix(BankTexts.readsEmailNow))
    #expect(!UseBankTextsSection.footnote(mailbox, lane: MockBankTexts(mailbox: mailbox)).contains(BankTexts.readsEmailNow))
  }

  @Test func thePrivacyLineSaysPaymentShapedTextsFromAnySenderAreKept() {
    for line in [BankTexts.keepsPayments, BankTexts.keepsPaymentShapedTexts] {
      #expect(line.contains("from any sender") && line.contains("Review") && line.contains("dropped at once"))
      #expect(!line.contains("only your banks"))
    }
  }

  @Test func switchingToTextsDisconnectsTheMailboxFirst() async {
    let mailbox = MockMailbox(mailboxes: [MockMailbox.gmail])
    mailbox.connectDelay = .zero
    let lane = MockBankTexts(mailbox: mailbox)
    #expect(lane.source == .email)
    #expect(await SourceSwitch.toTexts(mailbox: mailbox, texts: lane) == .switched)
    #expect(mailbox.mailboxes.allSatisfy { $0.state == .disconnected } && lane.source == .texts)
    #expect(mailbox.imported[MockMailbox.gmail.id] != nil)
  }

  @Test func aMailboxReadOnAnotherIPhoneIsNotDisconnectedFromHere() async {
    var elsewhere = MockMailbox.gmail
    elsewhere.readElsewhere = true
    let mailbox = MockMailbox(mailboxes: [elsewhere])
    mailbox.connectDelay = .zero
    let lane = MockBankTexts(mailbox: mailbox)
    let blocker = SourceSwitch.textsBlocker(mailbox)
    #expect(blocker?.contains("Your other iPhone reads \(elsewhere.address)") == true)
    #expect(blocker?.contains(MailCopy.consentPage(.gmail)) == true)
    #expect(UseBankTextsSection.footnote(mailbox, lane: lane) == blocker)
    #expect(await SourceSwitch.toTexts(mailbox: mailbox, texts: lane) == .failed(blocker ?? ""))
    #expect(mailbox.mailboxes.allSatisfy { $0.state != .disconnected } && lane.source == .email && lane.finishCalls == 0)
  }

  @Test func aLaneThatCannotDisconnectDoesNotSwitch() async {
    let mailbox = MockMailbox(mailboxes: [MockMailbox.gmail])
    mailbox.connectDelay = .zero
    mailbox.capabilities.remove(.disconnect)
    let lane = MockBankTexts(mailbox: mailbox)
    #expect(SourceSwitch.textsBlocker(mailbox) != nil)
    guard case .failed = await SourceSwitch.toTexts(mailbox: mailbox, texts: lane) else {
      Issue.record("the switch went ahead")
      return
    }
    #expect(mailbox.mailboxes.allSatisfy { $0.state != .disconnected } && lane.source == .email)
  }

  @Test func aFailedDisconnectLeavesTheLaneOnEmail() async {
    let mailbox = MockMailbox(mailboxes: [MockMailbox.gmail])
    mailbox.connectDelay = .zero
    mailbox.disconnectFails = true
    let lane = MockBankTexts(mailbox: mailbox)
    guard case .failed(let line) = await SourceSwitch.toTexts(mailbox: mailbox, texts: lane) else {
      Issue.record("the switch went ahead")
      return
    }
    #expect(line.contains("Nothing changed"))
    #expect(mailbox.mailboxes.allSatisfy { $0.state != .disconnected } && lane.source == .email && lane.finishCalls == 0)
  }

  @Test func aSecondMailboxThatFailsToDisconnectSaysWhatIsOffAndARetryFinishes() async {
    let mailbox = MockMailbox(mailboxes: [MockMailbox.gmail, MockMailbox.outlook])
    mailbox.connectDelay = .zero
    mailbox.disconnectFailsFor = [MockMailbox.outlook.id]
    let lane = MockBankTexts(mailbox: mailbox)
    guard case .failed(let line) = await SourceSwitch.toTexts(mailbox: mailbox, texts: lane) else {
      Issue.record("the switch went ahead")
      return
    }
    #expect(line.contains("disconnected \(MockMailbox.gmail.address)") && line.contains("couldn't disconnect \(MockMailbox.outlook.address)"))
    #expect(line.contains("still reads bank email"))
    #expect(lane.source == .email && lane.finishCalls == 0 && SourceSwitch.reading(mailbox).map(\.id) == [MockMailbox.outlook.id])
    mailbox.disconnectFailsFor = []
    #expect(await SourceSwitch.toTexts(mailbox: mailbox, texts: lane) == .switched)
    #expect(SourceSwitch.reading(mailbox).isEmpty && lane.source == .texts)
  }

  @Test func aSwitchThatCannotBeSavedAfterTheDisconnectSaysSo() async {
    let mailbox = MockMailbox(mailboxes: [MockMailbox.gmail])
    mailbox.connectDelay = .zero
    let lane = MockBankTexts(mailbox: mailbox)
    lane.finishFails = true
    guard case .failed = await SourceSwitch.toTexts(mailbox: mailbox, texts: lane) else {
      Issue.record("the switch went ahead")
      return
    }
    #expect(lane.source == nil && !lane.readsEmail)
  }

  @Test func theTestTextIsWaitedFor() async throws {
    let lane = MockBankTexts(setUp: true)
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


  @Test func eachPastedTextGoesToReview() async {
    let lane = MockBankTexts(setUp: true)
    lane.readDelay = .zero
    let m = PasteBankTextModel(lane: lane)
    #expect(!m.canAdd && m.addTitle == "Add to Review")
    await m.paste(MockBankTexts.sampleText)
    guard case .read(let preview)? = m.reading else {
      Issue.record("the sample was not read")
      return
    }
    #expect(preview.amount == .aed(64_00) && preview.direction == .out && preview.merchant == "Sample Grocer")
    #expect(preview.date != nil && m.match == nil)
    #expect(PasteBankTextModel.amountLine(preview) == "AED 64.00 out")
    #expect(PasteBankTextModel.cardLine(preview) == "Card \u{00B7}\u{00B7}\u{00B7}0000")
    #expect(m.canAdd)
    let first = await m.add()
    let second = await m.add()
    #expect(first && second)
    #expect(lane.added.count == 2 && lane.replaced.isEmpty)
  }

  @Test func anUndatedTextSaysItIsDatedWhenPasted() async {
    let lane = MockBankTexts(setUp: true)
    lane.readDelay = .zero
    let m = PasteBankTextModel(lane: lane)
    await m.paste(MockBankTexts.undatedText)
    guard case .read(let preview)? = m.reading else {
      Issue.record("the refund was not read")
      return
    }
    #expect(preview.date == nil && preview.direction == .incoming)
    #expect(PasteBankTextModel.undatedNote.contains("when you paste it") && PasteBankTextModel.undatedNote.contains("Review"))
  }

  @Test func aPasteThatMatchesARowAsksFirst() async {
    let lane = MockBankTexts(setUp: true)
    lane.readDelay = .zero
    let row = BankTextMatch(
      rowID: "row-1", kind: .payment, merchant: "Sample Grocer", amount: .aed(64_00), postedAt: now, fromText: false)
    lane.nextMatch = row
    let m = PasteBankTextModel(lane: lane)
    await m.paste(MockBankTexts.sampleText)
    #expect(m.match == row && m.addTitle == "Add anyway" && m.canAdd)
    #expect(PasteBankTextModel.matchDetail(row).hasPrefix("AED 64.00") && PasteBankTextModel.matchDetail(row).hasSuffix("From email"))
    #expect(PasteBankTextModel.matchQuestion(row).contains("already in Hasala"))
    #expect(await m.add())
    #expect(lane.added.count == 1 && lane.replaced.isEmpty)
  }

  @Test func aPasteThatMatchesAnUnreadTextCanReplaceIt() async {
    let lane = MockBankTexts(setUp: true)
    lane.readDelay = .zero
    let unread = BankTextMatch(rowID: "row-2", kind: .unreadText, merchant: nil, amount: nil, postedAt: now, fromText: true)
    lane.nextMatch = unread
    let m = PasteBankTextModel(lane: lane)
    await m.paste(MockBankTexts.sampleText)
    #expect(m.addTitle == "Replace it" && PasteBankTextModel.matchTitle(unread) == "A bank text Hasala couldn't read")
    #expect(await m.add(replacing: true))
    #expect(lane.replaced == ["row-2"])
    #expect(await m.add(replacing: false))
    #expect(lane.replaced == ["row-2"] && lane.added.count == 2)
  }

  @Test func aCodeTextIsNotCheckedForAMatch() async {
    let lane = MockBankTexts(setUp: true)
    lane.readDelay = .zero
    lane.nextMatch = BankTextMatch(rowID: "row-3", kind: .payment, merchant: nil, amount: nil, postedAt: now, fromText: true)
    let m = PasteBankTextModel(lane: lane)
    await m.paste(MockBankTexts.codeText)
    #expect(m.match == nil)
  }

  @Test func anEmailAccountRefusesAPaste() async {
    let lane = MockBankTexts(setUp: true, link: .linked)
    lane.readDelay = .zero
    let m = PasteBankTextModel(lane: lane)
    #expect(m.refused)
    await m.paste(MockBankTexts.sampleText)
    #expect(m.text == nil && !m.canAdd)
    #expect(BankTexts.pasteRefused.contains("reads bank email"))
    await #expect(throws: BankTextsFailure.failed(BankTexts.pasteRefused)) {
      try await lane.addToReview(MockBankTexts.sampleText, replacing: nil)
    }
  }

  @Test func theGateDropsOnlyCodesAndDeclinesWithNoTransactionClause() {
    #expect(MockBankTexts.reading(MockBankTexts.codeText) == .notAPayment)
    #expect(MockBankTexts.reading("Your OTP is 000000 for a payment at Sample Shop.") == .notAPayment)
    #expect(MockBankTexts.reading("Purchase of AED 20.00 at Sample Shop was declined.") == .notAPayment)
    let barcode = "AED 12.00 spent on card ending 0000 at Barcode Cafe on 19/10 18:30."
    guard case .read(let cafe) = MockBankTexts.reading(barcode) else {
      Issue.record("a cafe payment was dropped")
      return
    }
    #expect(cafe.merchant == "Barcode Cafe")
    let withCodeLine = "AED 50.00 debited from card ending 0000 at Sample Shop on 19/10 18:30. Never share your OTP."
    guard case .read = MockBankTexts.reading(withCodeLine) else {
      Issue.record("a payment with a code line was dropped")
      return
    }
    #expect(MockBankTexts.reading("Your code for AED 10.00 at Sample Shop: never share your otp") == .notAPayment)
  }

  @Test func anUnreadableTextStillGoesToReview() async {
    let lane = MockBankTexts(setUp: true)
    lane.readDelay = .zero
    let m = PasteBankTextModel(lane: lane)
    await m.paste(MockBankTexts.unreadableText)
    #expect(m.reading == .unreadable && m.canAdd)
  }

  @Test func aTextThatIsNotAPaymentIsNotKept() async {
    let lane = MockBankTexts(setUp: true)
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
    #expect(AppModel(store: InMemoryLedger(), mailbox: MockMailbox()).mailOffer == .connect)
    let texts = AppModel(store: InMemoryLedger(), mailbox: MockMailbox(), services: services(texts: MockBankTexts(setUp: true)))
    #expect(texts.mailOffer == nil && texts.usesBankTexts)
    let email = AppModel(store: InMemoryLedger(), mailbox: MockMailbox(), services: services(texts: MockBankTexts(setUp: false, link: .linked)))
    #expect(email.mailOffer == .connect && !email.usesBankTexts)
  }

  @Test func finishSettingUpDoesNotAskForEmailWithTexts() {
    let m = FinishSetupModel(services: services(texts: MockBankTexts(setUp: true)))
    #expect(!m.needsEmail && !m.items.contains(.connectEmail))
    let email = FinishSetupModel(services: services(texts: MockBankTexts()))
    #expect(email.needsEmail && email.items.contains(.connectEmail))
  }

  @Test func aSwitchToTextsTakesAListedConnectEmailAway() async {
    let mailbox = MockMailbox()
    let lane = MockBankTexts(mailbox: mailbox)
    let m = FinishSetupModel(services: services(texts: lane, mailbox: mailbox))
    #expect(m.items.contains(.connectEmail) && !m.isDone(.connectEmail))
    #expect(await SourceSwitch.toTexts(mailbox: mailbox, texts: lane) == .switched)
    m.refresh()
    #expect(!m.items.contains(.connectEmail))
  }

  @Test func theAppAndSetupReadOneLane() {
    let s = AuthScenario.session(for: .textsWorking, releaseSurface: false).services
    let app = AppModel(store: InMemoryLedger(), mailbox: s.mailbox, services: s)
    let lane = s.bankTexts
    #expect(lane != nil && app.bankTexts === lane && model(s).bankTexts === lane)
    #expect(AuthScenario.session(for: .textsWorking, releaseSurface: true).services.bankTexts != nil)
    #expect(AuthScenario.session(for: .setupBank, releaseSurface: false).services.bankTexts == nil)
  }

  @Test func theTextsSummary() {
    let s = MailboxesSummary.texts(.working(lastRan: now.addingTimeInterval(-240)), now: now)
    #expect(s.title == "Bank texts are working" && s.detail == "Ran 4 min ago" && !s.needsYou)
    #expect(MailboxesSummary.texts(.waitingForFirstText, now: now).detail == "Waiting for your first bank text")
  }
}
