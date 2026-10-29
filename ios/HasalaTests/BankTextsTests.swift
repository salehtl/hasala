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
    #expect(!lane.isSetUp && before.step == .bank && before.path == [.textsSetUp])
    var finished = 0
    let relaunched = model(services(texts: lane)) { finished += 1 }
    let facts = AuthScenario.setupFacts(for: .setupTexts, texts: lane)
    relaunched.reconcile(facts: facts, banks: [])
    relaunched.resume()
    #expect(!relaunched.facts.textsChosen && relaunched.step == .bank && relaunched.asksSource && finished == 0)
  }

  @Test func aRelaunchAfterFinishingTheTextsSetUpGoesHome() async {
    let lane = MockBankTexts()
    let before = model(services(texts: lane))
    before.chooseSource(.texts)
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

  @Test func skippingTheSourceChoiceLeavesSetUp() {
    var finished = 0
    let lane = MockBankTexts()
    let m = model(services(texts: lane)) { finished += 1 }
    #expect(m.asksSource && m.path.isEmpty)
    m.skipSource()
    #expect(finished == 1 && m.facts.bankSkipped && !lane.isSetUp && !m.facts.textsChosen && lane.finishCalls == 0)
  }

  @Test func aFinishThatCannotBeSavedStaysOnTheStep() async {
    let lane = MockBankTexts()
    lane.finishFails = true
    var finished = 0
    let m = model(services(texts: lane)) { finished += 1 }
    m.chooseSource(.texts)
    await m.finishTexts()
    #expect(!lane.isSetUp && finished == 0 && m.failure != nil && !m.facts.textsChosen && m.path == [.textsSetUp])
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

  @Test func textsLeadToTheSetUpThenTheTestThenHomeWithNoBankList() async {
    let lane = MockBankTexts()
    let setup = MockSetupAuthoring()
    let s = AccountServices(
      account: MockAccountService(existing: .passkey, signedIn: true), mailbox: MockMailbox(), setup: setup,
      notifications: MockNotificationPermission(), bankTexts: lane)
    var finished = 0
    let m = model(s) { finished += 1 }
    m.chooseSource(.texts)
    #expect(m.path == [.textsSetUp] && m.asksSource && m.step == .bank && finished == 0 && !lane.isSetUp)
    m.sendTestText()
    m.sendTestText()
    #expect(m.path == [.textsSetUp, .textsTest] && lane.testsStarted == 1 && lane.test.isWaiting)
    await m.finishTexts()
    #expect(finished == 1 && m.facts.textsChosen && m.step == .finished && lane.isSetUp && lane.usesTexts)
    #expect(setup.banks.isEmpty && !m.facts.banksChosen)
  }

  @Test func theAutomationStepCanBeSkipped() async {
    let lane = MockBankTexts()
    var finished = 0
    let m = model(services(texts: lane)) { finished += 1 }
    m.chooseSource(.texts)
    await m.finishTexts()
    #expect(finished == 1 && lane.testsStarted == 0 && lane.isSetUp)
  }

  @Test func theTextsCopyNamesNoBank() {
    #expect(BankTexts.anyBankLine.contains("from any bank") && BankTexts.anyBankLine.contains("waits in Review"))
    #expect(!BankTexts.anyBankLine.lowercased().contains("automatically"))
    let lines = [
      BankTexts.anyBankLine, BankTexts.keepsPayments, BankTexts.keepsPaymentShapedTexts, BankTexts.keepsNoText,
      BankTexts.setAsideFootnote, BankTextsTestScreen.worksLine,
    ] + BankTextsGuide.shortSteps + BankTextsGuide.fullSteps + BankTextsGuide.checklist.map(\.detail)
    for line in lines {
      for bank in SupportedBank.allCases {
        #expect(!line.contains(bank.shortName) && !line.contains(bank.name), "\(line)")
      }
    }
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
    #expect(RelativeTime.ago(now, now: now) == "just now")
    #expect(RelativeTime.ago(now.addingTimeInterval(-59 * 60), now: now) == "59 min ago")
    #expect(RelativeTime.ago(now.addingTimeInterval(-2 * 3600), now: now) == "2 h ago")
    #expect(RelativeTime.ago(now.addingTimeInterval(-3 * 86_400), now: now) == "3 days ago")
    #expect(RelativeTime.ago(now.addingTimeInterval(60), now: now) == "just now")
    #expect(RelativeTime.ago(now.addingTimeInterval(-240), now: now) == RelativeTime.ago(ms: 240_000, nowMs: 0))
    #expect(RelativeTime.ago(now.addingTimeInterval(-7 * 86_400), now: now) == "7 days ago")
    #expect(RelativeTime.ago(now.addingTimeInterval(-8 * 86_400), now: now) == "on 6 Oct")
    #expect(RelativeTime.ago(now.addingTimeInterval(-412 * 86_400), now: now) == "on 28 Aug 2025")
    #expect(RelativeTime.ago(ms: 86_400_000 * 30, nowMs: Int64(1_792_000_000) * 1000) == "on 14 Sep")
    #expect(RelativeTime.localDate(Int64(1_792_000_000) * 1000) == LocalDate(2026, 10, 14))
    #expect(RelativeTime.localDate(-1) == LocalDate(1970, 1, 1))
    #expect(RelativeTime.localDate(-4 * 3_600_000 - 1) == LocalDate(1969, 12, 31))
  }

  @Test func sendingTheTestAgainStartsANewTest() async throws {
    let lane = MockBankTexts()
    lane.testOutcome = .nothing
    lane.testDelay = .zero
    let m = model(services(texts: lane))
    m.chooseSource(.texts)
    m.sendTestText()
    for _ in 0..<200 where lane.test.isWaiting { try await Task.sleep(for: .milliseconds(5)) }
    #expect(lane.test == .nothingYet)
    m.navigationPath = [.textsSetUp]
    lane.testDelay = .seconds(60)
    m.sendTestText()
    #expect(lane.testsStarted == 2 && lane.test.isWaiting && m.path == [.textsSetUp, .textsTest])
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
    let lane = MockBankTexts(setUp: true, mailbox: mailbox, lastRan: last, lastText: last)
    #expect(lane.usesTexts)
    _ = try await mailbox.connect(.gmail, replacing: false, removingOld: false) { _ in .keep }
    #expect(lane.source == .email && lane.status == .notSetUp && lane.readsEmail)
    #expect(UseBankTextsSection.footnote(mailbox, lane: lane).hasPrefix(BankTexts.readsEmailNow))
    #expect(!UseBankTextsSection.footnote(mailbox, lane: MockBankTexts(mailbox: mailbox)).contains(BankTexts.readsEmailNow))
  }

  @Test func thePrivacyLineSaysPaymentShapedTextsFromAnySenderAreKept() {
    for line in [BankTexts.keepsPayments, BankTexts.keepsPaymentShapedTexts] {
      #expect(line.contains("from any sender") && line.contains("dropped at once"))
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
    let blocker = SourceSwitch.textsBlocker(mailbox, texts: lane)
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
    #expect(SourceSwitch.textsBlocker(mailbox, texts: lane) != nil)
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
    #expect(PasteBankTextModel.matchDetail(row, hidden: false).hasPrefix("AED 64.00") && PasteBankTextModel.matchDetail(row, hidden: false).hasSuffix("From email"))
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
    let texts = AppModel(store: InMemoryLedger(), mailbox: MockMailbox(), bankTexts: MockBankTexts(setUp: true))
    #expect(texts.mailOffer == nil && texts.usesBankTexts)
    let email = AppModel(store: InMemoryLedger(), mailbox: MockMailbox(), bankTexts: MockBankTexts(setUp: false, link: .linked))
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
    let app = AppModel(store: InMemoryLedger(), mailbox: s.mailbox, bankTexts: s.bankTexts)
    let lane = s.bankTexts
    #expect(lane != nil && app.bankTexts === lane && model(s).bankTexts === lane)
    #expect(AuthScenario.session(for: .textsWorking, releaseSurface: true).services.bankTexts != nil)
    #expect(AuthScenario.session(for: .setupBank, releaseSurface: false).services.bankTexts == nil)
  }

  @Test func aSwitchWhileTheMailboxesAreNotKnownIsRefused() async {
    let base = MockMailbox(mailboxes: [MockMailbox.gmail])
    base.connectDelay = .zero
    let mailbox = CountingMailbox(base)
    mailbox.known = false
    let lane = MockBankTexts(mailbox: base)
    #expect(SourceSwitch.textsBlocker(mailbox, texts: lane) == SourceSwitch.checking)
    #expect(UseBankTextsSection.footnote(mailbox, lane: lane) == SourceSwitch.checking)
    #expect(await SourceSwitch.toTexts(mailbox: mailbox, texts: lane) == .failed(SourceSwitch.checking))
    #expect(base.mailboxes.allSatisfy { $0.state != .disconnected } && lane.finishCalls == 0 && !lane.isSetUp)
    mailbox.known = true
    #expect(await SourceSwitch.toTexts(mailbox: mailbox, texts: lane) == .switched)
    #expect(lane.usesTexts)
  }

  @Test func aLinkWithNoMailboxListedHereDoesNotSwitch() async {
    let mailbox = MockMailbox()
    let lane = MockBankTexts(mailbox: mailbox, link: .linked)
    #expect(SourceSwitch.textsBlocker(mailbox, texts: lane) == SourceSwitch.readElsewhereLink)
    #expect(await SourceSwitch.toTexts(mailbox: mailbox, texts: lane) == .failed(SourceSwitch.readElsewhereLink))
    #expect(lane.finishCalls == 0 && !lane.isSetUp && !lane.usesTexts)
    #expect(await SourceSwitch.toTexts(mailbox: nil, texts: lane) == .failed(SourceSwitch.readElsewhereLink))
    #expect(lane.finishCalls == 0)
  }

  @Test func aDisconnectThatLeavesTheLinkDoesNotSwitch() async {
    let mailbox = MockMailbox(mailboxes: [MockMailbox.gmail])
    mailbox.connectDelay = .zero
    let lane = MockBankTexts(mailbox: mailbox, link: .linked)
    #expect(SourceSwitch.textsBlocker(mailbox, texts: lane) == nil)
    #expect(await SourceSwitch.toTexts(mailbox: mailbox, texts: lane) == .failed(SourceSwitch.linkRemains))
    #expect(SourceSwitch.reading(mailbox).isEmpty && lane.finishCalls == 0 && !lane.isSetUp && lane.readsEmail)
    lane.linkOverride = nil
    #expect(await SourceSwitch.toTexts(mailbox: mailbox, texts: lane) == .switched)
    #expect(lane.usesTexts && !lane.readsEmail)
  }

  @Test func setupDoesNotOfferTextsWhenTheLinkCopySaysLinked() {
    let linked = model(services(texts: MockBankTexts(link: .linked)))
    #expect(!linked.mailConnected && !linked.offersBankTexts && !linked.asksSource)
    #expect(model(services(texts: MockBankTexts(link: .unknown))).offersBankTexts)
    #expect(model(services(texts: MockBankTexts(link: .notLinked))).offersBankTexts)
  }

  @Test func theSourceCannotChangeWhileAMailboxConnects() async throws {
    let mailbox = MockMailbox()
    let lane = MockBankTexts(mailbox: mailbox)
    let s = services(texts: lane, mailbox: mailbox)
    mailbox.connectDelay = .milliseconds(300)
    let m = model(s)
    m.chooseSource(.email)
    #expect(m.source == .email && !m.asksSource)
    let connect = Task { await m.connectMail(.gmail) }
    for _ in 0..<200 where !m.connectBusy { try await Task.sleep(for: .milliseconds(1)) }
    #expect(m.connectBusy)
    m.backToSourceChoice()
    #expect(m.source == .email && !m.asksSource)
    m.chooseSource(.texts)
    #expect(m.source == .email && m.path.isEmpty)
    await connect.value
    #expect(!m.connectBusy && m.facts.mailbox == .scanning && m.path.isEmpty && lane.finishCalls == 0)
  }

  @Test func pasteIsOfferedWheneverTheCopyIsNotLinked() async {
    for link in [MailboxLinkCopy.notLinked, .unknown] {
      let lane = MockBankTexts(setUp: false, link: link)
      lane.readDelay = .zero
      #expect(lane.offersPaste && !lane.usesTexts)
      #expect(AppModel(store: InMemoryLedger(), bankTexts: lane).offersBankTextPaste)
      let m = PasteBankTextModel(lane: lane)
      #expect(!m.refused)
      await m.paste(MockBankTexts.sampleText)
      #expect(m.canAdd)
      let added = await m.add()
      #expect(added && lane.added.count == 1)
    }
    let linked = MockBankTexts(setUp: true, link: .linked)
    #expect(!linked.offersPaste && !AppModel(store: InMemoryLedger(), bankTexts: linked).offersBankTextPaste)
    #expect(!AppModel(store: InMemoryLedger()).offersBankTextPaste)
  }

  @Test func theFullGuideSharesTheShortGuideLines() {
    #expect(BankTextsGuide.shortSteps.contains(BankTextsGuide.runImmediately))
    #expect(BankTextsGuide.fullSteps.contains(BankTextsGuide.runImmediately))
    #expect(BankTextsGuide.shortSteps.contains(BankTextsGuide.newBlank))
    #expect(BankTextsGuide.fullSteps.contains(BankTextsGuide.newBlank))
    #expect(BankTextsGuide.shortSteps.count == 5 && BankTextsGuide.fullSteps.count == 6)
    #expect(BankTextsGuide.checklist.last?.title == BankTextsGuide.actionMissing.title)
  }

  @Test func noGuideStepClaimsTheActionTakesTheMessageByItself() {
    for step in BankTextsGuide.shortSteps + BankTextsGuide.fullSteps {
      #expect(!step.contains("by itself") && !step.contains("takes the message"), "\(step)")
    }
    #expect(BankTextsGuide.shortSteps.last?.contains("Check that it shows Message") == true)
    #expect(BankTextsGuide.fullSteps.last?.contains("pick Message") == true)
  }

  @Test func theFootnoteTellsADeviceThatRanTheAutomationToDeleteItWhenAnotherIPhoneReadsEmail() {
    let lane = MockBankTexts(setUp: true, link: .linked)
    let empty = UseBankTextsSection.footnote(MockMailbox(), lane: lane)
    #expect(empty.hasPrefix(BankTexts.readsEmailNow) && empty.contains(SourceSwitch.readElsewhereLink))
    var elsewhere = MockMailbox.gmail
    elsewhere.readElsewhere = true
    let other = MockMailbox(mailboxes: [elsewhere])
    let read = UseBankTextsSection.footnote(other, lane: MockBankTexts(setUp: true, mailbox: other))
    #expect(read.hasPrefix(BankTexts.readsEmailNow) && read.contains("Your other iPhone reads \(elsewhere.address)"))
    let ran = MockBankTexts(link: .linked, lastRan: now)
    #expect(UseBankTextsSection.footnote(MockMailbox(), lane: ran).hasPrefix(BankTexts.readsEmailNow))
    #expect(UseBankTextsSection.footnote(MockMailbox(), lane: MockBankTexts(link: .linked)) == SourceSwitch.readElsewhereLink)
  }

  @Test func anEmailAccountCountsTheTextsThatLookLikePaymentsItIgnored() {
    #expect(BankTexts.ignoredLine(0) == nil)
    #expect(BankTexts.ignoredLine(1) == "1 text that looks like a payment was ignored in the last 30 days because this account reads bank email.")
    #expect(BankTexts.ignoredLine(3) == "3 texts that look like payments were ignored in the last 30 days because this account reads bank email.")
    let linked = MockBankTexts(link: .linked, ignored: 3)
    #expect(UseBankTextsSection.ignoredLine(linked) == BankTexts.ignoredLine(3))
    #expect(linked.sawAutomationRun && UseBankTextsSection.offersDeleteAutomation(linked))
    #expect(UseBankTextsSection.ignoredLine(MockBankTexts(link: .notLinked, ignored: 3)) == nil)
    #expect(!UseBankTextsSection.offersDeleteAutomation(MockBankTexts(link: .linked)))
    #expect(!UseBankTextsSection.offersDeleteAutomation(MockBankTexts(setUp: true, link: .notLinked)))
  }

  @Test func theLastDisconnectSaysTheAutomationStaysWhenThisDeviceSawItRun() {
    let mailbox = MockMailbox(mailboxes: [MockMailbox.gmail])
    let ran = MockBankTexts(mailbox: mailbox, lastRan: now)
    #expect(ran.status == .notSetUp && ran.lastRanAt == now && ran.sawAutomationRun)
    #expect(BankTexts.disconnectNote(ran, mailbox: mailbox, disconnecting: MockMailbox.gmail.id) == BankTexts.automationStillThere)
    let ignored = MockBankTexts(mailbox: mailbox, ignored: 2)
    #expect(BankTexts.disconnectNote(ignored, mailbox: mailbox, disconnecting: MockMailbox.gmail.id) != nil)
    #expect(BankTexts.disconnectNote(MockBankTexts(mailbox: mailbox), mailbox: mailbox, disconnecting: MockMailbox.gmail.id) == nil)
    #expect(BankTexts.disconnectNote(nil, mailbox: mailbox, disconnecting: MockMailbox.gmail.id) == nil)
    let two = MockMailbox(mailboxes: [MockMailbox.gmail, MockMailbox.outlook])
    #expect(BankTexts.disconnectNote(MockBankTexts(mailbox: two, lastRan: now), mailbox: two, disconnecting: MockMailbox.gmail.id) == nil)
  }

  @Test func theMatchHidesItsAmountWhenAmountsAreHidden() {
    let match = BankTextMatch(
      rowID: "r1", kind: .payment, merchant: "Sample Grocer", amount: .aed(6400), postedAt: now, fromText: false)
    #expect(PasteBankTextModel.matchDetail(match, hidden: false).hasPrefix("AED 64"))
    let hidden = PasteBankTextModel.matchDetail(match, hidden: true)
    #expect(hidden.hasPrefix("Amount hidden") && !hidden.contains("64"))
    #expect(PasteBankTextModel(lane: MockBankTexts(), hidden: true).hidden)
  }

  @Test func pastedForeignAmountsShowInHundredthsAndHide() {
    let bhd = BankTextPreview(
      amount: Money(minor: 3_250, currency: "BHD"), direction: .out, merchant: nil, date: nil, bank: nil, cardEnding: nil)
    #expect(PasteBankTextModel.amountLine(bhd) == "BHD 32.50 out")
    #expect(PasteBankTextModel.amountLine(bhd, hidden: true) == "Amount hidden")
    let jpy = BankTextPreview(
      amount: Money(minor: 150_000, currency: "JPY"), direction: .incoming, merchant: nil, date: nil, bank: nil, cardEnding: nil)
    #expect(PasteBankTextModel.amountLine(jpy) == "JPY 1,500.00 in")
    let match = BankTextMatch(
      rowID: "r1", kind: .payment, merchant: nil, amount: Money(minor: 1_234, currency: "KWD"), postedAt: now, fromText: true)
    #expect(PasteBankTextModel.matchDetail(match, hidden: false).hasPrefix("KWD 12.34 \u{00B7}"))
  }

  @Test func aPasteWithSeveralPaymentsSaysSo() async {
    #expect(PasteBankTextModel.paymentCount(MockBankTexts.sampleText) == 1)
    #expect(PasteBankTextModel.paymentCount(MockBankTexts.worstPasted) == 3)
    #expect(PasteBankTextModel.paymentCount(MockBankTexts.codeText) == 0)
    let dib = "مشتريات بمبلغ 123.45 من بطاقة XX1234 في 05-06-2026 10:11 من SAMPLE SHOP. الحد الائتماني المتاح 1,234.56"
    #expect(PasteBankTextModel.paymentCount([dib, dib, dib].joined(separator: "\n")) == 3)
    #expect(PasteBankTextModel.paymentCount("خصم 1,234.56 في 05-06-2026 MB FUND TRANSFER DEBIT رصيدك 3,333.33") == 1)
    let prepaid = "Your prepaid card XXX1234 is ready. Unpaid fees: none."
    #expect(PasteBankTextModel.paymentCount([MockBankTexts.sampleText, prepaid].joined(separator: "\n")) == 1)
    #expect(PasteBankTextModel.paymentCount("Your prepaid card XXX1234 has AED 50 to spend.") == 0)
    let promo = "Get AED 20 back when bills are paid with your card"
    #expect(PasteBankTextModel.paymentCount([MockBankTexts.sampleText, promo].joined(separator: "\n")) == 1)
    #expect(PasteBankTextModel.severalNote(3) == "This paste has 3 payments. Paste them one at a time.")
    let lane = MockBankTexts(setUp: true)
    lane.readDelay = .zero
    let m = PasteBankTextModel(lane: lane)
    await m.paste(MockBankTexts.worstPasted)
    #expect(m.payments == 3 && m.text == MockBankTexts.worstPasted)
    await m.paste(MockBankTexts.sampleText)
    #expect(m.payments == 1)
  }

  @Test func theHeroStateDoesNotDependOnTheTime() {
    let status = BankTextsStatus.working(lastRan: now)
    #expect(BankTextsAlertsPage.Hero.state(status) == BankTextsAlertsPage.Hero(status, lastText: nil, now: now).state)
    #expect(BankTextsAlertsPage.Hero.state(.waitingForFirstText) == .ready)
    #expect(BankTextsAlertsPage.Hero.state(.notSetUp) == .notSetUp)
  }

  @Test func theTextsSummary() {
    let s = MailboxesSummary.texts(.working(lastRan: now.addingTimeInterval(-240)), now: now)
    #expect(s.title == "Bank texts are working" && s.detail == "Ran 4 min ago" && !s.needsYou)
    #expect(MailboxesSummary.texts(.waitingForFirstText, now: now).detail == "Waiting for your first bank text")
  }

  @Test func setupSaysTheAccountReadsEmailWhenTheLinkCopySaysLinked() {
    let linked = model(services(texts: MockBankTexts(link: .linked)))
    #expect(linked.readsBankEmailNote == BankTexts.setupReadsEmailElsewhere)
    #expect(BankTexts.setupReadsEmail.contains("Profile \u{203A} Bank alerts"))
    #expect(BankTexts.setupReadsEmailElsewhere.contains("on the iPhone that reads your bank email"))
    #expect(!linked.bankStepSubtitle.contains("SMS"))
    let open = model(services(texts: MockBankTexts(link: .notLinked)))
    #expect(open.readsBankEmailNote == nil && !open.bankStepSubtitle.contains("SMS"))
    let lane = MockBankTexts(link: .notLinked)
    let chose = model(services(texts: lane))
    chose.chooseSource(.email)
    lane.linkOverride = .linked
    #expect(chose.readsBankEmailNote == nil)
    let mailbox = MockMailbox(mailboxes: [MockMailbox.gmail])
    let connected = model(services(texts: MockBankTexts(mailbox: mailbox), mailbox: mailbox))
    #expect(connected.readsBankEmailNote == BankTexts.setupReadsEmail && !connected.bankStepSubtitle.contains("SMS"))
    var elsewhere = MockMailbox.gmail
    elsewhere.readElsewhere = true
    let other = MockMailbox(mailboxes: [elsewhere])
    let joined = model(services(texts: MockBankTexts(mailbox: other), mailbox: other))
    #expect(joined.readsBankEmailNote == BankTexts.setupReadsEmailElsewhere)
    let sample = AccountServices(
      account: MockAccountService(existing: .passkey, signedIn: true), mailbox: MockMailbox(offersSampleData: true),
      setup: MockSetupAuthoring(), notifications: MockNotificationPermission(), bankTexts: MockBankTexts())
    #expect(!model(sample).bankStepSubtitle.contains("SMS"))
    let noLane = model(services(texts: nil))
    #expect(noLane.readsBankEmailNote == nil && noLane.bankStepSubtitle.contains("not only SMS"))
  }

  @Test func theKeepingCopyCoversUnreadPaymentTexts() {
    for line in [BankTexts.keepsNoText, BankTexts.keepsPaymentShapedTexts] {
      #expect(!line.contains("payments it reads") && !line.contains("payment Hasala read"))
    }
    let keepsTexts = #/\bkeeps\b[^.]*?\btexts?\b/#
    for line in [BankTexts.keepsNoText, BankTexts.keepsPaymentShapedTexts, BankTexts.keepsPayments] {
      for sentence in line.split(separator: ".") where sentence.contains(keepsTexts) {
        #expect(sentence.contains("details"), "\(sentence)")
      }
    }
    #expect(BankTexts.keepsPaymentShapedTexts.contains("texts that look like payments"))
    #expect(BankTexts.keepsNoText.contains("never the text itself"))
  }

  @Test func aPasteWhileAddingIsIgnored() async throws {
    let lane = MockBankTexts(setUp: true)
    lane.readDelay = .zero
    lane.addDelay = .milliseconds(200)
    let m = PasteBankTextModel(lane: lane)
    await m.paste(MockBankTexts.sampleText)
    let adding = Task { await m.add() }
    for _ in 0..<200 where !m.adding { try await Task.sleep(for: .milliseconds(1)) }
    #expect(m.adding)
    await m.paste(MockBankTexts.undatedText)
    #expect(m.text == MockBankTexts.sampleText)
    let added = await adding.value
    #expect(added && lane.added == [MockBankTexts.sampleText] && m.text == MockBankTexts.sampleText)
  }

  @Test func pasteCopyNamesTheAutomationOnlyForTexts() {
    #expect(BankTexts.pasteDetail(usesTexts: true).contains("automation"))
    #expect(BankTexts.pasteIntro(usesTexts: true).contains("automation"))
    #expect(!BankTexts.pasteDetail(usesTexts: false).contains("automation"))
    #expect(!BankTexts.pasteIntro(usesTexts: false).contains("automation"))
    #expect(BankTexts.pasteIntro(usesTexts: false).contains("paste it here"))
  }

  @Test func theSwitchToTextsSaysItDisconnectsOnlyWhenAMailboxIsRead() {
    #expect(!UseBankTextsSection.switchMessage(MockMailbox()).contains("disconnect"))
    #expect(!UseBankTextsSection.switchMessage(nil).contains("disconnect"))
    #expect(UseBankTextsSection.switchMessage(MockMailbox(mailboxes: [MockMailbox.gmail])).hasPrefix("Hasala disconnects your mailbox."))
  }

  @Test func theHeroAnimatesOnlyWhenItsStateChanges() {
    let a = BankTextsAlertsPage.Hero(.working(lastRan: now.addingTimeInterval(-60)), lastText: nil, now: now)
    let b = BankTextsAlertsPage.Hero(.working(lastRan: now.addingTimeInterval(-60)), lastText: nil, now: now.addingTimeInterval(120))
    #expect(a.detail != b.detail && a.state == b.state && a.working)
    let ready = BankTextsAlertsPage.Hero(.waitingForFirstText, lastText: nil, now: now)
    #expect(ready.state != a.state && !ready.working)
  }

  @Test func theHeroNamesTheLastTextWithNoBank() {
    let hero = BankTextsAlertsPage.Hero(
      .working(lastRan: now.addingTimeInterval(-60)), lastText: now.addingTimeInterval(-7200), now: now)
    #expect(hero.detail.hasSuffix("\nLast text added 2 h ago"))
    #expect(!hero.detail.contains("Last bank text"))
  }

  @Test func bankTextTimesUseTheLedgerClock() {
    #expect(BankTexts.clock.secondsFromGMT() == 4 * 3600)
  }
}
