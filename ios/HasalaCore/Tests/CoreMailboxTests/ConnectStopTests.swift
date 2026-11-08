import CoreMailbox
import CoreTestSupport
import Foundation
import Testing

final class Gate: @unchecked Sendable {
  private let lock = NSLock()
  private var opened = false
  private var arrived = false
  private var waiting: [CheckedContinuation<Void, Never>] = []

  func pass() async {
    await withCheckedContinuation { c in
      let go = lock.withLock { () -> Bool in
        arrived = true
        if opened { return true }
        waiting.append(c)
        return false
      }
      if go { c.resume() }
    }
  }

  var reached: Bool { lock.withLock { arrived } }

  func open() {
    let all = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
      opened = true
      defer { waiting = [] }
      return waiting
    }
    for c in all { c.resume() }
  }
}

@Suite struct ConnectStopTests {
  @Test func aConnectWaitingBehindACycleLeavesItsStopInPlace() async {
    let rig = Rig()
    await rig.connectAndActivate()
    rig.gmail.add(SyntheticMail.dibCard(id: "late", dateMs: rig.clock.nowMs() - 1000))
    let gate = Gate()
    await rig.ledger.setSyncGate { await gate.pass() }
    let cycle = Task { await rig.engine.runCycle(trigger: .refresh) }
    while !gate.reached { await Task.yield() }
    let stopping = Task { await rig.engine.stop() }
    while await !rig.engine.stopped { await Task.yield() }
    let connecting = Task { await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90) }
    for _ in 0..<500 { await Task.yield() }
    #expect(await rig.engine.stopped)
    gate.open()
    let report = await cycle.value
    await stopping.value
    #expect(await connecting.value == .connected(address: SyntheticMail.defaultTo))
    #expect(report.ops == 0)
    #expect(await rig.accounted("late") == nil)
    #expect(await !rig.engine.stopped)
  }
}
