import CoreMailbox
import CoreTestSupport
import Foundation
import Testing

@Suite struct ProviderPauseTests {
  let t0 = OutlookRig.t0
  let day: Int64 = 86_400_000

  func activeRig() async -> OutlookRig {
    let rig = OutlookRig()
    rig.graph.add(SyntheticOutlookMail.dibCard(id: "AAkALgAA-d1", dateMs: t0 - day))
    await rig.connectAndActivate()
    #expect(await rig.state().phase == .active)
    rig.graph.add(SyntheticOutlookMail.dibCard(id: "AAkALgAA-d2", amount: "2.00", dateMs: t0 - 1000))
    return rig
  }

  func pausedRig() async -> OutlookRig {
    let rig = await activeRig()
    rig.graph.fail("/$value", with: [429], retryAfter: 30)
    let r = await rig.engine.runCycle(trigger: .launch)
    #expect(r.haltedOn == .gmail && !r.completed)
    return rig
  }

  @Test func aViewOrAProbeWaitsForThePause() async {
    let rig = await pausedRig()
    let requests = rig.graph.requests.count
    #expect(await rig.engine.viewEmail(messageID: "AAkALgAA-d1") == .offline)
    #expect(await rig.engine.probeSenders(["dib.ae"]) == .offline)
    #expect(rig.graph.requests.count == requests)
    rig.clock.advance(31_000)
    if case .ready = await rig.engine.viewEmail(messageID: "AAkALgAA-d1") {} else { Issue.record("not ready after the pause") }
  }

  @Test func anImportStaysPendingUntilThePauseHasPassed() async throws {
    let rig = await pausedRig()
    let requests = rig.graph.requests.count
    let report = await rig.engine.backfill(senders: ["alerts.dib.ae"])
    #expect(report.haltedOn == .gmail && !report.completed)
    #expect(rig.graph.requests.count == requests)
    #expect(try await rig.store.pendingImports().map(\.domain) == ["alerts.dib.ae"])
    rig.clock.advance(31_000)
    let later = await rig.engine.runCycle(trigger: .launch)
    #expect(later.completed && later.haltedOn == nil)
    #expect(try await rig.store.pendingImports().isEmpty)
  }

  @Test func addingASenderKeepsItsImportForAfterThePause() async throws {
    let rig = await pausedRig()
    let requests = rig.graph.requests.count
    let out = await rig.engine.importSender("alerts@bank.example")
    guard case .success(let report) = out else {
      Issue.record("refused: \(out)")
      return
    }
    #expect(report.haltedOn == .gmail && !report.completed)
    #expect(rig.graph.requests.count == requests)
    #expect(try await rig.store.pendingImports().map(\.domain) == ["bank.example"])
  }

  @Test func importingPastMailKeepsItsImportForAfterThePause() async throws {
    let rig = OutlookRig()
    rig.graph.add(SyntheticOutlookMail.dibCard(id: "AAkALgAA-d1", dateMs: t0 - 1000))
    _ = await rig.engine.connect(
      presenter: OutlookPresenter(graph: rig.graph), backfillDays: 90, pastMail: .skip(catchUpFromMs: nil))
    rig.clock.advance(60_000)
    rig.graph.add(SyntheticOutlookMail.dibCard(id: "AAkALgAA-d2", amount: "2.00", dateMs: t0 + 30_000))
    rig.graph.fail("/$value", with: [429], retryAfter: 30)
    #expect(await rig.engine.runCycle(trigger: .launch).haltedOn == .gmail)
    let requests = rig.graph.requests.count
    let report = await rig.engine.importPastMail()
    #expect(report.haltedOn == .gmail && !report.completed)
    #expect(rig.graph.requests.count == requests)
    #expect(try await !rig.store.pendingImports().isEmpty)
    #expect(await rig.state().readFromMs == nil)
  }

  @Test func aPauseNamedToAViewHoldsTheNextCycle() async {
    let rig = await activeRig()
    rig.graph.fail("/$value", with: [429], retryAfter: 30)
    #expect(await rig.engine.viewEmail(messageID: "AAkALgAA-d1") == .offline)
    let requests = rig.graph.requests.count
    #expect(await rig.engine.runCycle(trigger: .launch).haltedOn == .gmail)
    #expect(rig.graph.requests.count == requests)
  }

  @Test func aPauseNamedToAProbeHoldsTheNextCycle() async {
    let rig = await activeRig()
    rig.graph.fail("/messages", with: [429], retryAfter: 30)
    #expect(await rig.engine.probeSenders(["dib.ae"]) == .offline)
    let requests = rig.graph.requests.count
    #expect(await rig.engine.runCycle(trigger: .launch).haltedOn == .gmail)
    #expect(rig.graph.requests.count == requests)
  }

  @Test func aClockThatWentBackDoesNotLengthenThePause() async {
    let rig = await pausedRig()
    rig.clock.set(t0 - 3_600_000)
    let r = await rig.engine.runCycle(trigger: .launch)
    #expect(r.completed && r.haltedOn == nil)
  }
}
