// gmail-sync: the first scan of a large window (a 90-day backfill of hundreds of alerts)
// against Gmail's per-user rate limit (250 quota units a second, a moving average; each
// message is two 5-unit `messages.get` calls). The limit is modelled on the rig's clock,
// which the engine's waits advance. Every message is synthetic.
import CoreMailbox
import CoreTestSupport
import CoreTime
import Foundation
import Testing

/// Gmail's per-user limit as these tests see it: `allowance` message requests, then every
/// request answers 429 until `penaltyMs` have passed on `clock`, then the allowance again.
/// `forever` answers 429 to every request.
final class GmailRateLimit: @unchecked Sendable {
  private let lock = NSLock()
  private let clock: ManualClock
  private let allowance: Int
  private let penaltyMs: Int64
  private var used = 0
  private var until: Int64?
  var forever = false
  private(set) var refused = 0

  init(clock: ManualClock, allowance: Int, penaltyMs: Int64) {
    self.clock = clock
    self.allowance = allowance
    self.penaltyMs = penaltyMs
  }

  func answer(_ path: String) -> Int? {
    guard path.contains("/messages/") else { return nil }
    return lock.withLock {
      let now = clock.nowMs()
      if forever {
        refused += 1
        return 429
      }
      if let u = until {
        if now < u {
          refused += 1
          return 429
        }
        until = nil
        used = 0
      }
      used += 1
      if used > allowance {
        until = now + penaltyMs
        refused += 1
        return 429
      }
      return nil
    }
  }
}

@Suite struct FirstScanTests {
  /// `count` alerts over the last 89 days, newest first.
  static func backfill(_ rig: Rig, count: Int) {
    for i in 0..<count {
      let t = Rig.t0 - 60_000 - Int64(i) * (89 * day / Int64(count))
      if i % 2 == 0 {
        rig.gmail.add(SyntheticMail.dibCard(id: "d\(i)", amount: "\(10 + i).50", dateMs: t))
      } else {
        rig.gmail.add(SyntheticMail.enbdAlert(id: "e\(i)", amount: "\(i).25", dateMs: t))
      }
    }
  }

  @Test func aRateLimitedDownloadWaitsLongEnoughForTheLimitToPass() async {
    // One download at a time, so the waits are the only time that passes. The old 400 ms and
    // 1.2 s retries ended inside a 5 s penalty, and the cycle stopped there.
    let rig = Rig { $0.downloadWidth = 1 }
    Self.backfill(rig, count: 60)
    let limit = GmailRateLimit(clock: rig.clock, allowance: 40, penaltyMs: 5_000)
    rig.gmail.limiter = { limit.answer($0) }
    _ = await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90)
    let r = await rig.engine.runCycle(trigger: .refresh)
    #expect(limit.refused > 0)
    #expect(r.haltedOn == nil && r.phase == .active && r.ops == 60, "\(r)")
  }

  @Test func theFirstScanReadsAFiveHundredAlertWindowThroughTheRateLimit() async {
    // A penalty longer than one download's retries: the cycle stops partway, as the shipped
    // build's first scan did ("Reading your bank alerts stopped"), and the next one goes on.
    let rig = Rig()
    Self.backfill(rig, count: 500)
    let limit = GmailRateLimit(clock: rig.clock, allowance: 300, penaltyMs: 60_000)
    rig.gmail.limiter = { limit.answer($0) }
    let seen = ProgressLog()
    await rig.engine.setProgressHandler { seen.append($0) }
    _ = await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90)

    let reports = await rig.engine.runFirstScan()
    #expect(reports.count > 1, "the limit cut a cycle short")
    #expect(reports.dropLast().contains { $0.haltedOn == .gmail })
    let last = reports.last
    #expect(last?.phase == .active && last?.haltedOn == nil && last?.completed == true, "\(reports)")
    #expect(reports.reduce(0) { $0 + $1.ops } == 500)
    #expect(Set(await rig.enqueued().map(\.messageID)).count == 500)
    #expect(await rig.state().watermarkMs == Rig.t0)
    // The board never showed "stopped" for a stop the scan rode out, and ended done.
    #expect(!seen.all.contains { if case .failed = $0.stage { true } else { false } })
    #expect(seen.all.last == MailboxProgress(stage: .done, done: 500, total: 500))
  }

  @Test func aLimitThatNeverLiftsEndsTheForegroundScanQuietlyAndALaterRunFinishesIt() async {
    let rig = Rig()
    Self.backfill(rig, count: 20)
    let limit = GmailRateLimit(clock: rig.clock, allowance: 1_000, penaltyMs: 0)
    limit.forever = true
    rig.gmail.limiter = { limit.answer($0) }
    let seen = ProgressLog()
    await rig.engine.setProgressHandler { seen.append($0) }
    _ = await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90)

    let start = rig.clock.nowMs()
    let reports = await rig.engine.runFirstScan()
    // One cycle, then one more after each stall wait (2, 5, 15 and 30 s), then it stops: no
    // spinning against a limit that does not lift.
    #expect(reports.count == 5, "\(reports)")
    #expect(reports.allSatisfy { $0.haltedOn == .gmail || $0.haltedOn == .quota })
    #expect(reports.last?.phase == .scanning)
    #expect(rig.clock.nowMs() - start >= 52_000)
    #expect(!seen.all.contains { if case .failed = $0.stage { true } else { false } })

    // The limit lifts; the next trigger reads the window from where it was.
    limit.forever = false
    let later = await rig.engine.runCycle(trigger: .foreground)
    #expect(later.phase == .active && later.ops == 20, "\(later)")
  }

  @Test func aStopTheUserMustActOnEndsTheFirstScanAtOnce() async {
    let rig = Rig()
    Self.backfill(rig, count: 10)
    _ = await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90)
    rig.gmail.fail("/messages/d0", with: [403], reason: "insufficientPermissions")
    let seen = ProgressLog()
    await rig.engine.setProgressHandler { seen.append($0) }
    let reports = await rig.engine.runFirstScan()
    #expect(reports.count == 1)
    #expect(reports.last?.haltedOn == .reconnectRequired && reports.last?.phase == .reconnectRequired)
    #expect(seen.all.contains(MailboxProgress(stage: .failed(.reconnectRequired), done: 0, total: 0)))
  }
}

final class CommitLog: @unchecked Sendable {
  private let lock = NSLock()
  private var marks: [Int] = []
  func mark(_ authored: Int) { lock.withLock { marks.append(authored) } }
  var all: [Int] { lock.withLock { marks } }
}

@Suite struct MonthFirstScanTests {
  static let monthStart = LocalClock.startOfDay(CivilDate(year: 2026, month: 5, day: 1)!)

  static func dates(count: Int) -> [String: Int64] {
    var out: [String: Int64] = [:]
    for i in 0..<count {
      out[i % 2 == 0 ? "d\(i)" : "e\(i)"] = Rig.t0 - 60_000 - Int64(i) * (89 * day / Int64(count))
    }
    return out
  }

  @Test func aFiveHundredAlertBackfillCommitsThisMonthFirstInSmallBatches() async {
    let rig = Rig()
    FirstScanTests.backfill(rig, count: 500)
    let dates = Self.dates(count: 500)
    let thisMonth = Set(dates.filter { $0.value >= Self.monthStart }.keys)
    #expect(thisMonth.count > 100 && thisMonth.count < 200)
    let seen = ProgressLog()
    let commits = CommitLog()
    let authored = rig.authored
    await rig.engine.setProgressHandler { seen.append($0) }
    await rig.engine.setCommitHandler { commits.mark(authored.all.count) }
    _ = await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90)

    let reports = await rig.engine.runFirstScan()
    #expect(reports.last?.phase == .active && reports.last?.haltedOn == nil, "\(reports)")

    let order = await rig.enqueued().map(\.messageID)
    #expect(order.count == 500 && Set(order).count == 500)
    #expect(Set(order.prefix(thisMonth.count)) == thisMonth)
    var batches: [[Int64]] = []
    var at = 0
    for n in rig.authored.batches {
      batches.append(order[at..<at + n].compactMap { dates[$0] })
      at += n
    }
    #expect(zip(batches, batches.dropFirst()).allSatisfy { ($0.min() ?? 0) >= ($1.max() ?? 0) })

    let first = rig.listRequests.first?.query.first { $0.0 == "q" }?.1 ?? ""
    #expect(first.contains("after:\(Self.monthStart / 1000)"), "\(first)")

    #expect(rig.authored.batches.allSatisfy { $0 <= 28 }, "\(rig.authored.batches)")
    #expect(commits.all.count >= 500 / 28)
    #expect(commits.all.first ?? 0 <= 28)
    #expect(commits.all == commits.all.sorted())
    #expect(await rig.ledger.flushes >= commits.all.count)

    let reading = seen.all.filter { $0.stage == .downloading }
    #expect(reading.allSatisfy { $0.total == 500 })
    #expect(reading.map(\.done) == reading.map(\.done).sorted())
    #expect(reading.last?.done == 500)
    #expect(seen.all.last == MailboxProgress(stage: .done, done: 500, total: 500))
  }

  @Test func aStopMidScanKeepsWhatWasCommittedAndTheNextCycleGoesOnWithTheRest() async {
    let rig = Rig()
    FirstScanTests.backfill(rig, count: 120)
    _ = await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90)
    rig.gmail.fail("/messages/d60", with: [500, 500, 500])
    let cut = await rig.engine.runCycle(trigger: .refresh)
    #expect(cut.phase == .scanning && cut.haltedOn != nil, "\(cut)")
    let early = await rig.enqueued().count
    #expect(early >= 25 && early < 120)
    #expect(await rig.stagedCount() == 0)
    let rest = await rig.engine.runCycle(trigger: .refresh)
    #expect(rest.phase == .active)
    #expect(Set(await rig.enqueued().map(\.messageID)).count == 120)
  }

  @Test func batchedCommitsAuthorTheSamePayloadsAsOnePass() async {
    let batched = Rig()
    let onePass = Rig { $0.firstScanCommitEvery = Int.max }
    for rig in [batched, onePass] {
      FirstScanTests.backfill(rig, count: 120)
      _ = await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90)
      #expect(await rig.engine.runFirstScan().last?.phase == .active)
    }
    #expect(batched.authored.batches.count > onePass.authored.batches.count)
    func payloads(_ rig: Rig) async -> [String: String] {
      Dictionary(uniqueKeysWithValues: await rig.enqueued().map { ($0.messageID, $0.payload.canonical) })
    }
    let a = await payloads(batched)
    let b = await payloads(onePass)
    #expect(a.count == 120)
    #expect(a == b)
  }

  @Test func aDeadlineMidScanCommitsWhatWasReadBeforeItStops() async {
    let rig = Rig()
    FirstScanTests.backfill(rig, count: 120)
    let clock = rig.clock
    rig.gmail.limiter = { path in
      if path.contains("/messages/") { clock.advance(200) }
      return nil
    }
    _ = await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90)
    let deadline = rig.clock.nowMs() + 5_000 + 20_000
    let cut = await rig.engine.runCycle(trigger: .processing, deadlineMs: deadline)
    #expect(cut.phase == .scanning, "\(cut)")
    let early = await rig.enqueued().count
    #expect(early > 0 && early < 120, "\(early)")
    let downloaded = Set(rig.rawRequests.map(\.path))
    #expect(downloaded.count == early, "\(rig.authored.batches)")
    #expect(await rig.stagedCount() == 0)
    rig.gmail.limiter = nil
    let rest = await rig.engine.runCycle(trigger: .refresh)
    #expect(rest.phase == .active)
    let ids = await rig.enqueued().map(\.messageID)
    #expect(ids.count == 120 && Set(ids).count == 120)
  }

  @Test func anAccountFullFlushMidScanHaltsAndARetryFinishes() async {
    let rig = Rig()
    FirstScanTests.backfill(rig, count: 120)
    let seen = ProgressLog()
    await rig.engine.setProgressHandler { seen.append($0) }
    _ = await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90)
    await rig.ledger.setAccountFull(after: 2)
    let reports = await rig.engine.runFirstScan()
    #expect(reports.count == 1)
    let full = reports.last
    #expect(full?.haltedOn == .accountFull && full?.phase == .halted, "\(reports)")
    #expect(seen.all.contains { $0.stage == .failed(.accountFull) })
    let early = await rig.enqueued().count
    #expect(early >= 50 && early < 120, "\(early)")
    #expect(await rig.ledger.flushes == 3)
    #expect(await rig.state().watermarkMs != Rig.t0)
    await rig.ledger.setAccountFull(after: nil)
    let retry = await rig.engine.runCycle(trigger: .retry)
    #expect(retry.phase == .active, "\(retry)")
    let ids = await rig.enqueued().map(\.messageID)
    #expect(Set(ids).count == 120 && ids.count == 120)
  }

  @Test func aPagedRunCountsAcrossItsPages() async {
    let rig = Rig()
    FirstScanTests.backfill(rig, count: 250)
    let seen = ProgressLog()
    await rig.engine.setProgressHandler { seen.append($0) }
    _ = await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90)
    let r = await rig.engine.runCycle(trigger: .processing)
    #expect(r.phase == .active, "\(r)")
    #expect(rig.listRequests.count > 2)
    let reading = seen.all.filter { $0.stage == .downloading }
    #expect(reading.map(\.done) == reading.map(\.done).sorted())
    #expect(reading.map(\.total) == reading.map(\.total).sorted())
    #expect(reading.allSatisfy { $0.done <= $0.total })
    #expect(reading.last == MailboxProgress(stage: .downloading, done: 250, total: 250))
    #expect(seen.all.last == MailboxProgress(stage: .done, done: 250, total: 250))
  }

  @Test func aPagedRunAfterAForegroundOneKeepsTheWholeWindowsTotal() async {
    let rig = Rig()
    FirstScanTests.backfill(rig, count: 250)
    _ = await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90)
    rig.gmail.fail("/messages/d150", with: [500, 500, 500])
    let cut = await rig.engine.runCycle(trigger: .refresh)
    #expect(cut.phase == .scanning && cut.haltedOn != nil, "\(cut)")
    let seen = ProgressLog()
    await rig.engine.setProgressHandler { seen.append($0) }
    let r = await rig.engine.runCycle(trigger: .processing)
    #expect(r.phase == .active, "\(r)")
    let reading = seen.all.filter { $0.stage == .downloading }
    #expect(!reading.isEmpty && reading.allSatisfy { $0.total == 250 }, "\(reading)")
    #expect(reading.map(\.done) == reading.map(\.done).sorted())
    #expect(reading.last?.done == 250)
  }
}
