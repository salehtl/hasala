import CoreAuth
import CoreCrypto
import CoreJSON
import CorePrimitives
import CoreSoftAuth
import CoreTestSupport
import CoreWire
import Foundation
import Testing
import os

@testable import CoreSync

private final class OnFold: PageObserver, Sendable {
  private let calls = OSAllocatedUnfairLock(initialState: 0)
  private let act: @Sendable (Int) throws -> Void

  init(_ act: @escaping @Sendable (Int) throws -> Void) { self.act = act }

  func fold(_ rows: [PulledRow]) async throws(SyncStop) -> FoldSnapshotChange {
    let n = calls.withLock { c -> Int in
      c += 1
      return c
    }
    do { try act(n) } catch { throw .cancelled }
    return .keep
  }
}

@Suite("Pull: a removed writer's rows that stop short of its pin")
struct ShortChainAlarmTests {
  func twoPhones() async throws -> (World, SyncContext, SyncContext) { try await PagePlaintextTests().twoPhones() }
  func alone(_ i: Int) -> Op { PagePlaintextTests().alone(i) }

  func pin(_ c: SyncContext, _ writer: WriterID, at counter: Int64, head: Data = Data(repeating: 9, count: 32)) throws {
    let stored = try #require(try c.store.syncState().rosterJSON)
    var o = try #require(try JSONSerialization.jsonObject(with: stored) as? [String: Any])
    var writers = try #require(o["writers"] as? [String: [String: Any]])
    writers[writer.string]?["final_counter"] = counter
    writers[writer.string]?["final_head"] = head.base64EncodedString()
    o["writers"] = writers
    try c.store.setRoster(try JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]))
  }

  func alarms(_ c: SyncContext) throws -> [String] {
    try c.store.foldEvents().filter { $0.kind == "integrity_alarm" }.map(\.detail)
  }

  func detail(_ w: WriterID, _ counter: Int64) -> String { "short_of_final_\(w.string)_\(counter)" }

  @Test("a pull that ends on rows records one alarm, and later pulls add none")
  func endsOnRows() async throws {
    let (_, a, b) = try await twoPhones()
    try enqueue(a, (1...2).map(alone))
    #expect(await SyncEngine(context: a).run(.authored).stop == nil)
    try pin(b, a.writerID, at: 5)

    let out = try await Puller.pull(b, observer: nil)
    #expect(out.rowsStored == 2 && out.alarms == 0)
    #expect(try alarms(b) == [detail(a.writerID, 5)])

    #expect(try await Puller.pull(b, observer: nil).rowsStored == 0)
    #expect(try alarms(b) == [detail(a.writerID, 5)])
  }

  @Test("a pull that ends on an empty page records one alarm, and later pulls add none")
  func endsOnEmptyPage() async throws {
    let (_, a, b) = try await twoPhones()
    try enqueue(a, (1...2).map(alone))
    #expect(await SyncEngine(context: a).run(.authored).stop == nil)
    #expect(try await Puller.pull(b, observer: nil).rowsStored == 2)
    #expect(try alarms(b).isEmpty)

    try pin(b, a.writerID, at: 5)
    for _ in 0..<3 {
      #expect(try await Puller.pull(b, observer: nil).rowsStored == 0)
      #expect(try alarms(b) == [detail(a.writerID, 5)])
    }
  }

  @Test("rows that reach the pin raise nothing")
  func reachedThePin() async throws {
    let (_, a, b) = try await twoPhones()
    try enqueue(a, (1...2).map(alone))
    #expect(await SyncEngine(context: a).run(.authored).stop == nil)
    #expect(try await Puller.pull(b, observer: nil).rowsStored == 2)
    let head = try #require(try b.store.chainHeads()[a.writerID])
    try pin(b, a.writerID, at: head.counter, head: head.hash.bytes)

    #expect(try await Puller.pull(b, observer: nil).rowsStored == 0)
    #expect(try alarms(b).isEmpty)
  }

  @Test("a pin that lands during a pull is judged on the next pull, not this one")
  func pinDuringThePull() async throws {
    let (_, a, b) = try await twoPhones()
    try enqueue(a, (1...2).map(alone))
    #expect(await SyncEngine(context: a).run(.authored).stop == nil)
    let during = OnFold { _ in try self.pin(b, a.writerID, at: 5) }

    #expect(try await Puller.pull(b, observer: during).rowsStored == 2)
    #expect(try alarms(b).isEmpty)

    #expect(try await Puller.pull(b, observer: nil).rowsStored == 0)
    #expect(try alarms(b) == [detail(a.writerID, 5)])
  }

  @Test("a page the budget cut short does not end the pull: a stop on the rest records nothing")
  func cutShortThenStopped() async throws {
    let (_, a, b) = try await twoPhones()
    try enqueue(a, (1...2).map(alone))
    #expect(await SyncEngine(context: a).run(.authored).stop == nil)
    try pin(b, a.writerID, at: 5)
    struct Stop: Error {}
    let second = OnFold { if $0 == 2 { throw Stop() } }

    await #expect(throws: SyncStop.cancelled) { _ = try await Puller.pull(b, observer: second, plaintextBudget: 1) }
    #expect(try alarms(b).isEmpty)
  }

  @Test("a live writer and a pull that fails raise nothing")
  func liveAndFailed() async throws {
    let (w, a, b) = try await twoPhones()
    try enqueue(a, (1...2).map(alone))
    #expect(await SyncEngine(context: a).run(.authored).stop == nil)
    #expect(try await Puller.pull(b, observer: nil).rowsStored == 2)
    #expect(try alarms(b).isEmpty)

    try pin(b, a.writerID, at: 5)
    w.server.refuseNext("GET /api/v1/sync", status: 503, code: "unavailable")
    await #expect(throws: SyncStop.offline) { _ = try await Puller.pull(b, observer: nil) }
    #expect(try alarms(b).isEmpty)
  }

  @Test("after a removal whose last row the server no longer has, the other iPhone records one alarm and keeps syncing")
  func removalWithLostTail() async throws {
    let w = World()
    let phoneA = w.phone("a")
    let (account, words, a) = try await w.passwordAccount(phoneA)
    let phoneB = w.phone("b")
    let r = try await AccountSignIn.withPassword(phoneB.env, email: "maya@example.com", password: password, bound: nil)
    let body = try await Enrolment.unlockWithPhrase(phoneB.env, userID: account.userID, typed: words.joined(separator: " "))
    let b = Enrolment.context(
      phoneB.env,
      account: try await Enrolment.enrolWriter(
        phoneB.env, userID: account.userID, body: body, emailNorm: r.emailNorm, serverSalt: r.serverSalt))

    try enqueue(a, [alone(1), alone(2)])
    #expect(await SyncEngine(context: a).run(.authored).stop == nil)
    let kept = try a.store.syncState().cursorHot
    #expect(kept > 0)
    try enqueue(a, [alone(3)])
    #expect(await SyncEngine(context: a).run(.authored).stop == nil)
    #expect(w.server.storedRowCount(user: a.userID) == 3)
    try await AccountManagement.removeThisIPhone(
      phoneA.env, engine: SyncEngine(context: a), factor: .device(password: password), binding: try #require(phoneA.binding))
    w.server.loseLogTail(user: a.userID, after: kept)

    let engine = SyncEngine(context: b)
    let first = await engine.run(.launch)
    #expect(first.stop == nil && first.pulled.rowsStored == 2 && first.pulled.alarms == 0)
    #expect(try b.store.chainHeads()[a.writerID]?.counter == 2)
    #expect(try alarms(b) == [detail(a.writerID, 3)])

    #expect(await engine.run(.launch).stop == nil)
    try enqueue(b, [alone(4)])
    #expect(await engine.run(.authored).stop == nil)
    #expect(w.server.storedRowCount(user: a.userID) == 3)
    #expect(try alarms(b) == [detail(a.writerID, 3)])
  }
}
