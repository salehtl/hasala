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
    #expect(g.spellings == ["TAILSCALE.COM", "TAILSCALE INC", "PAYPAL *TAILSCALE"])
    #expect(g.totals == [Money(minor: 360_00, currency: "USD")])
    #expect(g.amount.rendered(hidden: false) == "USD 360.00")
    #expect(g.amount.rendered(hidden: true) == "USD ••••")
    #expect(g.estimate == nil)
    #expect(g.dateRange == "3 Jul to 9 Oct")
    #expect(g.metaLine == "Spent · 30 payments · 3 Jul to 9 Oct")
    #expect(!g.isIncome && !g.isNewMerchant)
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
    #expect(g.dateRange == "1 Oct to 9 Oct")
    #expect(g.countLine == "8 payments · 22 more in other months")
    #expect(g.spoken(hidden: true)
      == "Tailscale, 8 payments from 1 October to 9 October, USD Amount hidden, 22 more in other months, repeats monthly.")
    #expect(!g.spoken(hidden: false).contains(g.leftOutLine ?? "-"))
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

  @Test func aGroupNamesThePaymentsItLeavesOut() throws {
    let g = try group(MayaBacklog.tailscale)
    #expect(g.leftOut == [ReviewLeftOut(txnID: "bl-ts-unverified", reason: .senderUnverified)])
    #expect(g.leftOutLine == "1 more payment gets its own card. Hasala couldn't verify its sender.")
    #expect(try group(MayaBacklog.tailscale, in: .month(YearMonth(2026, 9))).leftOut.isEmpty)
    #expect(try group(MayaBacklog.qasrGroup).leftOutLine == nil)

    var two = s
    for i in two.txns.indices where two.txns[i].id == "bl-ts-02" {
      two.txns[i].reviewReason = .senderUnverified
      two.txns[i].reachable = false
    }
    let plural = try #require(ReviewEngine.groupCard(MayaBacklog.tailscale, two))
    #expect(plural.count == 29)
    #expect(plural.leftOut.map(\.txnID) == ["bl-ts-02", "bl-ts-unverified"].sorted { a, b in
      (two.txn(a)?.postedAt ?? MayaLedger.now) < (two.txn(b)?.postedAt ?? MayaLedger.now)
    })
    #expect(plural.leftOutLine == "2 more payments get their own cards. Hasala couldn't verify their sender.")

    var copy = s
    for i in copy.txns.indices where copy.txns[i].id == "bl-ts-unverified" {
      copy.txns[i].reviewReason = nil
      copy.txns[i].heldCopy = HeldCopy(of: "bl-ts-01", fromOtherInbox: true)
    }
    #expect(ReviewEngine.groupCard(MayaBacklog.tailscale, copy)?.leftOutLine
      == "1 more payment gets its own card. It may be a copy.")

    var pair = s
    for i in pair.txns.indices where pair.txns[i].id == "bl-ts-unverified" {
      pair.txns[i].reviewReason = nil
      pair.txns[i].samePurchase = SamePurchaseMatch(of: "bl-ts-01")
    }
    for i in pair.txns.indices where pair.txns[i].id == "bl-ts-01" { pair.txns[i].reachable = false }
    let same = try #require(ReviewEngine.groupCard(MayaBacklog.tailscale, pair))
    #expect(Set(same.leftOut) == [
      ReviewLeftOut(txnID: "bl-ts-01", reason: .samePurchase), ReviewLeftOut(txnID: "bl-ts-unverified", reason: .samePurchase),
    ])
    #expect(same.leftOutLine == "2 more payments get their own cards. Each may be the same purchase twice.")

    var mixed = two
    for i in mixed.txns.indices where mixed.txns[i].id == "bl-ts-unverified" {
      mixed.txns[i].reviewReason = nil
      mixed.txns[i].heldCopy = HeldCopy(of: "bl-ts-01", fromOtherInbox: true)
    }
    #expect(ReviewEngine.groupCard(MayaBacklog.tailscale, mixed)?.leftOutLine == "2 more payments get their own cards.")
  }

  @Test func aGroupGuessCoversEveryPaymentOrNone() throws {
    var one = s
    for i in one.txns.indices where one.txns[i].id == "bl-ts-05" {
      one.txns[i].categoryID = "subscriptions"
      one.txns[i].categorySource = .model(tag: "cf-clef/1")
    }
    let partial = try #require(ReviewEngine.groupCard(MayaBacklog.tailscale, one))
    #expect(partial.suggestion == nil && partial.suggestedBy == nil)

    var all = s
    for i in all.txns.indices where all.txns[i].groupRef == MayaBacklog.tailscale && all.txns[i].reachable {
      all.txns[i].categoryID = "subscriptions"
      all.txns[i].categorySource = .model(tag: i % 2 == 0 ? "cf-clef/1" : "apple-fm/1")
    }
    let every = try #require(ReviewEngine.groupCard(MayaBacklog.tailscale, all))
    #expect(every.suggestion?.id == "subscriptions")
    #expect(every.suggestedBy != nil)
    #expect(every.count == 30)
  }

  @Test func aGroupOfRefundsReadsAsMoneyIn() throws {
    var s = s
    var second = try #require(s.txn("bl-ts-refund"))
    second.id = "bl-ts-refund-2"
    second.postedAt = LocalDateTime(2026, 10, 8, 20, 5)
    s.txns.append(second)
    let g = try #require(ReviewEngine.groupCard(MayaBacklog.tailscaleRefunds, s))
    #expect(g.count == 2)
    #expect(g.isIncome)
    #expect(g.verb == "Received")
    #expect(g.metaLine == "Received · 2 payments · 7 Oct to 8 Oct")
    #expect(g.spoken(hidden: false) == "Tailscale, 2 payments received from 7 October to 8 October, plus USD 12.00.")
    #expect(g.spoken(hidden: true).contains("plus USD Amount hidden"))
    #expect(ReviewEngine.items(s).contains { $0.id == "group.in.n:tailscale" })
    #expect(!g.repeatsMonthly)
    #expect(ReviewEngine.groupCard(MayaBacklog.tailscaleRefunds, s)?.repeatsMonthly == false)
    #expect(try group(MayaBacklog.tailscale).repeatsMonthly)
  }

  @Test func aGroupWithANewMerchantSaysSo() throws {
    var s = s
    for i in s.txns.indices where s.txns[i].id == "bl-alnoor-t-1" { s.txns[i].isNewMerchant = true }
    let g = try #require(ReviewEngine.groupCard(MayaBacklog.alNoorTradingGroup, s))
    #expect(g.isNewMerchant)
    #expect(g.spoken(hidden: false).contains(", new merchant."))
    #expect(try !group(MayaBacklog.alNoorTradingGroup).isNewMerchant)
  }

  @Test func theSpokenCardEndsWithItsGuess() throws {
    let g = try group(MayaBacklog.brightwellGroup)
    #expect(g.spoken(hidden: false).hasSuffix(". Looks like Shopping, suggested by Cloudflare AI."))
  }

  @Test func aShopFiledTwoWaysIsMixed() throws {
    let g = try group(MayaBacklog.qasrGroup)
    #expect(g.count == 6)
    #expect(g.isMixed)
    #expect(g.filedAs.map(\.id) == ["groceries", "shopping"])
    #expect(g.filedAs.map(\.count) == [4, 3])
    #expect(g.historyLine == "You sorted Qasr Corner Store as Groceries (4) and Shopping (3) before")
    #expect(g.spoken(hidden: false).hasSuffix(". You sorted Qasr Corner Store as Groceries (4) and Shopping (3) before."))
    #expect(g.suggestion == nil)
  }

  @Test func aCloudflareFilingIsNotSortedByThePerson() throws {
    var s = s
    for i in s.txns.indices {
      switch s.txns[i].id {
      case "bl-bright-7":
        s.txns[i].categoryID = "entertainment"
        s.txns[i].categorySource = .user
        s.txns[i].needsReview = false
      case "bl-bright-8":
        s.txns[i].needsReview = false
      case "bl-bright-9", "bl-bright-10":
        s.txns[i].categoryID = nil
        s.txns[i].categorySource = nil
      default: break
      }
    }
    #expect(s.txn("bl-bright-8")?.autoFiledByCloudflare == true)
    let g = try #require(ReviewEngine.groupCard(MayaBacklog.brightwellGroup, s))
    #expect(g.count == 2)
    #expect(g.filedAs.map(\.id) == ["entertainment"])
    #expect(g.filedAs.map(\.count) == [1])
    #expect(!g.isMixed)
    #expect(g.historyLine == nil)
    #expect(ReviewEngine.filedAs(MayaBacklog.brightwellGroup, s).map(\.id) == ["entertainment"])
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

  @Test func aDenseGroupHasTwoCurrenciesThreeSpellingsAndALeftOutRow() throws {
    let g = try group(MayaBacklog.mirdifGroup)
    #expect(g.count == 4)
    #expect(g.totals.map(\.currency) == ["AED", "USD"])
    #expect(g.spellings.count == 3)
    #expect(g.leftOut.map(\.txnID) == ["bl-mirdif-unverified"])
    #expect(g.leftOutLine == "1 more payment gets its own card. Hasala couldn't verify its sender.")
    #expect(g.estimateBreakdown != nil && g.estimate != nil)
    #expect(g.suggestion?.id == MayaBacklog.wrongGuess)
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
    #expect(items.count == 17)
    #expect(ReviewEngine.payments(items) == ReviewEngine.queue(s, in: october).count)
    #expect(ReviewEngine.payments(items) == 30)
    #expect(ReviewEngine.toSortLine(items) == "Tailscale and 16 more · 30 payments")
    #expect(Array(items.prefix(4).map(\.id)) == [
      "group.out.n:tailscale", "group.out.n:mirdif books", "group.out.n:qasr corner store",
      "group.out.n:al noor trading",
    ])
    #expect(Array(items.prefix(3).map(\.payments)) == [8, 4, 3])
    #expect(zip(items, items.dropFirst()).allSatisfy { $0.payments >= $1.payments })
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
    #expect(months[0].items.first?.id == "group.out.n:tailscale")
    #expect(zip(months[0].items, months[0].items.dropFirst()).allSatisfy { $0.payments >= $1.payments })
    let everything = ReviewEngine.itemMonths(ReviewEngine.items(s), now: MayaLedger.now)
    #expect(everything.flatMap(\.items) == ReviewEngine.items(s))
  }

  @Test func mostPaymentsLeadInsideEachMonth() {
    let fourMonths = ReviewWindow.range(LocalDate(2026, 7, 1), LocalDate(2026, 10, 31))
    var s = s
    for i in s.txns.indices where s.txns[i].id == "bl-saffron" { s.txns[i].postedAt = LocalDateTime(2026, 9, 6, 17, 45) }
    let items = ReviewEngine.items(s, in: fourMonths)
    let months = ReviewEngine.itemMonths(items, now: MayaLedger.now)
    #expect(months.map(\.month) == months.map(\.month).sorted(by: >))
    #expect(months.flatMap(\.items) == items)
    for m in months {
      #expect(zip(m.items, m.items.dropFirst()).allSatisfy { $0.payments >= $1.payments })
    }
    #expect(months.count == 2)
    #expect(months[1].items.contains { $0.id == "bl-saffron" })
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

  @Test func spellingsLeadWithTheMostUsed() throws {
    var s = Scenario.mayaBacklog.state
    let raws = ["TAILSCALE INC", "PAYPAL *TAILSCALE", "TAILSCALE INC", "TAILSCALE.COM"]
    for (i, raw) in raws.enumerated() {
      s.txns.append(Txn(
        id: "sp-\(i)", merchant: "Tailscale", amount: Money(minor: 6_00, currency: "USD"),
        postedAt: LocalDateTime(2026, 6, 2 + i, 9, 0), needsReview: true,
        provenance: Provenance(title: "Alert", readAt: "Read automatically", rawMerchant: raw),
        merchantKey: raw.lowercased(), merchantGroup: "n:tailscale"))
    }
    let g = try #require(ReviewEngine.groupCard(MayaBacklog.tailscale, MockReach.refreshed(s)))
    #expect(g.count == 34)
    #expect(g.spellings == ["TAILSCALE INC", "TAILSCALE.COM", "PAYPAL *TAILSCALE"])
    let june = ReviewWindow(from: LocalDate(2026, 6, 1), to: LocalDate(2026, 6, 30))
    var only = s
    only.txns.removeAll { $0.merchantGroup == "n:tailscale" && !$0.id.hasPrefix("sp-") }
    let h = try #require(ReviewEngine.groupCard(MayaBacklog.tailscale, MockReach.refreshed(only), in: june))
    #expect(h.spellings == ["TAILSCALE INC", "PAYPAL *TAILSCALE", "TAILSCALE.COM"])
  }

  @Test func oneMoreInAnotherMonthIsSaidAsTheCardShowsIt() throws {
    let g = try group(MayaBacklog.alNoorTradingGroup, in: october)
    #expect(g.otherMonths == 1)
    #expect(g.countLine == "2 payments · 1 more in another month")
    #expect(g.spoken(hidden: true)
      == "Al Noor Trading, 2 payments from 1 October to 9 October, AED Amount hidden, 1 more in another month.")
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
}
