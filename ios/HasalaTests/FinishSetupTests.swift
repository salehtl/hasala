import Foundation
import HasalaDesign
import HasalaMocks
import HasalaModels
import Testing

@testable import Hasala

@MainActor
@Suite("Home: finish setting up")
struct FinishSetupTests: AccountSuite {
  func services(_ setup: MockSetupAuthoring = MockSetupAuthoring(),
                notifications: MockNotificationPermission = MockNotificationPermission(),
                mailbox: MockMailbox = MockMailbox()) -> AccountServices {
    AccountServices(account: MockAccountService(existing: .passkey, signedIn: true), mailbox: mailbox,
                    setup: setup, notifications: notifications)
  }

  func readMailbox(total: Int = 0) -> MockMailbox {
    let mailbox = MockMailbox(mailboxes: [MockMailbox.gmail])
    mailbox.total = total
    mailbox.step = .milliseconds(1)
    return mailbox
  }

  @Test func aScanThatFoundNothingIsTheFirstItem() {
    let m = FinishSetupModel(services: services(mailbox: readMailbox()))
    #expect(!m.items.contains(.bankAlerts))
    m.refresh(hasTransactions: false)
    #expect(m.noAlerts && m.items == [.bankAlerts, .plan, .notifications] && !m.isDone(.bankAlerts))
    m.refresh(hasTransactions: true)
    #expect(!m.noAlerts && m.isDone(.bankAlerts) && m.items.first == .bankAlerts)
  }

  @Test func theNoAlertsItemIsDerivedSoItSurvivesARelaunch() {
    let s = services(mailbox: readMailbox())
    let first = FinishSetupModel(services: s)
    first.refresh(hasTransactions: false)
    let relaunched = FinishSetupModel(services: s)
    relaunched.refresh(hasTransactions: false)
    #expect(first.noAlerts && relaunched.noAlerts && relaunched.items.first == .bankAlerts)
  }

  @Test func noAlertsItemWithoutAFinishedScan() async throws {
    let manual = FinishSetupModel(services: services())
    manual.refresh(hasTransactions: false)
    #expect(!manual.noAlerts && !manual.items.contains(.bankAlerts))

    let reading = readMailbox()
    reading.importing = MailImport(state: .reading, read: 0, total: 10)
    let scanning = FinishSetupModel(services: services(mailbox: reading))
    scanning.refresh(hasTransactions: false)
    #expect(!scanning.noAlerts)

    let sample = MockMailbox(offersSampleData: true, mailboxes: [MockMailbox.gmail])
    try await sample.loadSampleData()
    let review = FinishSetupModel(services: services(mailbox: sample))
    review.refresh(hasTransactions: false)
    #expect(!review.noAlerts)
  }

  @Test func checkAgainThatFindsNothingKeepsTheSheet() async {
    let m = FinishSetupModel(services: services(mailbox: readMailbox()))
    m.refresh(hasTransactions: false)
    m.openNoAlerts()
    await m.checkAgain()
    #expect(m.noAlerts && m.showingNoAlerts && !m.checkingAgain && m.checkFailure == nil)
  }

  @Test func checkAgainThatFindsAlertsClosesTheItem() async {
    let m = FinishSetupModel(services: services(mailbox: readMailbox(total: 24)))
    m.refresh(hasTransactions: false)
    m.openNoAlerts()
    await m.checkAgain()
    #expect(!m.noAlerts && !m.showingNoAlerts && m.isDone(.bankAlerts) && m.items.first == .bankAlerts)
  }

  @Test func theSheetNamesTheBanksAndTheMailbox() {
    let mailbox = readMailbox()
    mailbox.banks = [.adib, .enbd]
    let m = FinishSetupModel(services: services(mailbox: mailbox))
    #expect(m.noAlertsBanks == [.enbd, .adib] && m.noAlertsMailbox == .gmail)
  }

  @Test func theItemsLeaveAsTheyAreDone() async throws {
    let setup = MockSetupAuthoring()
    let notifications = MockNotificationPermission()
    let m = FinishSetupModel(services: services(setup, notifications: notifications))
    #expect(!m.isDone(.plan) && !m.isDone(.notifications))

    m.setPlan()
    let flow = try #require(m.planFlow)
    for d in [2, 5, 0, 0, 0] { flow.incomeEntry.type(.digit(d)) }
    flow.continueWithIncome()
    #expect(flow.path == [.plan])
    await flow.savePlan()
    #expect(setup.savePlanCalls == 1 && setup.income == 2_500_000 && setup.payday == 28 && setup.plan == StartingPlan())
    #expect(m.isDone(.plan) && m.planFlow == nil)

    m.askNotifications()
    #expect(m.askingNotifications)
    m.showDetails = true
    await m.allowNotifications()
    #expect(notifications.asked && notifications.showsDetails && m.isDone(.notifications) && !m.askingNotifications)
  }

  @Test func whatWasTypedStaysWhenThePlanIsClosedAndOpenedAgain() throws {
    let m = FinishSetupModel(services: services())
    m.setPlan()
    let flow = try #require(m.planFlow)
    flow.incomeEntry = AmountEntry(typing: "25000")
    flow.paydayChoice = .day(25)
    flow.continueWithIncome()
    m.planFlow = nil
    m.setPlan()
    let again = try #require(m.planFlow)
    #expect(again === flow && again.path.isEmpty && again.incomeEntry.text == "25000" && again.paydayChoice == .day(25))
  }

  @Test func notNowAnswersTheNotificationsItem() {
    let notifications = MockNotificationPermission()
    let m = FinishSetupModel(services: services(notifications: notifications))
    m.askNotifications()
    m.notificationsNotNow()
    #expect(m.isDone(.notifications) && notifications.answered && !notifications.asked)
  }

  @Test func whatTheAccountHoldsCountsAsDone() {
    let saved = SetupReadBack(incomeMinor: 2_500_000, payday: 25, split: StartingPlan())
    let m = FinishSetupModel(services: services(MockSetupAuthoring(saved: saved),
                                                notifications: MockNotificationPermission(answered: true)))
    #expect(m.isDone(.plan) && m.isDone(.notifications))
    let onlySplit = FinishSetupModel(services: services(MockSetupAuthoring(saved: SetupReadBack(split: StartingPlan()))))
    #expect(onlySplit.isDone(.plan))
    let onlyIncome = FinishSetupModel(services: services(MockSetupAuthoring(
      saved: SetupReadBack(incomeMinor: 2_500_000, payday: 25))))
    #expect(!onlyIncome.isDone(.plan))
  }

  @Test func anIncomeWithoutASplitKeepsThePlanItem() async throws {
    let setup = MockSetupAuthoring()
    let m = FinishSetupModel(services: services(setup))
    m.setPlan()
    let flow = try #require(m.planFlow)
    flow.incomeEntry = AmountEntry(typing: "25000")
    flow.continueWithIncome()
    await flow.savePlan(skip: true)
    #expect(setup.savePlanCalls == 1 && setup.income == 2_500_000 && setup.plan == nil)
    #expect(!m.isDone(.plan) && m.planFlow == nil)
    m.setPlan()
    let again = try #require(m.planFlow)
    #expect(again !== flow && again.incomeEntry.text == "25000")
    again.continueWithIncome()
    await again.savePlan()
    #expect(setup.savePlanCalls == 2 && setup.plan == StartingPlan() && m.isDone(.plan))
  }

  @Test func closingThePlanWithNothingChosenSendsNothingAndKeepsTheItem() async throws {
    let setup = MockSetupAuthoring()
    let m = FinishSetupModel(services: services(setup))
    m.setPlan()
    let flow = try #require(m.planFlow)
    flow.skipIncome()
    await flow.savePlan(skip: true)
    #expect(setup.savePlanCalls == 0 && !m.isDone(.plan) && m.planFlow == nil)
  }

  @Test func incomeIsWholeDirhamsAndSkipKeepsWhatWasTyped() async throws {
    let setup = MockSetupAuthoring()
    let flow = MonthlyPlanModel(setup: setup) { _ in }
    for key in [AmountKey.digit(4), .digit(8), .decimal, .digit(5)] { flow.incomeEntry.type(key) }
    #expect(flow.incomeEntry.text == "485" && flow.incomeMinor == 48_500)
    flow.incomeEntry = AmountEntry(typing: "12.50")
    #expect(flow.incomeEntry.text == "485")
    for _ in 0..<3 { flow.incomeEntry.type(.delete) }
    #expect(flow.incomeMinor == nil)
    flow.continueWithIncome()
    #expect(flow.path.isEmpty)
    flow.incomeEntry = AmountEntry(typing: "25000")
    flow.skipIncome()
    #expect(flow.savedIncomeMinor == nil && flow.incomeEntry.text == "25000" && flow.path == [.plan])
    await flow.savePlan()
    #expect(setup.planSaved && setup.income == nil && setup.payday == nil && setup.plan == StartingPlan())
  }

  @Test func theSavedPlanIsReadBackAndNotSentAgain() async {
    let saved = SetupReadBack(incomeMinor: 2_500_050, payday: 25,
                              split: StartingPlan(needsPercent: 60, wantsPercent: 20, savingsPercent: 20))
    let setup = MockSetupAuthoring(saved: saved)
    var outcome: SetupReadBack?
    let flow = MonthlyPlanModel(setup: setup) { outcome = $0 }
    #expect(flow.incomeEntry.display == "25,000" && flow.paydayChoice == .day(25) && flow.plan.needsPercent == 60)
    #expect(flow.today == MayaLedger.now.date && flow.nextPayday == LocalDate(2026, 10, 25))
    flow.incomeEntry = AmountEntry(typing: "25000")
    flow.continueWithIncome()
    await flow.savePlan()
    #expect(setup.savePlanCalls == 1 && outcome?.incomeMinor == 2_500_000 && outcome?.split?.needsPercent == 60)
    let unchanged = MockSetupAuthoring(saved: SetupReadBack(
      incomeMinor: 2_500_000, payday: 25, split: StartingPlan(needsPercent: 60, wantsPercent: 20, savingsPercent: 20)))
    outcome = nil
    let same = MonthlyPlanModel(setup: unchanged) { outcome = $0 }
    same.continueWithIncome()
    await same.savePlan()
    #expect(unchanged.savePlanCalls == 0 && outcome?.split != nil)
  }
}
