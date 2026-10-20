import Foundation
import Synchronization
import Testing

@testable import CoreCategorize

final class GradedFake: GradedCategoryModel, Sendable {
  let modelTag: String
  let graded: [String: (answer: ModelAnswer, autoFile: Bool)]
  let plainCalls = Mutex(0)

  init(_ tag: String, _ graded: [String: (answer: ModelAnswer, autoFile: Bool)]) {
    modelTag = tag
    self.graded = graded
  }

  func availability() -> ModelAvailability { .available }

  func suggest(subject: String, allowed: [AllowedCategory]) async -> ModelAnswer {
    plainCalls.withLock { $0 += 1 }
    return .unknown
  }

  func suggestGraded(subject: String, allowed: [AllowedCategory]) async -> (answer: ModelAnswer, autoFile: Bool) {
    graded[subject] ?? (.unknown, true)
  }
}

@Suite("CoreCategorize: graded model stages")
struct GradedStageTests {
  static let allowed = ModelTier.allowed(TaxonomyV1.builtins)

  @Test("a graded model is asked through suggestGraded; autoFile is kept only with an allowed category")
  func graded() async {
    let device = StageFake("apple-fm/26.1", fallback: .category("dining"))
    let cloud = GradedFake(
      "cf-clef/1",
      [
        "sure shop": (.category("groceries"), true), "unsure shop": (.category("groceries"), false), "odd shop": (.category("salary"), true),
      ])
    let r = await ModelTier.run(
      subjects: ["sure shop", "unsure shop", "odd shop", "nothing shop", "cafe latin"], stages: [.cloud(cloud), .onDevice(device)],
      allowed: Self.allowed, context: .foreground, now: { 0 })
    #expect(cloud.plainCalls.withLock { $0 } == 0)
    #expect(
      r.suggestions == [
        .init(subject: "sure shop", category: "groceries", modelTag: "cf-clef/1", autoFile: true),
        .init(subject: "unsure shop", category: "groceries", modelTag: "cf-clef/1", autoFile: false),
        .init(subject: "odd shop", category: "dining", modelTag: "apple-fm/26.1", autoFile: false),
        .init(subject: "nothing shop", category: "dining", modelTag: "apple-fm/26.1", autoFile: false),
        .init(subject: "cafe latin", category: "dining", modelTag: "apple-fm/26.1", autoFile: false),
      ])
    #expect(r.unknown.map(\.subject) == ["odd shop", "nothing shop", "cafe latin"])
  }

  @Test("a graded model that hangs still times out")
  func gradedTimeout() async {
    final class Hangs: GradedCategoryModel, Sendable {
      let modelTag = "cf-clef/1"
      func availability() -> ModelAvailability { .available }
      func suggest(subject: String, allowed: [AllowedCategory]) async -> ModelAnswer { .unknown }
      func suggestGraded(subject: String, allowed: [AllowedCategory]) async -> (answer: ModelAnswer, autoFile: Bool) {
        try? await Task.sleep(for: .seconds(30))
        return (.category("dining"), true)
      }
    }
    let r = await ModelTier.run(
      subjects: ["slow shop"], stages: [.cloud(Hangs())], allowed: Self.allowed, context: .foreground, now: { 0 }, callTimeout: .milliseconds(100))
    #expect(r.suggestions.isEmpty && r.unknown.isEmpty)
  }

  @Test("only cf-clef tags may auto-file; a plain suggestion never auto-confirms")
  func prefix() {
    #expect(ModelTier.mayAutoFile(modelTag: "cf-clef/1") && !ModelTier.mayAutoFile(modelTag: "apple-fm/26.1"))
    #expect(!ModelTier.autoConfirm)
  }
}
