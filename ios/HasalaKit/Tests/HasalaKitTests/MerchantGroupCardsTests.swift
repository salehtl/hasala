import HasalaMocks
import HasalaModels
import Testing

@Suite("Merchant groups behind one card per payment")
struct MerchantGroupCardsTests {
  let s = Scenario.mayaBacklog.state
  let october = ReviewWindow.month(MayaLedger.october)

  @Test func everyWaitingPaymentIsItsOwnCard() {
    for window in [ReviewWindow.all, october] {
      let cards = ReviewEngine.cards(s, in: window)
      #expect(cards.map(\.id) == ReviewEngine.queue(s, in: window).map(\.id))
      #expect(cards.count == Set(cards.map(\.id)).count)
    }
    let thisMonth = ReviewEngine.cards(s, in: october)
    #expect(thisMonth.count == 30)
    #expect(thisMonth.filter { $0.group == MayaBacklog.tailscale }.count == 9)
    #expect(thisMonth.contains { $0.id == "bl-ts-01" } && thisMonth.contains { $0.id == "bl-ts-02" })
  }

  @Test func anUnverifiedRowAndARefundAreCardsLikeTheRest() throws {
    let cards = ReviewEngine.cards(s)
    let unverified = try #require(cards.first { $0.id == "bl-ts-unverified" })
    #expect(unverified.reviewReason == .senderUnverified)
    #expect(unverified.group == MayaBacklog.tailscale)
    #expect(cards.first { $0.id == "bl-ts-refund" }?.group == MayaBacklog.tailscaleRefunds)
    #expect(cards.first { $0.id == "bl-saffron" }?.group == MayaBacklog.saffronGroup)
  }

  @Test func aCardCarriesItsModelGuess() throws {
    let row = try #require(s.txn("bl-bright-10"))
    let card = ReviewEngine.card(row, s)
    #expect(card.suggestion?.id == MayaBacklog.wrongGuess)
    #expect(card.suggestedBy == "Suggested by Cloudflare AI")
    #expect(card.canAlwaysUse)
  }

  @Test func theGroupIndexCountsOnlyThePersonsFilings() throws {
    #expect(ReviewEngine.filedAs(MayaBacklog.qasrGroup, s).map(\.id) == ["groceries", "shopping"])
    #expect(ReviewEngine.filedAs(MayaBacklog.qasrGroup, s).map(\.count) == [4, 3])
    var s = s
    for i in s.txns.indices {
      switch s.txns[i].id {
      case "bl-bright-7":
        s.txns[i].categoryID = "entertainment"
        s.txns[i].categorySource = .user
        s.txns[i].needsReview = false
      case "bl-bright-8":
        s.txns[i].needsReview = false
      default: break
      }
    }
    #expect(s.txn("bl-bright-8")?.autoFiledByCloudflare == true)
    #expect(ReviewEngine.filedAs(MayaBacklog.brightwellGroup, s).map(\.id) == ["entertainment"])
    #expect(ReviewEngine.filedAs(MayaBacklog.brightwellGroup, s).map(\.count) == [1])
  }

  @Test func theGroupIndexKnowsWhatRepeatsMonthly() {
    #expect(ReviewEngine.repeatsMonthly(MayaBacklog.tailscale, s))
    #expect(!ReviewEngine.repeatsMonthly(MayaBacklog.tailscaleRefunds, s))
    #expect(!ReviewEngine.repeatsMonthly(MayaBacklog.nimbusGroup, s))
  }

  @Test func aSkippedPaymentLeavesTheQueue() {
    var s = s
    s.skippedReview = ["bl-ts-01"]
    #expect(!ReviewEngine.cards(s).contains { $0.id == "bl-ts-01" })
    #expect(ReviewEngine.cards(s).contains { $0.id == "bl-ts-02" })
  }

  @Test func ungroupedScenariosKeepTheirCards() {
    for scenario in [Scenario.maya, .mayaSuggestions, .mayaRange, .mayaCopy, .mayaSamePurchase] {
      let state = scenario.state
      #expect(ReviewEngine.cards(state).map(\.id) == ReviewEngine.queue(state).map(\.id))
    }
  }

  @Test func aRejectedGuessIsNoLongerASuggestion() throws {
    var s = s
    for i in s.txns.indices where s.txns[i].merchantGroup == "n:brightwell academy" {
      s.txns[i].rejectedCategories = [MayaBacklog.wrongGuess]
    }
    #expect(s.txn("bl-bright-10")?.reviewSuggestion == nil)
    let row = try #require(s.txn("bl-bright-10"))
    #expect(ReviewEngine.card(row, s).suggestion == nil)
  }

  @Test func aRejectedModelCategoryIsNotShownInTheSheet() throws {
    var s = s
    for i in s.txns.indices where s.txns[i].merchantGroup == "n:brightwell academy" {
      s.txns[i].rejectedCategories = [MayaBacklog.wrongGuess]
    }
    let detail = try #require(TransactionEngine.detail("bl-bright-10", s, now: MayaLedger.now))
    #expect(detail.category == nil)
    #expect(detail.sortedBy == nil)
    #expect(detail.suggestion == nil)
    #expect(detail.needsReview)
    #expect(detail.glyph == .review)
    let kept = try #require(TransactionEngine.detail("bl-bright-10", Scenario.mayaBacklog.state, now: MayaLedger.now))
    #expect(kept.category?.id == MayaBacklog.wrongGuess)
    #expect(kept.sortedBy?.title == "Suggested by Cloudflare AI")
  }

  @Test func theReviewTabListsOneRowPerPayment() throws {
    let cards = ReviewEngine.cards(s, in: october)
    let rows = cards.map { ReviewEngine.tabRow($0, s) }
    #expect(rows.map(\.id) == cards.map(\.id))
    #expect(rows.allSatisfy { $0.identifier == "review.tab.row.\($0.id)" })
    let bright = try #require(rows.first { $0.id == "bl-bright-10" })
    #expect(bright.subtitle == "Looks like Shopping" && bright.tone == .suggestion)
    let unverified = try #require(rows.first { $0.id == "bl-ts-unverified" })
    #expect(unverified.tone == .reason && unverified.reason == .senderUnverified)
  }
}
