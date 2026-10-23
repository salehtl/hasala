import CoreAuth
import CoreCrypto
import CoreTestSupport
import Foundation
import Testing

@testable import CoreSync

@Suite("Push: a Not this travels alone")
struct PusherIsolationTests {
  static func rejection(_ i: Int) -> Op {
    Op(
      v: 4, type: .merchantCategoryRejected, opID: "01J0000000000000000000R\(String(format: "%03d", i))",
      authoredAt: "2026-10-11T08:00:00.000Z",
      payload: .object(
        JSONObject([("merchant_key", .string("tailscale.com")), ("category", .string("shopping")), ("rejected", .bool(true))])))
  }

  @Test("the pusher closes the blob before and after every op of an isolated kind")
  func alone() async throws {
    let w = World()
    let phone = w.phone("a")
    let (_, _, ctx) = try await w.passwordAccount(phone)
    let ops = [op(1), op(2), Self.rejection(1), Self.rejection(2), op(3), Self.rejection(3)]
    try enqueue(ctx, ops)
    let batch = try Pusher.buildBatch(try ctx.store.pendingOps(), ctx: ctx)
    #expect(batch.map(\.opIDs) == [[op(1).opID, op(2).opID], [Self.rejection(1).opID], [Self.rejection(2).opID], [op(3).opID], [Self.rejection(3).opID]])
    let out = await SyncEngine(context: ctx).run(.authored)
    #expect(out.stop == nil && out.pushed.blobs == 5 && out.pushed.opsAcknowledged == 6)
    #expect(try storedOps(ctx).map(\.opID) == ops.map(\.opID))
  }
}
