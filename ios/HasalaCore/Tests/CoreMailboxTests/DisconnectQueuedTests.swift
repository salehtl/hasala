import CoreMailbox
import CoreTestSupport
import Foundation
import Testing

@Suite struct DisconnectQueuedTests {
  let day: Int64 = 86_400_000

  func queued(_ rig: Rig) async {
    var tries = 0
    while await rig.engine.disconnectsWaiting == 0, tries < 100_000 {
      await Task.yield()
      tries += 1
    }
    #expect(await rig.engine.disconnectsWaiting == 1)
  }

  func importingRig() async -> (Rig, Gate, Task<CycleReport, Never>) {
    let rig = Rig()
    _ = await rig.engine.connect(
      presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90, pastMail: .skip(catchUpFromMs: nil))
    rig.gmail.add(SyntheticMail.dibCard(id: "old", dateMs: Rig.t0 - 5 * day))
    rig.gmail.clearRequests()
    let gate = Gate()
    await rig.ledger.setSyncGate { await gate.pass() }
    let importing = Task { await rig.engine.importPastMail() }
    for _ in 0..<100_000 where !gate.reached { await Task.yield() }
    #expect(gate.reached)
    return (rig, gate, importing)
  }

  @Test func aDisconnectBehindAnImportIsNotKeptWaitingForTheMail() async throws {
    let (rig, gate, importing) = await importingRig()
    let disconnecting = Task { await rig.engine.disconnect(removing: nil) }
    await queued(rig)
    gate.open()
    let report = await importing.value
    #expect(!report.completed)
    #expect(await disconnecting.value == .disconnected)
    #expect(rig.rawRequests.isEmpty)
    #expect(await rig.state().phase == .unlinked)
    #expect(try await rig.store.pendingImports().isEmpty)
  }

  @Test func aDisconnectThatIsRefusedLeavesTheImportForALaterCycle() async throws {
    let (rig, gate, importing) = await importingRig()
    await rig.server.setOffline(true)
    let disconnecting = Task { await rig.engine.disconnect(removing: nil) }
    await queued(rig)
    gate.open()
    #expect(!(await importing.value).completed)
    #expect(await disconnecting.value == .failed)
    await rig.server.setOffline(false)
    #expect(try await !rig.store.pendingImports().isEmpty)
    let later = await rig.engine.runCycle(trigger: .launch)
    #expect(later.ops == 1)
    #expect(try await rig.store.pendingImports().isEmpty)
    #expect(await rig.accounted("old") == .op)
  }

  @Test func aDisconnectBehindACycleCutsItAtTheNextBoundary() async throws {
    let rig = Rig()
    await rig.connectAndActivate()
    rig.gmail.add(SyntheticMail.dibCard(id: "late", dateMs: rig.clock.nowMs() - 1000))
    rig.gmail.clearRequests()
    let gate = Gate()
    await rig.ledger.setSyncGate { await gate.pass() }
    let cycle = Task { await rig.engine.runCycle(trigger: .refresh) }
    while !gate.reached { await Task.yield() }
    let disconnecting = Task { await rig.engine.disconnect(removing: nil) }
    await queued(rig)
    gate.open()
    let report = await cycle.value
    #expect(!report.completed && report.ops == 0)
    #expect(await disconnecting.value == .disconnected)
    #expect(rig.rawRequests.isEmpty)
  }

  @Test func onceTheDisconnectHasEndedAnImportRunsAgain() async throws {
    let (rig, gate, importing) = await importingRig()
    await rig.server.setOffline(true)
    let disconnecting = Task { await rig.engine.disconnect(removing: nil) }
    await queued(rig)
    gate.open()
    _ = await importing.value
    _ = await disconnecting.value
    await rig.server.setOffline(false)
    let later = await rig.engine.backfill(senders: ["dib.ae"])
    #expect(later.completed && later.ops == 1)
  }
}
