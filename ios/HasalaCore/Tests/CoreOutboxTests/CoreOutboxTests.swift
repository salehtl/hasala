// Unit tests for CoreOutbox (owner: WS-11): durable, validated enqueue and
// the debounced `authored` trigger (spec 04 §5.4).
import CoreSync
import CoreTestSupport
import Foundation
import Synchronization
import Testing

@testable import CoreOutbox

func op(_ id: String, payload: JSONValue = .object(JSONObject([("currency", .string("AED"))]))) -> Op {
  Op(v: 4, type: .homeCurrencySet, opID: id, authoredAt: "2026-10-11T08:00:00Z", payload: payload)
}

final class Counter: Sendable {
  let n = Mutex(0)
  func bump() { n.withLock { $0 += 1 } }
  var value: Int { n.withLock { $0 } }
}

@Suite("CoreOutbox")
struct OutboxTests {
  @Test("enqueue stores each op's canonical JSON in one transaction")
  func enqueue() async throws {
    let store = try LedgerStore.inMemory()
    let box = Outbox(store: store, clock: FakeClock(), onAuthored: {})
    try await box.enqueue([op("a"), op("b")])
    let rows = try store.pendingOps()
    #expect(rows.map(\.opID) == ["a", "b"])
    // authored_at canonicalized; Go's field order; parent_version present.
    #expect(
      String(decoding: rows[0].opJSON, as: UTF8.self)
        == #"{"v":4,"type":"home_currency_set","op_id":"a","authored_at":"2026-10-11T08:00:00.000Z","parent_version":null,"payload":{"currency":"AED"}}"#
    )
  }

  @Test("an invalid op and an op over 8 KiB are refused and nothing is written")
  func refusals() async throws {
    let store = try LedgerStore.inMemory()
    let box = Outbox(store: store, clock: FakeClock(), onAuthored: {})
    let bad = Op(v: 4, type: .txnEdited, opID: "x", authoredAt: "2026-10-11T08:00:00Z", payload: .object(JSONObject()))
    await #expect(throws: OutboxError.self) { try await box.enqueue([op("ok"), bad]) }
    let huge = op("big", payload: .object(JSONObject([("currency", .string(String(repeating: "A", count: 9000)))])))
    await #expect(throws: OutboxError.opTooLarge(opID: "big")) { try await box.enqueue([huge]) }
    #expect(try store.pendingCount() == 0)
  }

  @Test("an edit made while the authored run is under way leaves that run alone and asks for its own")
  func enqueueDuringFiring() async throws {
    let store = try LedgerStore.inMemory()
    let started = Counter()
    let finished = Counter()
    let cancelled = Counter()
    let release = Mutex(false)
    let box = Outbox(
      store: store, clock: FakeClock(), debounce: .milliseconds(20),
      onAuthored: {
        started.bump()
        while !release.withLock({ $0 }) { await Task.yield() }
        if Task.isCancelled { cancelled.bump() }
        finished.bump()
      })
    try await box.enqueue([op("a")])
    for _ in 0..<200 where started.value == 0 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(started.value == 1)
    try await box.enqueue([op("b")])
    release.withLock { $0 = true }
    for _ in 0..<200 where finished.value < 2 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(finished.value == 2)
    #expect(cancelled.value == 0)
  }

  @Test("flushing the trigger while the authored run is under way leaves that run alone")
  func flushDuringFiring() async throws {
    let store = try LedgerStore.inMemory()
    let started = Counter()
    let finished = Counter()
    let cancelled = Counter()
    let release = Mutex(false)
    let box = Outbox(
      store: store, clock: FakeClock(), debounce: .milliseconds(20),
      onAuthored: {
        started.bump()
        while !release.withLock({ $0 }) { await Task.yield() }
        if Task.isCancelled { cancelled.bump() }
        finished.bump()
      })
    try await box.enqueue([op("a")])
    for _ in 0..<200 where started.value == 0 { try await Task.sleep(for: .milliseconds(10)) }
    async let flushed: Void = box.flushTriggerNow()
    for _ in 0..<200 where started.value < 2 { try await Task.sleep(for: .milliseconds(10)) }
    release.withLock { $0 = true }
    await flushed
    for _ in 0..<200 where finished.value < 2 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(finished.value == 2)
    #expect(cancelled.value == 0)
  }

  @Test("flushing inside the window fires once: the replaced wait never fires")
  func flushInsideWindowFiresOnce() async throws {
    let store = try LedgerStore.inMemory()
    let fired = Counter()
    let box = Outbox(store: store, clock: FakeClock(), debounce: .milliseconds(300), onAuthored: { fired.bump() })
    try await box.enqueue([op("a")])
    await box.flushTriggerNow()
    #expect(fired.value == 1)
    try await Task.sleep(for: .milliseconds(500))
    #expect(fired.value == 1)
  }

  @Test("several enqueues inside the debounce window fire one authored trigger")
  func debounce() async throws {
    let store = try LedgerStore.inMemory()
    let fired = Counter()
    // A wide window, so a slow, busy CI runner still makes both enqueues
    // inside it; then wait (bounded) for the one trigger, and a while longer
    // for a second one that must not come.
    let box = Outbox(store: store, clock: FakeClock(), debounce: .milliseconds(400), onAuthored: { fired.bump() })
    try await box.enqueue([op("a")])
    try await box.enqueue([op("b")])
    for _ in 0..<100 where fired.value == 0 { try await Task.sleep(for: .milliseconds(50)) }
    try await Task.sleep(for: .milliseconds(600))
    #expect(fired.value == 1)
  }
}
