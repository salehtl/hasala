import CoreAuth
import CoreStore
import CoreSync
import CoreTestSupport
import Foundation
import Testing

@Suite("Sync: a stuck outbox is tried again after an app update")
struct LatchAfterUpdateTests {
  func built(_ c: SyncContext, _ build: String?) -> SyncContext {
    SyncContext(
      userID: c.userID, writerID: c.writerID, store: c.store, secrets: c.secrets, client: c.client, clock: c.clock,
      random: c.random, build: build)
  }

  @Test("a hard_stop is tried once more on each new build, and latches again when the server still refuses")
  func hardStopRetriedOncePerBuild() async throws {
    let w = World()
    let (_, _, ctx) = try await w.passwordAccount(w.phone("a"))
    let first = built(ctx, "261101.1")
    try enqueue(first, [op(1)])
    w.server.refuseNext("POST /api/v1/sync", status: 400, code: "bad_request")
    #expect(await SyncEngine(context: first).run(.authored).stop == nil)
    #expect(try ctx.store.syncState().latch == .hardStop)
    #expect(try ctx.store.syncState().latchBuild == "261101.1")

    var sent = w.server.uploadCount
    #expect(await SyncEngine(context: first).run(.launch).stop == nil)
    #expect(w.server.uploadCount == sent)
    #expect(try ctx.store.syncState().latch == .hardStop)

    let second = built(ctx, "261108.2")
    w.server.refuseNext("POST /api/v1/sync", status: 400, code: "bad_request")
    let engine = SyncEngine(context: second)
    #expect(await engine.run(.launch).stop == nil)
    #expect(w.server.uploadCount == sent)
    #expect(try ctx.store.syncState().latch == .hardStop)
    #expect(try ctx.store.syncState().latchBuild == "261108.2")
    #expect(await engine.status.latch == .hardStop)

    sent = w.server.uploadCount
    #expect(await engine.run(.foreground).stop == nil)
    #expect(await SyncEngine(context: second).run(.launch).stop == nil)
    #expect(w.server.uploadCount == sent)
    #expect(try ctx.store.pendingCount() == 1)

    let third = SyncEngine(context: built(ctx, "261115.3"))
    #expect(await third.run(.bgRefresh).stop == nil)
    #expect(try ctx.store.syncState().latch == nil)
    #expect(try ctx.store.syncState().latchBuild == nil)
    #expect(await third.status.latch == nil)
    #expect(try ctx.store.pendingCount() == 0 && ctx.store.inflight().isEmpty)
    #expect(w.server.storedRowCount(user: ctx.userID) == 1)
  }

  @Test("a sealer_fault is tried once more on a new build, and the upload goes through")
  func sealerFaultRetriedOnANewBuild() async throws {
    let w = World()
    let (_, _, ctx) = try await w.passwordAccount(w.phone("a"))
    let first = built(ctx, "1")
    try enqueue(first, [op(1)])
    w.server.refuseNext("POST /api/v1/sync", status: 400, code: "plaintext_refused", detail: "blobs[0]: tail")
    let engine = SyncEngine(context: first)
    #expect(await engine.run(.authored).stop == nil)
    #expect(try ctx.store.syncState().latch == .sealerFault)
    #expect(try ctx.store.syncState().latchBuild == "1")
    #expect(await engine.status.integrityAlarms == 1)

    let sent = w.server.uploadCount
    #expect(await engine.run(.refresh).stop == nil)
    #expect(w.server.uploadCount == sent)

    let updated = SyncEngine(context: built(ctx, "2"))
    #expect(await updated.run(.launch).stop == nil)
    #expect(try ctx.store.syncState().latch == nil)
    #expect(try ctx.store.pendingCount() == 0)
    #expect(w.server.storedRowCount(user: ctx.userID) == 1)
  }

  @Test("a latch an older build raised, with no build noted, is tried once more")
  func latchWithNoBuildIsTriedAgain() async throws {
    let w = World()
    let (_, _, ctx) = try await w.passwordAccount(w.phone("a"))
    try enqueue(ctx, [op(1)])
    try ctx.store.setLatch(.hardStop)
    #expect(try ctx.store.syncState().latchBuild == nil)
    #expect(await SyncEngine(context: built(ctx, "7")).run(.silentPush).stop == nil)
    #expect(try ctx.store.syncState().latch == nil)
    #expect(try ctx.store.pendingCount() == 0)
  }

  @Test("an engine that does not know its build never lifts a hard_stop or a sealer_fault")
  func noBuildNoRetry() async throws {
    for latch in [OutboxLatch.hardStop, .sealerFault] {
      let w = World()
      let (_, _, ctx) = try await w.passwordAccount(w.phone("a"))
      try enqueue(ctx, [op(1)])
      try ctx.store.setLatch(latch, build: "1")
      let sent = w.server.uploadCount
      #expect(await SyncEngine(context: ctx).run(.launch).stop == nil)
      #expect(w.server.uploadCount == sent)
      #expect(try ctx.store.syncState().latch == latch)
    }
  }

  @Test("a chain_break latch is not lifted by a new build")
  func chainBreakIgnoresTheBuild() async throws {
    let w = World()
    let (_, _, ctx) = try await w.passwordAccount(w.phone("a"))
    try enqueue(ctx, [op(1)])
    try ctx.store.setLatch(.chainBreak, build: "1")
    let sent = w.server.uploadCount
    #expect(await SyncEngine(context: built(ctx, "2")).run(.silentPush).stop == nil)
    #expect(w.server.uploadCount == sent)
    #expect(try ctx.store.syncState().latch == .chainBreak)
  }

  @Test("the uploads count as stuck only behind a hard_stop or a sealer_fault")
  func stuckLatches() {
    #expect(OutboxLatch.allCases.filter(\.keepsChangesFromUploading) == [.hardStop, .sealerFault])
    var status = SyncStatus()
    #expect(!status.uploadsStuck)
    status.latch = .accountFull
    #expect(!status.uploadsStuck)
    status.latch = .sealerFault
    #expect(status.uploadsStuck)
  }
}
