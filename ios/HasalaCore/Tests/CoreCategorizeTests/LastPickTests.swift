import Testing

@testable import CoreCategorize

@Suite("The person's last pick for a merchant")
struct LastPickTests {
  static let key = LastPick.Key(group: "n:qasr corner store", direction: "debit")

  static func row(
    _ id: String, _ category: String?, _ kind: SweepRow.SourceKind = .user, at: Int64? = nil, posted: Int64 = 1_000,
    group: String? = "n:qasr corner store", direction: String = "debit", split: Bool = false, review: Bool = false
  ) -> LastPick.Row {
    LastPick.Row(
      id: id, group: group, direction: direction, category: category, sourceKind: kind, split: split, needsReview: review, categorizedMs: at,
      postedMs: posted)
  }

  @Test func theNewestPickWinsByTheTimeItWasSorted() {
    let rows = [
      Self.row("a", "groceries", at: 5_000, posted: 9_000),
      Self.row("b", "shopping", at: 7_000, posted: 2_000),
      Self.row("c", "dining", at: 6_000, posted: 8_000),
    ]
    #expect(LastPick.picks(rows) == [Self.key: "shopping"])
    #expect(LastPick.picks(rows.reversed()) == [Self.key: "shopping"])
  }

  @Test func aRowWithNoSortTimeFallsBackToItsPostedDate() {
    let rows = [Self.row("a", "groceries", at: 5_000), Self.row("b", "shopping", posted: 6_000)]
    #expect(LastPick.picks(rows) == [Self.key: "shopping"])
    #expect(LastPick.picks([Self.row("a", "groceries", at: 7_000), Self.row("b", "shopping", posted: 6_000)]) == [Self.key: "groceries"])
  }

  @Test func onlyThePersonsOwnSortsCount() {
    let older = Self.row("own", "groceries", at: 1_000)
    for kind in [SweepRow.SourceKind.held, .rule, .model, .dictionary, .none] {
      let newer = Self.row("other", "shopping", kind, at: 9_000)
      #expect(!LastPick.counts(newer))
      #expect(LastPick.picks([older, newer]) == [Self.key: "groceries"], "\(kind)")
      #expect(LastPick.picks([newer]).isEmpty, "\(kind)")
    }
  }

  @Test func aSplitAnUncategorizedOrAnUngroupedRowIsNoPick() {
    #expect(LastPick.picks([Self.row("s", "shopping", at: 9_000, split: true)]).isEmpty)
    #expect(LastPick.picks([Self.row("u", nil, at: 9_000)]).isEmpty)
    #expect(LastPick.picks([Self.row("g", "shopping", at: 9_000, group: nil)]).isEmpty)
    #expect(LastPick.picks([Self.row("e", "shopping", at: 9_000, group: "")]).isEmpty)
  }

  @Test func aRowThatStillWaitsInReviewIsNoPick() {
    let older = Self.row("own", "groceries", at: 1_000)
    let waiting = Self.row("undone", "shopping", at: 9_000, review: true)
    #expect(!LastPick.counts(waiting))
    #expect(LastPick.picks([older, waiting]) == [Self.key: "groceries"])
    #expect(LastPick.picks([waiting]).isEmpty)
  }

  @Test func eachDirectionHasItsOwnPick() {
    let rows = [Self.row("out", "groceries", at: 1_000), Self.row("in", "refunds", at: 9_000, direction: "credit")]
    let picks = LastPick.picks(rows)
    #expect(picks[Self.key] == "groceries")
    #expect(picks[LastPick.Key(group: "n:qasr corner store", direction: "credit")] == "refunds")
  }

  @Test func equalTimesAreBrokenTheSameWayInAnyOrder() {
    let rows = [Self.row("a", "groceries", at: 5_000, posted: 1_000), Self.row("b", "shopping", at: 5_000, posted: 1_000)]
    #expect(LastPick.picks(rows) == LastPick.picks(rows.reversed()))
    #expect(LastPick.picks([Self.row("a", "groceries", at: 5_000, posted: 2_000), Self.row("b", "shopping", at: 5_000, posted: 1_000)])
      == [Self.key: "groceries"])
  }
}
