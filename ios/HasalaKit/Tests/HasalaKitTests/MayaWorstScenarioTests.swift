import Foundation
import HasalaMocks
import HasalaModels
import Testing

@Suite("Break-UI scenarios")
struct MayaWorstScenarioTests {
  static let now = MayaLedger.now

  static func engines(_ s: LedgerState) {
    _ = HomeEngine.snapshot(s, now: now)
    _ = PlanEngine.snapshot(s, now: now)
    _ = BillsEngine.snapshot(s, now: now)
    _ = ProfileEngine.snapshot(s, now: now)
    _ = NotificationsEngine.snapshot(s, now: now)
    _ = CategoriesEngine.snapshot(s)
    _ = ReviewEngine.queue(s)
    _ = ActivityEngine.snapshot(s, now: now, filter: TxnFilter())
  }

  @MainActor @Test(arguments: [Scenario.mayaWorst, .mayaWorstTexts, .mayaEmpty, .mayaOne, .mayaHuge])
  func everyEngineReadsIt(_ scenario: Scenario) {
    Self.engines(InMemoryLedger(state: scenario.state, now: scenario.now).state)
  }

  @Test func existingScenariosAreUntouched() {
    #expect(Scenario.maya.state == MayaHistory.state)
    #expect(Scenario.fromLaunchArguments(["-HasalaScenario", "mayaWorst"]) == .mayaWorst)
    #expect(MockPerson.of(.maya) == .maya)
  }

  @Test func anEmailOverrideKeepsTheIdentityConsistent() {
    let p = MockPerson.maya.withEmail("ab@cd.co")
    #expect(p.email == "ab@cd.co" && p.gmailAddress == "ab@cd.co")
    #expect(p.outlookAddress == "ab.k@cd.co")
    #expect(p.emailHint == "a\u{2022}@c\u{2022}.co")
    #expect(MockPerson.hint("a@b.co") == "a\u{2022}@b\u{2022}.co")
    #expect(MockPerson.hint("maya@example.com") == "m\u{2022}\u{2022}\u{2022}@e\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}.com")
  }

  @Test func foreignReviewAmountsUseTheirMinorDigits() {
    for s in [Scenario.mayaWorst, .mayaHuge] {
      let jpy = s.state.txns.filter { $0.needsReview && $0.amount.currency == "JPY" }
      #expect(jpy.allSatisfy { $0.amount.minor < 1_000_000 })
    }
  }

  @Test func worstHitsTheCatalog() {
    let s = Scenario.mayaWorst.state
    #expect(s.txns.filter(\.needsReview).count == MayaWorst.reviewCount)
    #expect(s.txn("steam")?.amount == Money(minor: 12_500, currency: "KWD"))
    #expect(s.txn("dubai-taxi")?.amount.currency == "JPY")
    #expect(s.txn("transfer-in")?.amount == .aed(1_284_507_25))
    #expect(s.txn("talabat")?.amount == .aed(1))
    #expect(s.txn("w-blank")?.merchant == "")
    #expect(s.categories.filter { !$0.builtin }.allSatisfy { $0.name.unicodeScalars.count <= CategoryLimits.maxName })
    #expect(s.profile.displayName == MockPerson.worst.displayName)
    #expect(s.txn("w-split")?.splits.reduce(0) { $0 + $1.amount.minor } == 12_600_00)
  }

  @Test func emptyHasNothing() {
    let s = Scenario.mayaEmpty.state
    #expect(s.txns.isEmpty && s.bills.isEmpty && s.projects.isEmpty && s.goals.isEmpty && s.accounts.isEmpty)
  }

  @Test func oneHasOneOfEach() {
    let s = Scenario.mayaOne.state
    #expect(s.txns.count == 1 && s.bills.count == 1 && s.projects.count == 1 && s.goals.count == 1)
    #expect(s.accounts.count == 1 && s.rules.count == 1 && s.billCandidates.count == 1)
    #expect(s.categories.filter { !$0.builtin }.count == 1)
  }

  @Test func hugeIsTheUpperBound() {
    let s = Scenario.mayaHuge.state
    #expect(s.txns.count == MayaWorst.hugeTxnCount)
    #expect(s.txns.filter(\.needsReview).count == MayaWorst.hugeReviewCount)
    #expect(s.categories.count == 60)
    #expect(s.categories.filter { !$0.builtin && !$0.archived }.count == CategoryLimits.maxActiveCustom)
    #expect(s.bills.count == 40)
    #expect(s.rules.count == 300)
    #expect(s.projects.filter(\.isOpen).count == 12 && s.projects.filter(\.complete).count == 30)
    #expect(s.accounts.count == 12)
    #expect(Set(s.txns.map(\.id)).count == s.txns.count)
    #expect(Scenario.mayaHuge.state == s)
    #expect(MockPerson.huge.outlookAddress.utf8.count == 254)
  }
}
