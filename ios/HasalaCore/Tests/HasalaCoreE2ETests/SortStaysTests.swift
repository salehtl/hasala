import CoreDomain
import CoreMailbox
import CoreProjection
import CoreReplay
import CoreSync
import CoreTestSupport
import Foundation
import Testing

@Suite("A sorted review card stays sorted (sync, Gmail, relaunch)")
struct SortStaysTests {
  static let day: Int64 = 86_400_000

  static func sort(_ a: Runtime, _ id: String, into category: String) async throws {
    let v = try #require(try a.reader.txn(id)).version
    try await a.author { x in x.categorize(txnID: id, parentVersion: v, category: category, needsReview: false) }
  }

  static func inDeck(_ r: LedgerReader, _ id: String) throws -> Bool {
    try r.review().contains { $0.id == id }
  }

  static func connected(_ w: World, _ a: Runtime, _ gmail: FakeGmail) async throws -> (MailboxEngine, RuntimeMailboxLedger) {
    try await a.bootstrap()
    #expect(await a.run(.authored).stop == nil)
    let (engine, ledger) = Scenarios.mailbox(a, gmail: gmail, clock: w.clock)
    try await ledger.authorSenderTrust(domain: "dib.ae", trusted: true)
    guard case .connected = await engine.connect(presenter: Scenarios.ConsentPresenter(gmail: gmail), backfillDays: 30) else {
      Issue.record("connect")
      return (engine, ledger)
    }
    let first = await engine.runCycle(trigger: .launch)
    #expect(first.phase == .active && first.haltedOn == nil, "\(first)")
    return (engine, ledger)
  }

  static func card(_ id: String, merchant: String, at ms: Int64, arTopmost: Bool = true) -> FakeGmail.Message {
    SyntheticMail.dibCard(
      id: id, amount: "88.00", day: Scenarios.dibDay(ms), merchant: merchant, last4: "1234", dateMs: ms, arTopmost: arTopmost)
  }

  @Test("an acknowledged sort is still shown while the pull that brings it back has not run")
  func acknowledgedSortSurvivesTheGap() async throws {
    let (w, a, _) = try await twoRuntimes()
    let now = w.clock.nowMs()
    let gmail = FakeGmail()
    gmail.add(Self.card("g1", merchant: "SYNTHETIC KIOSK ONE", at: now - 2 * Self.day))
    gmail.add(Self.card("g2", merchant: "SYNTHETIC KIOSK TWO", at: now - Self.day))
    _ = try await Self.connected(w, a, gmail)
    let rows = try a.reader.review()
    let first = try #require(rows.first { $0.mailboxMessageID == "g1" })
    let second = try #require(rows.first { $0.mailboxMessageID == "g2" })

    try await Self.sort(a, first.id, into: "groceries")
    #expect(try !Self.inDeck(a.reader, first.id))
    w.server.losePullAfterNextUpload()
    let pushed = await a.run(.authored)
    #expect(pushed.pushed.opsAcknowledged == 1 && pushed.stop != nil)
    #expect(try a.context.store.pendingCount() == 0)

    try await Self.sort(a, second.id, into: "dining")
    #expect(try !Self.inDeck(a.reader, first.id))
    #expect(try a.reader.txn(first.id)?.category == "groceries")
    #expect(try a.reader.txn(first.id)?.version == 2)

    #expect(await a.run(.foreground).stop == nil)
    let row = try #require(try a.reader.txn(first.id))
    #expect(row.category == "groceries" && !row.needsReview && row.version == 2 && !row.pending)
    #expect(try !Self.inDeck(a.reader, second.id))
    let state = try await a.state()
    #expect(state.forks.isEmpty)
    #expect(!state.anomalies.contains { $0.kind == "future_parent" || $0.kind == "duplicate_delivery" })

    try await Self.sort(a, first.id, into: "dining")
    #expect(await a.run(.authored).stop == nil)
    #expect(try a.reader.txn(first.id)?.category == "dining")
    #expect(try await a.state().forks.isEmpty)
  }

  @Test("sort, then a Gmail cycle, a re-import of the sender, and a relaunch on a warm snapshot and a cold fold: still sorted")
  func sortThenSyncThenRelaunch() async throws {
    let (w, a, b) = try await twoRuntimes()
    let now = w.clock.nowMs()
    let gmail = FakeGmail()
    gmail.add(Self.card("g1", merchant: "SYNTHETIC KIOSK ONE", at: now - 2 * Self.day))
    gmail.add(Self.card("g2", merchant: "SYNTHETIC KIOSK TWO", at: now - Self.day))
    let (engine, _) = try await Self.connected(w, a, gmail)
    let target = try #require(try a.reader.review().first { $0.mailboxMessageID == "g1" })
    let other = try #require(try a.reader.review().first { $0.mailboxMessageID == "g2" })

    try await Self.sort(a, target.id, into: "groceries")
    w.server.losePullAfterNextUpload()
    _ = await a.run(.authored)
    gmail.add(Self.card("g3", merchant: "SYNTHETIC KIOSK THREE", at: now - Self.day / 4))
    try await Self.sort(a, other.id, into: "dining")
    #expect(try !Self.inDeck(a.reader, target.id))

    let cycle = await engine.runCycle(trigger: .refresh)
    #expect(cycle.haltedOn == nil, "\(cycle)")
    #expect(try !Self.inDeck(a.reader, target.id))
    if case .success(let again) = await engine.importSender("dib.ae") {
      #expect(again.ops == 0, "\(again)")
    } else {
      Issue.record("importSender")
    }
    #expect(await a.run(.foreground).stop == nil)
    #expect(try a.reader.txn(target.id)?.category == "groceries")
    #expect(try !Self.inDeck(a.reader, target.id) && !Self.inDeck(a.reader, other.id))

    let warm = try Runtime(a.context)
    try await warm.observer.open()
    #expect(try warm.reader.txn(target.id)?.category == "groceries")
    #expect(try !Self.inDeck(warm.reader, target.id))

    try await a.context.store.db.write { db in try db.execute(sql: "UPDATE fold_snapshot SET fold_print = 'older semantics'") }
    let cold = try Runtime(a.context)
    try await cold.observer.open()
    #expect(try cold.reader.txn(target.id)?.category == "groceries")
    #expect(try !Self.inDeck(cold.reader, target.id))
    #expect(try await cold.state().serialized() == a.state().serialized())

    #expect(await b.run(.launch).stop == nil)
    #expect(try b.reader.txn(target.id)?.category == "groceries")
    #expect(try !Self.inDeck(b.reader, target.id))
  }

  @Test("a sorted alert whose verified copy arrives later keeps its sort on the canonical row")
  func verifiedCopyKeepsTheSort() async throws {
    let (w, a, _) = try await twoRuntimes()
    let at = w.clock.nowMs() - Self.day
    let gmail = FakeGmail()
    gmail.add(Self.card("u1", merchant: "SYNTHETIC KIOSK ONE", at: at, arTopmost: false))
    let (engine, _) = try await Self.connected(w, a, gmail)
    let sorted = try #require(try a.reader.review().first { $0.mailboxMessageID == "u1" })
    #expect(sorted.needsReview)
    try await Self.sort(a, sorted.id, into: "groceries")
    #expect(await a.run(.authored).stop == nil)
    #expect(try !Self.inDeck(a.reader, sorted.id))

    gmail.add(Self.card("v1", merchant: "SYNTHETIC KIOSK ONE", at: at))
    let cycle = await engine.runCycle(trigger: .refresh)
    #expect(cycle.ops == 1 && cycle.haltedOn == nil, "\(cycle)")
    let live = try a.reader.activity(limit: 50).filter { $0.merchantRaw == "SYNTHETIC KIOSK ONE" }
    #expect(live.count == 1)
    let canonical = try #require(live.first)
    #expect(canonical.mailboxMessageID == "v1")
    #expect(canonical.category == "groceries" && !canonical.needsReview)
    #expect(try !Self.inDeck(a.reader, canonical.id))
  }
}
