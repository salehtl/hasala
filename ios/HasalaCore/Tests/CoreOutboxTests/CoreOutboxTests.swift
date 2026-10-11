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

  @Test("several enqueues inside the debounce window fire one authored trigger")
  func debounce() async throws {
    let store = try LedgerStore.inMemory()
    let fired = Counter()
    let box = Outbox(store: store, clock: FakeClock(), onAuthored: { fired.bump() })
    try await box.enqueue([op("a")])
    try await box.enqueue([op("b")])
    try await Task.sleep(for: .milliseconds(1700))
    #expect(fired.value == 1)
  }
}
