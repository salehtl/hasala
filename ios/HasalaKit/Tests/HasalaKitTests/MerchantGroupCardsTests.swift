import HasalaMocks
import HasalaModels
import Testing

@Suite("Merchant group cards")
struct MerchantGroupCardsTests {
  let s = Scenario.mayaBacklog.state
  let october = ReviewWindow.month(MayaLedger.october)

  func group(_ ref: MerchantGroupRef, in window: ReviewWindow = .all) throws -> ReviewGroupCardModel {
    try #require(ReviewEngine.groupCard(ref, s, in: window))
  }

  @Test func threeSpellingsOfTailscaleMakeOneCard() throws {
    let g = try group(MayaBacklog.tailscale)
    #expect(g.count == 30)
    #expect(g.otherMonths == 0)
    #expect(g.merchant == "Tailscale")
    #expect(g.spellings == ["PAYPAL *TAILSCALE", "TAILSCALE INC", "TAILSCALE.COM"])
    #expect(g.totals == [Money(minor: 360_00, currency: "USD")])
    #expect(g.amount.rendered(hidden: false) == "USD 360.00")
    #expect(g.amount.rendered(hidden: true) == "USD ••••")
    #expect(g.estimate == nil)
    #expect(g.dateRange == "3 Jul – 9 Oct")
    #expect(g.repeatsMonthly)
    #expect(g.id == "out.n:tailscale")
    #expect(g.countLine == "30 payments")
  }

  @Test func aPeriodShowsItsOwnPaymentsAndCountsTheOtherMonths() throws {
    let g = try group(MayaBacklog.tailscale, in: october)
    #expect(g.count == 8)
    #expect(g.otherMonths == 22)
    #expect(g.total == 30)
    #expect(g.totals == [Money(minor: 96_00, currency: "USD")])
    #expect(g.dateRange == "1 Oct – 9 Oct")
    #expect(g.countLine == "8 payments · 22 more in other months")
    #expect(g.spoken(hidden: true)
      == "Tailscale, 8 payments, USD Amount hidden, 1 October to 9 October, 22 more in other months, repeats monthly")
  }

  @Test func anUnverifiedRowAndARefundStayTheirOwnCards() {
    let items = ReviewEngine.items(s)
    let singles = items.compactMap { if case .single(let c) = $0 { c.id } else { nil } }
    #expect(singles.contains("bl-ts-unverified"))
    #expect(singles.contains("bl-ts-refund"))
    let tailscale = items.first { $0.id == "group.out.n:tailscale" }
    #expect(tailscale?.txnIDs.contains("bl-ts-unverified") == false)
    #expect(tailscale?.payments == 30)
    let unverified = items.first { $0.id == "bl-ts-unverified" }
    if case .single(let c) = unverified {
      #expect(c.reviewReason == .senderUnverified)
      #expect(c.group == MayaBacklog.tailscale)
    } else {
      Issue.record("the unverified row is not a single card")
    }
    #expect(items.first { $0.id == "bl-ts-refund" }?.group == MayaBacklog.tailscaleRefunds)
  }

  @Test func aShopFiledTwoWaysIsMixed() throws {
    let g = try group(MayaBacklog.qasrGroup)
    #expect(g.count == 6)
    #expect(g.isMixed)
    #expect(g.filedAs.map(\.id) == ["groceries", "shopping"])
    #expect(g.filedAs.map(\.count) == [4, 3])
    #expect(g.historyLine == "You sorted Qasr Corner Store as Groceries (4) and Shopping (3) before")
    #expect(g.suggestion == nil)
  }

  @Test func aGroupCarriesItsModelGuess() throws {
    let g = try group(MayaBacklog.brightwellGroup)
    #expect(g.count == 4)
    #expect(g.suggestion?.id == MayaBacklog.wrongGuess)
    #expect(g.suggestedBy == "Suggested by Cloudflare AI")
    #expect(!g.isMixed)
    #expect(g.historyLine == nil)
  }

  @Test func mixedCurrenciesAreTotalledApartWithAnEstimate() throws {
    let g = try group(MayaBacklog.nimbusGroup)
    #expect(g.totals == [Money(minor: 15_00, currency: "EUR"), Money(minor: 24_00, currency: "USD")])
    #expect(g.amount.rendered(hidden: false) == "EUR 15.00 + USD 24.00")
    let estimate = try #require(g.estimate)
    let homes = s.txns.filter { $0.groupRef == MayaBacklog.nimbusGroup }.compactMap(\.homeMinor)
    #expect(estimate.minor == Fils.sum(homes))
    #expect(estimate.estimate)
    #expect(g.estimateLine?.rendered(hidden: false) == "≈ AED \(MoneyFormat.string(estimate.minor)) estimated")
    #expect(!g.repeatsMonthly)
  }

  @Test func anEstimateSaysWhatItLeavesOut() throws {
    var s = s
    for i in s.txns.indices where s.txns[i].id == "bl-nimbus-10" { s.txns[i].homeMinor = nil }
    let g = try #require(ReviewEngine.groupCard(MayaBacklog.nimbusGroup, s))
    #expect(g.estimateLine?.rendered(hidden: false).hasSuffix(" estimated · Not counted: 1 in EUR") == true)
  }

  @Test func nearMissesStayApart() throws {
    let trading = try group(MayaBacklog.alNoorTradingGroup)
    let pharmacy = try group(MayaBacklog.alNoorPharmacyGroup)
    #expect(trading.count == 3)
    #expect(pharmacy.count == 2)
    #expect(Set(trading.txnIDs).isDisjoint(with: pharmacy.txnIDs))
  }

  @Test func oneWaitingPaymentIsASingleCard() {
    let items = ReviewEngine.items(s)
    #expect(items.contains { $0.id == "bl-saffron" })
    #expect(items.first { $0.id == "bl-saffron" }?.group == MayaBacklog.saffronGroup)
  }

  @Test func theTabCountsCardsAndPayments() {
    let items = ReviewEngine.items(s, in: october)
    #expect(items.count == 15)
    #expect(ReviewEngine.payments(items) == ReviewEngine.queue(s, in: october).count)
    #expect(ReviewEngine.payments(items) == 25)
    #expect(ReviewEngine.toSortLine(items) == "Tailscale and 14 more · 25 payments")
    #expect(Array(items.prefix(4).map(\.id)) == [
      "group.out.n:tailscale", "group.out.n:al noor trading", "group.out.n:qasr corner store",
      "group.out.n:brightwell academy",
    ])
    #expect(ReviewEngine.toSortLine([]) == nil)
    #expect(ReviewEngine.toSortLine(Array(items.prefix(1))) == "Tailscale · 8 payments")
  }

  @Test func everyPaymentInTheQueueIsOnExactlyOneCard() {
    for window in [ReviewWindow.all, october] {
      let items = ReviewEngine.items(s, in: window)
      let ids = items.flatMap(\.txnIDs)
      #expect(ids.count == Set(ids).count)
      #expect(Set(ids) == Set(ReviewEngine.queue(s, in: window).map(\.id)))
    }
  }

  @Test func monthsHoldTheirItems() {
    let all = ReviewEngine.itemMonths(ReviewEngine.items(s), now: MayaLedger.now)
    #expect(all.map(\.title) == ["This month"])
    #expect(all[0].items.first?.id == "group.out.n:tailscale")
    let summer = ReviewWindow.range(LocalDate(2026, 7, 1), LocalDate(2026, 9, 30))
    let months = ReviewEngine.itemMonths(ReviewEngine.items(s, in: summer), now: MayaLedger.now)
    #expect(months.map(\.title) == ["September"])
    #expect(months.flatMap(\.items).filter { $0.id == "group.out.n:tailscale" }.count == 1)
    #expect(months[0].items.first { $0.id == "group.out.n:tailscale" }?.payments == 22)
  }

  @Test func ungroupedScenariosKeepTheirCards() {
    for scenario in [Scenario.maya, .mayaSuggestions, .mayaRange, .mayaCopy, .mayaSamePurchase] {
      let state = scenario.state
      let items = ReviewEngine.items(state)
      #expect(items.map(\.id) == ReviewEngine.cards(state).map(\.id))
    }
  }

  @Test func aSkippedPaymentLeavesItsGroup() throws {
    var s = s
    s.skippedReview = ["bl-ts-01"]
    let g = try #require(ReviewEngine.groupCard(MayaBacklog.tailscale, s))
    #expect(g.count == 29)
    #expect(!g.txnIDs.contains("bl-ts-01"))
  }

  @Test func theWordsForAGroupSort() {
    #expect(ReviewEngine.sortAllLabel(30, as: "Subscriptions") == "Sort all 30 as Subscriptions")
    #expect(ReviewEngine.sortAllLabel(1, as: "Subscriptions") == "Sort as Subscriptions")
    #expect(ReviewEngine.sortEachLabel == "Sort each one")
    #expect(ReviewEngine.groupFiledAnnouncement(count: 30, merchant: "Tailscale", category: "Subscriptions", left: 39)
      == "Filed 30 Tailscale payments as Subscriptions. 39 left.")
    #expect(ReviewEngine.groupFiledAnnouncement(count: 1, merchant: "Tailscale", category: "Subscriptions", left: 0)
      == "Filed 1 Tailscale payment as Subscriptions. All caught up.")
    #expect(ReviewEngine.notThisLine(merchant: "Tailscale", category: "Software")
      == "Hasala won't suggest Software for Tailscale again.")
  }

  @Test func aRejectedGuessIsNoLongerASuggestion() throws {
    var s = s
    for i in s.txns.indices where s.txns[i].merchantGroup == "n:brightwell academy" {
      s.txns[i].rejectedCategories = [MayaBacklog.wrongGuess]
    }
    let g = try #require(ReviewEngine.groupCard(MayaBacklog.brightwellGroup, s))
    #expect(g.suggestion == nil)
    #expect(s.txn("bl-bright-10")?.reviewSuggestion == nil)
    let row = try #require(s.txn("bl-bright-10"))
    #expect(ReviewEngine.card(row, s).suggestion == nil)
    #expect(!SuggestionsEngine.snapshot(s).rows.contains { $0.id.hasPrefix("bl-bright") })
  }
}
