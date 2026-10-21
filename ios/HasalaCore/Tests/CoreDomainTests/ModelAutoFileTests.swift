import CoreCategorize
import CoreReplay
import Foundation
import Testing

@testable import CoreDomain

final class GradedCloud: GradedCategoryModel, Sendable {
  let modelTag: String
  let graded: [String: (answer: ModelAnswer, autoFile: Bool)]

  init(_ tag: String, _ graded: [String: (answer: ModelAnswer, autoFile: Bool)]) {
    modelTag = tag
    self.graded = graded
  }

  func availability() -> ModelAvailability { .available }
  func suggest(subject: String, allowed: [AllowedCategory]) async -> ModelAnswer { .unknown }
  func suggestGraded(subject: String, allowed: [AllowedCategory]) async -> (answer: ModelAnswer, autoFile: Bool) {
    graded[subject] ?? (.unknown, true)
  }
}

@Suite("ModelSuggestionSweep: sort automatically")
struct ModelAutoFileTests {
  typealias T = ModelSuggestionSweepTests

  @Test("a confident graded cloud answer files the row; an unsure one and a plain model's answer only suggest")
  func autoFile() async throws {
    var l = T.Ledger()
    let ids = try l.ingest([
      ("SURE SHOP", "debit"), ("UNSURE SHOP", "debit"), (T.arabic, "debit"), ("PLAIN SHOP", "debit"), ("SURE SHOP", "debit"),
    ], needsReview: false)
    let device = SweepModel("apple-fm/26.1", answers: ["plain shop": .category("shopping")])
    let cloud = GradedCloud(
      "cf-clef/1",
      [
        "sure shop": (.category("groceries"), true), "unsure shop": (.category("groceries"), false),
        "مطعم الياسمين الشعبي": (.category("dining"), true), "plain shop": (.unknown, true),
      ])
    let suggestions = try await ModelSuggestionSweep.suggest(
      rows: l.rows(), categorizer: T.categorizer, allowed: T.allowed, stages: [.onDevice(device), .cloud(cloud)], context: .foreground,
      cache: MemoryCache(), now: { now })
    let blobs = try ModelSuggestionSweep.author(suggestions, current: l.rows(), context: l.context())
    var review: [String: Bool] = [:]
    var tags: [String: String] = [:]
    for op in blobs.flatMap(\.ops) {
      let id = try #require(op.entity?.id)
      review[id] = op.payload["needs_review"]?.boolValue
      tags[id] = op.payload["source"]?.objectValue?["model"]?.stringValue
    }
    #expect(review == [ids[0]: false, ids[1]: true, ids[2]: false, ids[3]: true, ids[4]: false])
    #expect(tags[ids[3]] == "apple-fm/26.1" && tags[ids[0]] == "cf-clef/1" && tags[ids[2]] == "cf-clef/1")
    for b in blobs { try l.fold(b) }
    let filed = try #require(l.state.txns[ids[0]])
    #expect(filed.category == "groceries" && !filed.needsReview && filed.categorySource == CategorySource(kind: .model, model: "cf-clef/1"))
    #expect(ReviewQueue.lane(filed) == nil)
    #expect(ReviewQueue.lane(try #require(l.state.txns[ids[1]])) == .needsReview)
    #expect(ReviewQueue.lane(try #require(l.state.txns[ids[3]])) == .needsReview)
  }

  @Test("a confident cloud answer never clears a review the mail trust gates set")
  func gateReviewStays() async throws {
    var l = T.Ledger()
    let gated = try l.ingest([("SURE SHOP", "debit")], needsReview: true)[0]
    let trusted = try l.ingest([("SURE SHOP", "debit")], needsReview: false)[0]
    let cloud = GradedCloud("cf-clef/1", ["sure shop": (.category("groceries"), true)])
    let suggestions = try await ModelSuggestionSweep.suggest(
      rows: l.rows(), categorizer: T.categorizer, allowed: T.allowed, stages: [.cloud(cloud)], context: .foreground,
      cache: MemoryCache(), now: { now })
    #expect(suggestions.allSatisfy { !$0.needsReview })
    let blobs = try ModelSuggestionSweep.author(suggestions, current: l.rows(), context: l.context())
    var review: [String: Bool] = [:]
    for op in blobs.flatMap(\.ops) { review[try #require(op.entity?.id)] = op.payload["needs_review"]?.boolValue }
    #expect(review == [gated: true, trusted: false])
    for b in blobs { try l.fold(b) }
    let held = try #require(l.state.txns[gated])
    #expect(held.category == "groceries" && held.needsReview)
    #expect(ReviewQueue.lane(held) == .needsReview)
  }

  @Test("autoFile counts only for a cf-clef tag, and a plain model's suggestion is always reviewed")
  func flags() {
    let s = { (tag: String, auto: Bool) in ModelSuggestionSweep.Suggestion(txnID: "t", version: 1, category: "dining", modelTag: tag, autoFile: auto) }
    #expect(!s("cf-clef/1", true).needsReview)
    #expect(s("cf-clef/1", false).needsReview)
    #expect(s("apple-fm/26.1", true).needsReview)
    #expect(s("apple-fm/26.1", false).needsReview)
  }

  @Test("review lanes: a filed model row leaves review only for a cf-clef tag")
  func lanes() throws {
    var l = T.Ledger()
    let id = try l.ingest([("LANE SHOP", "debit")])[0]
    var t = try #require(l.state.txns[id])
    t.category = "dining"
    t.needsReview = false
    t.categorySource = CategorySource(kind: .model, model: "apple-fm/26.1")
    #expect(ReviewQueue.lane(t) == .uncategorized)
    t.categorySource = CategorySource(kind: .model, model: "cf-clef/1")
    #expect(ReviewQueue.lane(t) == nil)
    t.categorySource = CategorySource(kind: .model, model: nil)
    #expect(ReviewQueue.lane(t) == .uncategorized)
    t.needsReview = true
    t.categorySource = CategorySource(kind: .model, model: "cf-clef/1")
    #expect(ReviewQueue.lane(t) == .needsReview)
  }
}
