import Foundation
import Synchronization
import Testing

@testable import CoreCategorize

final class StageFake: CategoryModel, Sendable {
  let modelTag: String
  let state: ModelAvailability
  let answers: [String: ModelAnswer]
  let fallback: ModelAnswer
  let log = Mutex<[String]>([])

  init(_ tag: String, state: ModelAvailability = .available, answers: [String: ModelAnswer] = [:], fallback: ModelAnswer = .unknown) {
    modelTag = tag
    self.state = state
    self.answers = answers
    self.fallback = fallback
  }

  func availability() -> ModelAvailability { state }

  func suggest(subject: String, allowed: [AllowedCategory]) async -> ModelAnswer {
    log.withLock { $0.append(subject) }
    return answers[subject] ?? fallback
  }

  var calls: [String] { log.withLock { $0 } }
}

@Suite("CoreCategorize: model stages")
struct ModelStageTests {
  static let allowed = ModelTier.allowed(TaxonomyV1.builtins)
  static let latin = "cafe example jbr"
  static let arabic = "مطعم الياسمين الشعبي"

  @Test("stage gates: on-device is Latin-only, cloud takes any subject with a letter")
  func gates() {
    let device = ModelStage.onDevice(StageFake("apple-fm/26.1"))
    let cloud = ModelStage.cloud(StageFake("cf-clef/1"))
    #expect(device.accepts(Self.latin) && !device.accepts(Self.arabic))
    #expect(cloud.accepts(Self.latin) && cloud.accepts(Self.arabic) && cloud.accepts("x"))
    #expect(!cloud.accepts("12345") && !cloud.accepts("") && !cloud.accepts("🍕 42"))
    #expect(cloud.accepts("٧-١١ ب"))
  }

  @Test("Latin goes on-device first; Arabic skips on-device and goes to cloud; first answer wins")
  func routing() async {
    let device = StageFake("apple-fm/26.1", answers: [Self.latin: .category("dining")])
    let cloud = StageFake("cf-clef/1", fallback: .category("groceries"))
    let r = await ModelTier.run(
      subjects: [Self.latin, Self.arabic, Self.latin], stages: [.onDevice(device), .cloud(cloud)], allowed: Self.allowed, context: .foreground,
      now: { 0 })
    #expect(
      r.suggestions == [
        .init(subject: Self.latin, category: "dining", modelTag: "apple-fm/26.1"),
        .init(subject: Self.arabic, category: "groceries", modelTag: "cf-clef/1"),
      ])
    #expect(r.unknown.isEmpty && r.stoppedBy.isEmpty)
    #expect(device.calls == [Self.latin])
    #expect(cloud.calls == [Self.arabic])
  }

  @Test("unknown, guardrail, refusal and an answer outside the set fall through and are recorded per stage")
  func fallThrough() async {
    let device = StageFake(
      "apple-fm/26.1",
      answers: ["a shop": .unknown, "b shop": .failed(.guardrail), "c shop": .failed(.refusal), "d shop": .category("salary"), "e shop": .failed(.decoding)])
    let cloud = StageFake("cf-clef/1", answers: ["b shop": .unknown], fallback: .category("shopping"))
    let r = await ModelTier.run(
      subjects: ["a shop", "b shop", "c shop", "d shop", "e shop"], stages: [.onDevice(device), .cloud(cloud)], allowed: Self.allowed,
      context: .foreground, now: { 0 })
    #expect(r.suggestions.map(\.subject) == ["a shop", "c shop", "d shop", "e shop"])
    #expect(r.suggestions.allSatisfy { $0.modelTag == "cf-clef/1" && $0.category == "shopping" })
    #expect(r.unknown.map { "\($0.subject)|\($0.modelTag)" } == [
      "a shop|apple-fm/26.1", "b shop|apple-fm/26.1", "b shop|cf-clef/1", "c shop|apple-fm/26.1", "d shop|apple-fm/26.1",
    ])
  }

  @Test("a rate-limited stage is disabled for the rest of the run; the others continue")
  func disable() async {
    let device = StageFake("apple-fm/26.1", answers: ["first one": .failed(.rateLimited)], fallback: .category("dining"))
    let cloud = StageFake("cf-clef/1", fallback: .category("travel"))
    let r = await ModelTier.run(
      subjects: ["first one", "second one", Self.arabic], stages: [.onDevice(device), .cloud(cloud)], allowed: Self.allowed,
      context: .foreground, now: { 0 })
    #expect(r.stoppedBy == ["apple-fm/26.1": .rateLimited])
    #expect(device.calls == ["first one"])
    #expect(cloud.calls == ["first one", "second one", Self.arabic])
    #expect(r.suggestions.map(\.modelTag) == ["cf-clef/1", "cf-clef/1", "cf-clef/1"])
    for f in [ModelFailure.busy, .unsupportedLanguage, .assetsUnavailable] {
      let only = StageFake("cf-clef/1", fallback: .failed(f))
      let s = await ModelTier.run(subjects: ["x shop", "y shop"], stages: [.cloud(only)], allowed: Self.allowed, context: .foreground, now: { 0 })
      #expect(s.stoppedBy == ["cf-clef/1": f] && only.calls == ["x shop"])
    }
  }

  @Test("the call budget is shared across stages")
  func sharedBudget() async {
    let device = StageFake("apple-fm/26.1")
    let cloud = StageFake("cf-clef/1")
    let subjects = (0..<30).map { "shop number \($0)" }
    let r = await ModelTier.run(subjects: subjects, stages: [.onDevice(device), .cloud(cloud)], allowed: Self.allowed, context: .foreground, now: { 0 })
    #expect(device.calls.count + cloud.calls.count == 40)
    #expect(device.calls.count == 20 && cloud.calls.count == 20)
    #expect(r.unknown.count == 40)
  }

  @Test("a cloud cap limits only the calls that leave the device; on-device still runs")
  func cloudCap() async {
    let device = StageFake("apple-fm/26.1")
    let cloud = StageFake("cf-clef/1")
    let subjects = ["one shop", "two shop", "three shop"]
    let r = await ModelTier.run(
      subjects: subjects, stages: [.cloud(cloud), .onDevice(device)], allowed: Self.allowed, context: .foreground, now: { 0 },
      maxCloudCalls: 1)
    #expect(cloud.calls == ["one shop"] && r.cloudRequests == 1)
    #expect(device.calls == subjects && r.requests == 4)
    let none = StageFake("cf-clef/1")
    let device2 = StageFake("apple-fm/26.1")
    let z = await ModelTier.run(
      subjects: subjects, stages: [.cloud(none), .onDevice(device2)], allowed: Self.allowed, context: .foreground, now: { 0 },
      maxCloudCalls: 0)
    #expect(none.calls.isEmpty && z.cloudRequests == 0 && device2.calls == subjects)
    let alone = StageFake("cf-clef/1")
    let c = await ModelTier.run(
      subjects: subjects, stages: [.cloud(alone)], allowed: Self.allowed, context: .backlog, now: { 0 }, maxCloudCalls: 2, concurrency: 3)
    #expect(alone.calls.count == 2 && c.cloudRequests == 2)
  }

  @Test("the phase budget is shared across stages")
  func phaseBudget() async {
    let clock = Mutex<Int64>(0)
    let device = StageFake("apple-fm/26.1")
    let cloud = StageFake("cf-clef/1")
    let r = await ModelTier.run(
      subjects: ["one shop", "two shop", "three shop"], stages: [.onDevice(device), .cloud(cloud)], allowed: Self.allowed, context: .foreground,
      now: { clock.withLock { t in
        defer { t += 7_000 }
        return t
      } })
    #expect(device.calls.count + cloud.calls.count == 2)
    #expect(r.unknown.count == 2)
  }

  @Test("refresh calls nothing; unavailable stages are skipped")
  func refreshAndAvailability() async {
    let device = StageFake("apple-fm/26.1", fallback: .category("dining"))
    let cloud = StageFake("cf-clef/1", fallback: .category("dining"))
    let none = await ModelTier.run(
      subjects: [Self.latin, Self.arabic], stages: [.onDevice(device), .cloud(cloud)], allowed: Self.allowed, context: .refresh, now: { 0 })
    #expect(none.suggestions.isEmpty && none.unknown.isEmpty && device.calls.isEmpty && cloud.calls.isEmpty)
    let off = StageFake("apple-fm/26.1", state: .notEnabled, fallback: .category("dining"))
    let r = await ModelTier.run(subjects: [Self.latin], stages: [.onDevice(off), .cloud(cloud)], allowed: Self.allowed, context: .foreground, now: { 0 })
    #expect(off.calls.isEmpty && r.suggestions == [.init(subject: Self.latin, category: "dining", modelTag: "cf-clef/1")])
    let empty = await ModelTier.run(subjects: [Self.latin], stages: [], allowed: Self.allowed, context: .foreground, now: { 0 })
    #expect(empty.suggestions.isEmpty)
  }

  @Test("a cache hit skips that stage only")
  func cacheHit() async {
    let device = StageFake("apple-fm/26.1", fallback: .category("dining"))
    let cloud = StageFake("cf-clef/1", fallback: .category("groceries"))
    let r = await ModelTier.run(
      subjects: [Self.latin, "other shop"], stages: [.onDevice(device), .cloud(cloud)], allowed: Self.allowed, context: .foreground, now: { 0 },
      isCached: { s, tag in s == Self.latin && tag == "apple-fm/26.1" })
    #expect(device.calls == ["other shop"] && cloud.calls == [Self.latin])
    #expect(r.suggestions == [
      .init(subject: Self.latin, category: "groceries", modelTag: "cf-clef/1"), .init(subject: "other shop", category: "dining", modelTag: "apple-fm/26.1"),
    ])
  }

  @Test("a subject that may not leave the device skips the cloud stage only")
  func staysOnDevice() async {
    let device = StageFake("apple-fm/26.1")
    let cloud = StageFake("cf-clef/1", fallback: .category("groceries"))
    #expect(ModelStage.cloud(cloud).leavesDevice && !ModelStage.onDevice(device).leavesDevice)
    let r = await ModelTier.run(
      subjects: [Self.latin, Self.arabic, "other shop"], stages: [.cloud(cloud), .onDevice(device)], allowed: Self.allowed,
      context: .foreground, now: { 0 },
      mayLeaveDevice: { $0 == "other shop" })
    #expect(cloud.calls == ["other shop"] && device.calls == [Self.latin])
    #expect(r.suggestions == [.init(subject: "other shop", category: "groceries", modelTag: "cf-clef/1")])
  }

  @Test("the single-model wrapper keeps its Latin gate and stop")
  func wrapper() async {
    let m = StageFake("apple-fm/26.1", answers: ["b shop": .failed(.busy)], fallback: .category("dining"))
    let r = await ModelTier.run(subjects: [Self.arabic, "a shop", "b shop", "c shop"], model: m, allowed: Self.allowed, context: .foreground, now: { 0 })
    #expect(r.suggestions == [.init(subject: "a shop", category: "dining")])
    #expect(r.stoppedBy == .busy && m.calls == ["a shop", "b shop"])
  }

  @Test("a call that found the app off screen is not counted, and no later call starts")
  func offScreenStopsTheRun() async {
    let cloud = StageFake("cf-clef/1", answers: ["b shop": .failed(.offScreen)], fallback: .category("shopping"))
    let r = await ModelTier.run(
      subjects: ["a shop", "b shop", "c shop"], stages: [.cloud(cloud)], allowed: Self.allowed, context: .foreground, now: { 0 })
    #expect(cloud.calls == ["a shop", "b shop"])
    #expect(r.suggestions.map(\.subject) == ["a shop"])
    #expect(r.asked.map(\.subject) == ["a shop"])
    #expect(r.requests == 1 && r.cloudRequests == 1 && r.cutShort)
    #expect(r.failed.isEmpty && r.unknown.isEmpty && r.stoppedBy.isEmpty)
  }

  @Test("concurrent calls that found the app off screen are not counted, and no more start")
  func offScreenStopsTheConcurrentRun() async {
    let cloud = StageFake("cf-clef/1", fallback: .failed(.offScreen))
    let r = await ModelTier.run(
      subjects: ["a shop", "b shop", "c shop", "d shop", "e shop"], stages: [.cloud(cloud)], allowed: Self.allowed, context: .backlog,
      now: { 0 }, concurrency: 3)
    #expect(cloud.calls.count <= 3)
    #expect(r.asked.isEmpty && r.requests == 0 && r.cloudRequests == 0 && r.cutShort)
    #expect(r.failed.isEmpty && r.unknown.isEmpty && r.stoppedBy.isEmpty)
  }

  @Test("no call starts once mayAsk turns false")
  func mayAskStopsTheRun() async {
    let device = StageFake("apple-fm/26.1")
    let r = await ModelTier.run(
      subjects: ["a shop", "b shop", "c shop"], stages: [.onDevice(device)], allowed: Self.allowed, context: .foreground, now: { 0 },
      mayAsk: { device.calls.isEmpty })
    #expect(device.calls == ["a shop"])
    #expect(r.requests == 1 && r.asked.map(\.subject) == ["a shop"] && r.cutShort)
    let none = await ModelTier.run(
      subjects: ["a shop"], stages: [.onDevice(device)], allowed: Self.allowed, context: .foreground, now: { 0 }, concurrency: 3,
      mayAsk: { false })
    #expect(device.calls == ["a shop"] && none.requests == 0 && none.cutShort)
    let done = await ModelTier.run(
      subjects: ["z shop"], stages: [.onDevice(device)], allowed: Self.allowed, context: .foreground, now: { 0 },
      mayAsk: { !device.calls.contains("z shop") })
    #expect(done.requests == 1 && !done.cutShort)
  }
}
