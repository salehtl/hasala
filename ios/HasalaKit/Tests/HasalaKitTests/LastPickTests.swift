import HasalaMocks
import HasalaModels
import Testing

@MainActor
@Suite("Your last pick comes first")
struct LastPickTests {
  static func ledger() -> InMemoryLedger { InMemoryLedger(state: Scenario.mayaBacklog.state) }

  static func card(_ l: InMemoryLedger, _ id: TxnID) throws -> ReviewCardModel {
    ReviewEngine.card(try #require(l.state.txn(id)), l.state)
  }

  @Test func aSortMakesTheNextPaymentOfTheMerchantSuggestIt() throws {
    let l = Self.ledger()
    #expect(l.state.txn("bl-alnoor-t-3")?.lastPick == nil)
    #expect(try Self.card(l, "bl-alnoor-t-3").suggestion == nil)
    try l.apply(.categorize("bl-alnoor-t-2", "groceries", learnRule: false, project: nil))
    for id in ["bl-alnoor-t-1", "bl-alnoor-t-3"] {
      #expect(l.state.txn(id)?.lastPick == "groceries")
      let card = try Self.card(l, id)
      #expect(card.suggestion?.id == "groceries" && card.suggestedBy == "Your last pick")
    }
    #expect(l.state.txn("bl-alnoor-t-2")?.lastPick == nil)
    #expect(l.state.txn("bl-alnoor-p-1")?.lastPick == nil)
    #expect(l.state.txn("bl-alnoor-p-2")?.lastPick == nil)
  }

  @Test func theLatestPickBeatsAnOlderOne() throws {
    let l = Self.ledger()
    #expect(l.state.txn("bl-qasr-1")?.lastPick == "shopping")
    #expect(try Self.card(l, "bl-qasr-1").suggestedBy == "Your last pick")
    try l.apply(.categorize("bl-qasr-6", "groceries", learnRule: false, project: nil))
    #expect(l.state.txn("bl-qasr-1")?.lastPick == "groceries")
    try l.apply(.categorize("bl-qasr-1", "dining", learnRule: false, project: nil))
    #expect(l.state.txn("bl-qasr-2")?.lastPick == "dining")
    #expect(try Self.card(l, "bl-qasr-5").suggestion?.id == "dining")
  }

  @Test func thePersonsPickBeatsTheAIAndARejectionDoesNotHideIt() throws {
    var s = Scenario.mayaBacklog.state
    for i in s.txns.indices where s.txns[i].merchantGroup == "n:brightwell academy" {
      s.txns[i].rejectedCategories = ["healthcare"]
    }
    let l = InMemoryLedger(state: s)
    let before = try Self.card(l, "bl-bright-9")
    #expect(before.suggestion?.id == MayaBacklog.wrongGuess && before.suggestedBy == "Suggested by Cloudflare AI")
    try l.apply(.categorize("bl-bright-10", "healthcare", learnRule: false, project: nil))
    let after = try Self.card(l, "bl-bright-9")
    #expect(after.suggestion?.id == "healthcare" && after.suggestedBy == "Your last pick")
    #expect(l.state.txn("bl-bright-9")?.reviewSuggestion == "healthcare")
    #expect(l.state.txn("bl-bright-9")?.modelSuggestion == MayaBacklog.wrongGuess)
  }

  @Test func ruleModelAndDictionaryFilingsAreNotThePersonsPick() throws {
    var s = Scenario.mayaBacklog.state
    let recent = LocalDateTime(2026, 10, 9, 12, 0)
    for i in s.txns.indices {
      switch s.txns[i].id {
      case "bl-alnoor-t-1":
        s.txns[i].categoryID = "groceries"
        s.txns[i].categorySource = .user
        s.txns[i].needsReview = false
        s.txns[i].categorizedAt = LocalDateTime(2026, 9, 23, 9, 0)
      case "bl-alnoor-t-2":
        s.txns[i].categoryID = "shopping"
        s.txns[i].categorySource = .rule(pattern: "al noor trading llc")
        s.txns[i].needsReview = false
        s.txns[i].categorizedAt = recent
      default: break
      }
    }
    var model = try #require(s.txn("bl-alnoor-t-3"))
    model.id = "bl-alnoor-model"
    model.categoryID = "dining"
    model.categorySource = .model(tag: "cf-clef/1")
    model.needsReview = false
    model.categorizedAt = recent
    var dictionary = model
    dictionary.id = "bl-alnoor-dictionary"
    dictionary.categoryID = "entertainment"
    dictionary.categorySource = .dictionary
    var split = model
    split.id = "bl-alnoor-split"
    split.categoryID = "transport"
    split.categorySource = .user
    split.splits = [
      SplitLine(id: 0, categoryID: "transport", amount: .aed(100_00)), SplitLine(id: 1, categoryID: "dining", amount: .aed(110_00)),
    ]
    s.txns += [model, dictionary, split]
    let l = InMemoryLedger(state: s)
    #expect(l.state.txn("bl-alnoor-t-3")?.lastPick == "groceries")
    #expect(try Self.card(l, "bl-alnoor-t-3").suggestedBy == "Your last pick")
  }

  @Test func aPickInAnArchivedCategoryIsNoSuggestionAndTheAIsAnswerStaysHidden() throws {
    var s = Scenario.mayaBacklog.state
    for i in s.categories.indices where s.categories[i].id == "shopping" { s.categories[i].archived = true }
    let l = InMemoryLedger(state: s)
    #expect(l.state.txn("bl-qasr-1")?.lastPick == "shopping")
    #expect(try Self.card(l, "bl-qasr-1").suggestion == nil)
    let picked = Self.ledger()
    try picked.apply(.categorize("bl-bright-10", "healthcare", learnRule: false, project: nil))
    try picked.apply(.archiveCategory("healthcare", moveTo: nil))
    #expect(picked.state.category("healthcare")?.archived == true)
    #expect(picked.state.txn("bl-bright-9")?.lastPick == "healthcare")
    #expect(picked.state.txn("bl-bright-9")?.modelSuggestion == MayaBacklog.wrongGuess)
    let bright = try Self.card(picked, "bl-bright-9")
    #expect(bright.suggestion == nil && bright.suggestedBy == nil)
  }

  @Test func undoTakesThePickBack() throws {
    let l = Self.ledger()
    let token = try #require(try l.apply(.categorize("bl-alnoor-t-2", "groceries", learnRule: false, project: nil)))
    #expect(l.state.txn("bl-alnoor-t-3")?.lastPick == "groceries")
    l.undo(token)
    #expect(l.state.txn("bl-alnoor-t-3")?.lastPick == nil)
    #expect(l.state.txn("bl-alnoor-t-2")?.inReview == true)
  }

  @Test func undoAlsoTakesBackTheOrderOfThatSort() throws {
    let l = Self.ledger()
    try l.apply(.categorize("bl-alnoor-t-2", "groceries", learnRule: false, project: nil))
    try l.apply(.categorize("bl-alnoor-t-3", "shopping", learnRule: false, project: nil))
    #expect(l.state.txn("bl-alnoor-t-1")?.lastPick == "shopping")
    let token = try #require(try l.apply(.categorize("bl-alnoor-t-2", "dining", learnRule: false, project: nil)))
    #expect(l.state.txn("bl-alnoor-t-1")?.lastPick == "dining")
    l.undo(token)
    #expect(l.state.txn("bl-alnoor-t-2")?.categoryID == "groceries")
    #expect(l.state.txn("bl-alnoor-t-1")?.lastPick == "shopping")
  }

  @Test func aHeldRowThatWaitsInReviewIsNoPick() throws {
    var s = Scenario.mayaBacklog.state
    for i in s.txns.indices where s.txns[i].id == "bl-alnoor-t-2" {
      s.txns[i].categoryID = "groceries"
      s.txns[i].categorySource = .user
      s.txns[i].needsReview = true
      s.txns[i].categorizedAt = LocalDateTime(2026, 10, 2, 9, 0)
    }
    let l = InMemoryLedger(state: s)
    #expect(l.state.txn("bl-alnoor-t-3")?.lastPick == nil)
    #expect(try Self.card(l, "bl-alnoor-t-3").suggestion == nil)
  }

  @Test func aMerchantThePersonSortedIsNoLongerNewOnItsCards() throws {
    var s = Scenario.mayaBacklog.state
    for i in s.txns.indices where s.txns[i].id == "bl-alnoor-t-1" { s.txns[i].isNewMerchant = true }
    let l = InMemoryLedger(state: s)
    #expect(try Self.card(l, "bl-alnoor-t-1").isNewMerchant)
    try l.apply(.categorize("bl-alnoor-t-2", "groceries", learnRule: false, project: nil))
    let card = try Self.card(l, "bl-alnoor-t-1")
    #expect(!card.isNewMerchant && card.suggestedBy == "Your last pick")
  }

  @Test func theTransactionSheetMarksThePickAndKeepsTheAIsLine() throws {
    let l = Self.ledger()
    try l.apply(.categorize("bl-bright-10", "healthcare", learnRule: false, project: nil))
    let detail = try #require(TransactionEngine.detail("bl-bright-9", l.state, now: l.now))
    #expect(detail.suggestion?.id == "healthcare")
    #expect(detail.sortedBy?.title == "Suggested by Cloudflare AI")
  }
}
