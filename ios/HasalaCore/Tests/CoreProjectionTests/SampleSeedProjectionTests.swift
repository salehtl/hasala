// The bundled sample seed, loaded as a review account would load it (the
// account's open authors home currency and the USD rate first), folded and
// projected, then read back through LedgerReader's queries, including the
// bills-and-accounts ones: the figures the reviewer sees on Home, Activity,
// Review, Bills and the Japan trip (MayaLedger's).
import CoreCategorize
import CoreDomain
import CoreInvariants
import CorePrimitives
import CoreReplay
import CoreTestSupport
import CoreTime
import CoreWire
import Foundation
import Testing

@testable import CoreProjection

@Suite("The sample seed, projected")
struct SampleSeedProjectionTests {
  static let anchor: Int64 = 1_791_625_200_000  // 2026-10-10T09:40:00Z
  static let writer = "ios-0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"
  static let october = CivilMonth(year: 2026, month: 10)!
  static let today = CivilDate(year: 2026, month: 10, day: 10)!

  static func loaded() throws -> (State, ProjectionStore) {
    var s = State()
    var boot = OpAuthor(AuthorContext(writerID: writer, nowMs: anchor - 86_400_000, ownLastMs: nil, maxAuthored: [:], random: SeededRandom(seed: "boot")))
    boot.setHomeCurrency("AED")
    try boot.setRate(currency: "USD", rateMicro: 3_672_500)
    let first = try boot.build()
    try Replay.foldOps(first.ops, seq: 1, writerID: writer, into: &s)
    let ctx = AuthorContext(writerID: writer, nowMs: anchor, ownLastMs: first.lastAuthoredMs, maxAuthored: [:], random: SeededRandom(seed: "seed"))
    for (i, b) in try SampleSeed.batches(try SampleSeed.bundled(), nowMs: anchor, context: ctx).enumerated() {
      try Replay.foldOps(b.ops, seq: Int64(i + 2), writerID: writer, into: &s)
    }
    let p = try ProjectionStore.inMemory()
    try p.project(s, pending: [], writerID: writer, dictionary: try MerchantDictionary.bundled().get(), projectedAtMs: anchor)
    return (s, p)
  }

  @Test("folds clean and projects complete")
  func clean() throws {
    let (s, p) = try Self.loaded()
    #expect(s.anomalies.isEmpty && s.forks.isEmpty && s.unreadable.isEmpty)
    #expect(!Invariants.halts(Invariants.check(s)))
    #expect(try p.reader.isUsable())
  }

  @Test("Activity, Review and the sample rows: 26 in October, 6 to review, sample-<n> message ids")
  func activity() throws {
    let (_, p) = try Self.loaded()
    let r = p.reader
    #expect(try r.activity(month: Self.october, limit: 500).count == 26)
    #expect(try r.review().count == 6)
    #expect(try r.reviewCounts().values.reduce(0, +) == 6)
    let rows = try r.activity(limit: 500)
    #expect(rows.count == 30)
    let mailbox = rows.compactMap(\.mailboxMessageID)
    #expect(!mailbox.isEmpty && mailbox.allSatisfy { $0.hasPrefix("sample-") })
    let byName = Dictionary(grouping: rows, by: \.displayName)
    #expect(byName["Carrefour"]?.count == 3 && byName["Talabat"]?.count == 2 && byName["Starbucks"]?.first?.location == "DIFC")
    #expect(byName["Steam"]?.first?.needsReview == true)
    // Card rows take their account from the card; manual rows from their annotation.
    let enbd = OpAuthor.cardAccountID(bank: "enbd", last4: "4412")
    #expect(rows.first { $0.displayName == "Waitrose" }?.effectiveAccountID == enbd)
    #expect(rows.first { $0.merchantRaw == "Al Habtoor" }?.effectiveAccountID == enbd)
    #expect(try r.knownMailboxMessageIDs(["sample-1", "sample-999"]) == ["sample-1"])
  }

  @Test("accounts, cards, check-ins: ENBD ···4412 and DIB ···8891, net worth 227,568.00")
  func accounts() throws {
    let (_, p) = try Self.loaded()
    let r = p.reader
    let accounts = try r.accounts()
    #expect(accounts.map(\.name) == ["Emirates NBD Current", "DIB Credit Card", "Cash", "Sarwa portfolio"])
    #expect(accounts.map(\.kind) == ["current", "credit_card", "cash", "investment"])
    let cards = try r.cards()
    #expect(cards.map { "\($0.bank ?? "") \($0.last4) \($0.state)" } == ["dib 8891 mine", "enbd 4412 mine"])
    #expect(cards.first { $0.bank == "enbd" }?.account == OpAuthor.cardAccountID(bank: "enbd", last4: "4412"))
    let checkins = try r.checkins()
    #expect(checkins.count == 4 && checkins.map(\.balanceMinor).reduce(0, +) == 22_756_800)
    #expect(try r.checkins(account: "ac_cash").map(\.balanceMinor) == [55_000])
  }

  @Test("bills: 8 tracked, resolutions on their due dates; the income source; the trip and the goal")
  func billsAndPlanRecords() throws {
    let (_, p) = try Self.loaded()
    let r = p.reader
    let bills = try r.bills()
    #expect(bills.count == 8)
    #expect(Set(bills.map(\.bill.name)) == ["AXA Insurance", "DEWA", "du", "Rent · Al Habtoor", "Netflix", "Spotify", "Savings standing order", "Sarwa"])
    let axa = try #require(bills.first { $0.bill.name == "AXA Insurance" })
    #expect(axa.bill.amountMinor == 55_000 && axa.bill.anchor == "2026-10-07" && axa.bill.cadence == BillCadence(unit: "month", every: 1))
    #expect(try r.billResolutions(bill: axa.id).map(\.due) == ["2026-04-07", "2026-05-07", "2026-06-07", "2026-07-07", "2026-08-07", "2026-09-07"])
    let du = try #require(bills.first { $0.bill.name == "du" })
    #expect(du.bill.amountMinor == 38_900 && du.bill.toleranceBp == 200)
    #expect(try r.billResolutions(bill: du.id).last?.txn != nil)
    #expect(bills.first { $0.bill.name == "DEWA" }?.bill.amountMode == "variable")
    #expect(try r.billResolutions().count == 13)
    let income = try r.incomeSources()
    #expect(income.count == 1 && income[0].amountMinor == 2_500_000 && income[0].payday == 28)
    let projects = try r.projects()
    #expect(projects.map(\.project.name) == ["Japan trip"] && projects[0].project.budgetMinor == 1_200_000)
    #expect(try r.projectLines().map(\.signedHome).reduce(0) { $0 + ($1 ?? 0) } == 486_000)
    #expect(try r.goals().map(\.goal.name) == ["Emergency fund"])
    #expect(try r.senderTrust().isEmpty)
    let ingest = try #require(try rowsIngest(p))
    #expect(try r.hasIngest(ingest) && !r.hasIngest(String(repeating: "0", count: 64)))
  }

  func rowsIngest(_ p: ProjectionStore) throws -> String? {
    try p.reader.db.read { db in try String.fetchOne(db, sql: "SELECT ingest_id FROM txn LIMIT 1") }
  }

  @Test("the plan and Home's hero: 24,000 planned of 25,000, 2,282.45 of 9,700.00 everyday spent")
  func plan() throws {
    let (_, p) = try Self.loaded()
    let e = try p.reader.planEngine(month: Self.october, today: Self.today)
    #expect(e.planned(Self.october) == 2_400_000)
    #expect(e.income(Self.october).total == 2_500_000)
    #expect(e.readyToAssign(Self.october) == 100_000)
    let h = e.hero(Self.october)
    #expect(h.budget == 970_000 && h.spent == 228_245 && h.left == 741_755)
  }
}
