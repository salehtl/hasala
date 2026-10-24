import CoreCategorize
import CoreDomain
import CoreJSON
import CoreStore
import Foundation
import Synchronization
import Testing

@testable import Hasala

@Suite("Model suggestion stage")
struct ModelSuggestionStageTests {
  struct Fake: CategoryModel {
    let modelTag: String
    let state: ModelAvailability
    func availability() -> ModelAvailability { state }
    func suggest(subject: String, allowed: [AllowedCategory]) async -> ModelAnswer { .unknown }
  }

  let apple = Fake(modelTag: "apple-fm/27.1", state: .available)

  @Test func clefRunsFirstWhenTheSwitchIsOn() {
    let stages = ModelSuggestionStage.stages(
      onDevice: apple, cloud: Fake(modelTag: "cf-clef/1", state: .available), onDeviceAlone: false)
    #expect(stages.map(\.model.modelTag) == ["cf-clef/1", "apple-fm/27.1"])
    #expect(stages[0].accepts("مطعم الياسمين الشعبي"))
    #expect(!stages[1].accepts("مطعم الياسمين الشعبي"))
  }

  @Test func noModelRunsInReleaseWhenTheSwitchIsOff() {
    let off = Fake(modelTag: "cf-clef/1", state: .notEnabled)
    #expect(ModelSuggestionStage.stages(onDevice: apple, cloud: off, onDeviceAlone: false).isEmpty)
    #expect(ModelSuggestionStage.stages(onDevice: apple, cloud: nil, onDeviceAlone: false).isEmpty)
  }

  @Test func debugRunsTheOnDeviceModelAloneWhenTheSwitchIsOff() {
    let off = Fake(modelTag: "cf-clef/1", state: .notEnabled)
    #expect(ModelSuggestionStage.stages(onDevice: apple, cloud: off, onDeviceAlone: true).map(\.model.modelTag) == ["apple-fm/27.1"])
    #expect(ModelSuggestionStage.stages(onDevice: apple, cloud: nil, onDeviceAlone: true).map(\.model.modelTag) == ["apple-fm/27.1"])
  }

  @Test func applesModelRunsWhenTheSwitchIsOnButTheServiceRefusedThisVersion() {
    let refused = Fake(modelTag: "cf-clef/1", state: .notEligible)
    #expect(
      ModelSuggestionStage.stages(onDevice: apple, cloud: refused, onDeviceAlone: false).map(\.model.modelTag) == ["apple-fm/27.1"])
    #expect(
      ModelSuggestionStage.stages(onDevice: apple, cloud: refused, onDeviceAlone: true).map(\.model.modelTag) == ["apple-fm/27.1"])
  }

  nonisolated final class Counting: CategoryModel, Sendable {
    let modelTag: String
    let answer: ModelAnswer
    let log = Mutex<[String]>([])
    init(_ tag: String, answer: ModelAnswer) {
      modelTag = tag
      self.answer = answer
    }
    func availability() -> ModelAvailability { .available }
    func suggest(subject: String, allowed: [AllowedCategory]) async -> ModelAnswer {
      log.withLock { $0.append(subject) }
      return answer
    }
    var calls: [String] { log.withLock { $0 } }
  }

  @MainActor
  static func waiting(_ a: LiveLedgerMapperTests.Account, suite: String) async throws -> [String] {
    var ids: [String] = []
    var blobs: [AuthoredBlob] = []
    let merchants = [("QWERTY BISTRO", "10:00:00", "4100", "3"), ("ASDF GRILL", "12:00:00", "5200", "4"),
                     ("ZXCV NOODLES", "14:00:00", "6300", "5")]
    if let b = try a.observer.stamps.build(try await a.observer.authorContext(), { o throws(AuthorError) in
      for (i, m) in merchants.enumerated() {
        var row = LiveUndoTests.alert(grant: "u/mbx-a", message: "w\(i)", at: m.1, merchant: m.0, minor: m.2)
        row["category"] = .null
        row["category_source"] = nil
        row["needs_review"] = .bool(true)
        row["gates"] = .object(JSONObject([
          ("ar", .string("pass")), ("sender", .string("trusted")), ("template", .string("dib.card.v1@1")), ("card", .string("known")),
          ("forwarded", .bool(false)),
        ]))
        ids.append(try o.ingest(payload: row, ingestID: String(repeating: m.3, count: 64)))
      }
    }) { blobs.append(b) }
    _ = try await LiveUndoTests.store(a, suite: suite, extra: blobs)
    return ids
  }

  @MainActor
  @Test func theForegroundSweepSpendsTheSharedDayBudgetAndSkipsClefWhenNoneIsLeft() async throws {
    let a = try LiveLedgerMapperTests.account()
    _ = try await Self.waiting(a, suite: "stage.budget.tests")
    let anchor = LiveLedgerMapperTests.anchor
    let budget = Mutex(0)
    let spent = Mutex<[Int]>([])
    let device = Counting("apple-fm/27.1", answer: .unknown)
    let cloud = Counting("cf-clef/1", answer: .unknown)
    let stage = ModelSuggestionStage(
      observer: a.observer, outbox: a.outbox, cache: FMCache(a.context.store), dictionary: AccountRuntime.dictionary,
      onDevice: device, cloud: cloud, onDeviceAlone: false, nowMs: { anchor },
      cloudBudget: { budget.withLock { $0 } }, cloudSpent: { n in spent.withLock { $0.append(n) } })
    _ = await stage.run(.foreground)
    #expect(cloud.calls.isEmpty)
    #expect(device.calls.count >= 3)
    #expect(spent.withLock { $0 }.isEmpty)
    budget.withLock { $0 = 2 }
    _ = await stage.run(.foreground)
    #expect(cloud.calls.count == 2 && spent.withLock { $0 } == [2])
  }

  @MainActor
  @Test func theBackgroundStageWaitsOnlyForNamesCloudflareMayStillBeAsked() async throws {
    let a = try LiveLedgerMapperTests.account()
    _ = try await Self.waiting(a, suite: "stage.waiting.tests")
    let anchor = LiveLedgerMapperTests.anchor
    let cloud = Counting("cf-clef/1", answer: .unknown)
    func stage(_ cloud: (any CategoryModel)?) -> ModelSuggestionStage {
      ModelSuggestionStage(
        observer: a.observer, outbox: a.outbox, cache: FMCache(a.context.store), dictionary: AccountRuntime.dictionary,
        onDevice: Counting("apple-fm/27.1", answer: .unknown), cloud: cloud, onDeviceAlone: false, nowMs: { anchor })
    }
    #expect(await stage(cloud).backlogWaiting(BacklogSort.Memo()))
    #expect(await !stage(nil).backlogWaiting(BacklogSort.Memo()))
    #expect(await !stage(Fake(modelTag: "cf-clef/1", state: .notEnabled)).backlogWaiting(BacklogSort.Memo()))
    let r = await stage(cloud).backlogPass(BacklogSort.Memo(), dayLeft: 100)
    #expect(r?.pass.calls == 3 && cloud.calls.count == 3)
    #expect(await !stage(cloud).backlogWaiting(BacklogSort.Memo()))
    #expect(cloud.calls.count == 3)
  }

  @Test func onlyForegroundTriggersRunTheSweep() {
    let runs = WorkCoordinator.Trigger.allCases.filter(ModelSuggestionStage.runs)
    #expect(Set(runs) == [.launch, .foreground, .refresh])
  }
}
