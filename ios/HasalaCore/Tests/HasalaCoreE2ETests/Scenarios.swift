// The two cross-device scenarios of the TestFlight plan's Lane A, written once
// and run against FakeServer (SampleSeedSyncTests, GmailToReplayTests) and
// against a local hasalad (LiveSampleSeedTests, LiveGmailToReplayTests):
//
//   sample   A (a review account) loads the sample seed; B signs in, pulls and
//            projects: 26 October transactions, 8 bills, 6 to review, "Japan
//            trip", ENBD ···4412
//   gmail    FakeGmail's synthetic alerts → the real MailboxEngine (stub link
//            server, stub step-up) on A → RuntimeMailboxLedger → the real Outbox
//            and SyncEngine → the server → B pulls, folds and projects
import CoreAuth
import CoreCategorize
import CoreDomain
import CoreJSON
import CoreMailbox
import CoreProjection
import CoreReplay
import CoreStore
import CoreSync
import CoreTemplate
import CoreTestSupport
import CoreTime
import Foundation
import Testing

enum Scenarios {
  /// Saturday 10 October 2026, 13:40 in Dubai: the sample's anchor.
  static let anchor: Int64 = 1_791_625_200_000
  static let october = CivilMonth(year: 2026, month: 10)!

  // MARK: Sample

  /// A bootstraps and loads the sample at the anchor; both upload and pull.
  /// `account(review)` sets A's review flag on the server the test runs
  /// against and returns A's `GET /account`.
  static func sampleOnSecondDevice(_ a: Runtime, _ b: Runtime, account: (_ review: Bool) async throws -> AccountInfo)
    async throws
  {
    try await a.bootstrap()
    // AT-34: not a review account (the server's own answer): refused, nothing authored.
    let before = try a.context.store.pendingCount()
    let plain = try await account(false)
    #expect(plain.review_account != true)
    await #expect(throws: SampleLoadError.seed(.refused(.notReviewAccount))) { _ = try await a.loadSample(account: plain) }
    #expect(try a.context.store.pendingCount() == before)
    let account = try await account(true)
    #expect(account.review_account == true && account.user_id == a.context.userID.string)
    // Another account's answer never opens this one's gate.
    let other = AccountInfo(user_id: "00000000-0000-4000-8000-000000000000", review_account: true)
    await #expect(throws: SampleLoadError.seed(.refused(.notReviewAccount))) { _ = try await a.loadSample(account: other) }
    let ops = try await a.loadSample(account: account)
    #expect(ops > 100)
    // One-shot: a second tap on A, before or after the upload, is refused.
    await #expect(throws: SampleLoadError.seed(.refused(.alreadyLoaded))) { _ = try await a.loadSample(account: account) }
    #expect(try a.reader.activity(month: october, limit: 500).allSatisfy(\.pending))
    let out = await a.run(.authored)
    #expect(out.stop == nil, "\(String(describing: out.stop))")
    #expect(out.pushed.opsAcknowledged == ops + 2)
    #expect(try a.context.store.pendingCount() == 0)
    let pulled = await b.run(.launch)
    #expect(pulled.stop == nil, "\(String(describing: pulled.stop))")
    try expectMayaSample(b.reader, month: october)
    #expect(try await a.state().serialized() == b.state().serialized())
    // B, on the same review account, sees the sample: refused, nothing authored.
    await #expect(throws: SampleLoadError.seed(.refused(.alreadyLoaded))) { _ = try await b.loadSample(account: account) }
    #expect(try b.context.store.pendingCount() == 0)
  }

  /// The reviewer's figures on a device that pulled the sample.
  static func expectMayaSample(_ r: LedgerReader, month: CivilMonth) throws {
    #expect(try r.activity(month: month, limit: 500).count == 26)
    #expect(try r.review().count == 6)
    #expect(try r.bills().count == 8)
    #expect(try r.projects().map(\.project.name) == ["Japan trip"])
    let enbd = try #require(try r.cards().first { $0.bank == "enbd" && $0.last4 == "4412" && $0.state == "mine" })
    #expect(try r.accounts().first { $0.id == enbd.account }?.name == "Emirates NBD Current")
    #expect(try r.activity(limit: 500).contains { $0.mailboxMessageID?.hasPrefix("sample-") == true })
    let hero = try r.planEngine(month: month, today: CivilDate(year: month.year, month: month.month, day: 10)!).hero(month)
    #expect(hero.budget == 970_000 && hero.spent == 228_245)
  }

  // MARK: Gmail

  struct ConsentPresenter: GmailAuthSessionPresenter {
    let gmail: FakeGmail
    func authorize(url: URL, callbackScheme: String) async throws(GmailOAuthError) -> URL { gmail.consent(authorizeURL: url) }
  }

  /// hasalad's link routes, answered here: this iPhone holds the link, no wake topic.
  actor LinkServer: MailboxServer {
    var linked = false
    func linkStatus() async throws(MailboxServerError) -> MailboxLinkStatus {
      linked ? .holder(isThisDevice: true, watchExpiresAtMs: nil) : .noLink
    }
    func linkChallenge() async throws(MailboxServerError) -> String { "bm9uY2Utc3ludGhldGljLTAwMDAwMDAwMDAwMDAwMDA" }
    func putLink(idToken: String, stepUp: JSONValue) async throws(MailboxServerError) -> MailboxLinkStatus {
      linked = true
      return .holder(isThisDevice: true, watchExpiresAtMs: nil)
    }
    func putWatch(expiresAtMs: Int64) async throws(MailboxServerError) {}
    func deleteLink(stepUp: JSONValue) async throws(MailboxServerError) { linked = false }
    func watchTopic() async throws(MailboxServerError) -> String? { nil }
  }

  struct ApprovedStepUp: MailboxStepUp {
    func proof(kind: String, payloadHash: Data?) async throws(MailboxStepUpError) -> JSONValue {
      .object(JSONObject([("kind", .string("device"))]))
    }
  }

  /// The Gmail lane of `a`, composed as the app's GmailLane composes it.
  static func mailbox(_ a: Runtime, gmail: FakeGmail, clock: any CoreTime.Clock) -> (MailboxEngine, RuntimeMailboxLedger) {
    let oauth = GoogleOAuthClient(
      config: GmailOAuthConfig(
        clientID: "synthetic-client.apps.googleusercontent.com", redirectScheme: "com.googleusercontent.apps.synthetic-client"),
      http: gmail)
    let tokens = RefreshingGmailTokenProvider(
      oauth: oauth, store: SecretsGmailRefreshTokenStore(secrets: a.context.secrets, userID: a.context.userID), clock: clock)
    let authoring = MailboxAuthoring(observer: a.observer)
    let persistence = LedgerMailboxPersistence(store: a.context.store, authoring: authoring, nowMs: { clock.nowMs() })
    let ledger = RuntimeMailboxLedger(engine: a.engine, observer: a.observer, outbox: a.outbox, authoring: authoring)
    let engine = MailboxEngine(
      config: MailboxEngineConfig(grantID: a.context.userID.string), oauth: oauth, tokens: tokens, gmailHTTP: gmail,
      store: persistence, ledger: ledger, server: LinkServer(), stepUp: ApprovedStepUp(),
      categorizer: PipelineCategorizer(projection: a.projection, dictionary: bundledDictionary),
      templates: BundledTemplates.load().templates, clock: clock, random: a.context.random, sleep: { _ in })
    return (engine, ledger)
  }

  /// "DD-MM-YYYY" of the local day of `ms` (DIB's body date).
  static func dibDay(_ ms: Int64) -> String {
    let d = LocalClock.localDate(ms)!
    return String(format: "%02d-%02d-%04d", d.day, d.month, d.year)
  }

  static func gmailToReplay(_ a: Runtime, _ b: Runtime, clock: any CoreTime.Clock) async throws {
    let day: Int64 = 86_400_000
    let now = clock.nowMs()
    try await a.bootstrap()
    #expect(await a.run(.authored).stop == nil)
    let gmail = FakeGmail()
    let d1 = SyntheticMail.dibCard(id: "d1", amount: "64.50", day: dibDay(now - 2 * day), merchant: "STARBUCKS DIFC", last4: "1234", dateMs: now - 2 * day)
    gmail.add(d1)
    gmail.add(SyntheticMail.dibCard(id: "d2", amount: "342.15", day: dibDay(now - day), merchant: "SYNTHETIC GROCER DUBAI", last4: "1234", dateMs: now - day))
    gmail.add(SyntheticMail.enbdAlert(id: "e1", amount: "12.34", dateMs: now - day / 2))
    gmail.add(SyntheticMail.bankNotice(id: "n1", dateMs: now - day / 4))
    let (engine, ledger) = mailbox(a, gmail: gmail, clock: clock)
    // The bank step trusts the senders (03c §7.1); the lane lists only trusted senders.
    try await ledger.authorSenderTrust(domain: "dib.ae", trusted: true)
    try await ledger.authorSenderTrust(domain: "alerts@emiratesnbd.com", trusted: true)
    #expect(await ledger.senderTrust() == ["dib.ae": true, "emiratesnbd.com": true])

    let connected = await engine.connect(presenter: ConsentPresenter(gmail: gmail), backfillDays: 30)
    guard case .connected = connected else {
      Issue.record("connect: \(connected)")
      return
    }
    let scan = await engine.runCycle(trigger: .launch)
    #expect(scan.phase == .awaitingCards && scan.staged == 4, "\(scan)")
    let cards = await engine.scanSummary().cards.map(\.card)
    #expect(cards == [CardKey(bank: "dib", last4: "1234"), CardKey(bank: "enbd", last4: "8642")])
    let done = await engine.confirmCards(cards.map { CardDecision(card: $0, state: .mine) })
    #expect(done.phase == .active && done.ops == 4 && done.haltedOn == nil, "\(done)")
    #expect(done.sortedBy["dictionary"] == 1)
    #expect(try a.context.store.pendingCount() == 0)  // the lane flushed
    #expect(await ledger.isIngested(MessageDisposer.ingestID(d1.raw)))

    // B pulls, folds and projects what A read.
    #expect(await b.run(.launch).stop == nil)
    let rows = try b.reader.activity(limit: 50)
    #expect(Set(rows.compactMap(\.mailboxMessageID)) == ["d1", "d2", "e1"])  // n1 is unparsed: Review, not Activity
    let starbucks = try #require(rows.first { $0.mailboxMessageID == "d1" })
    #expect(starbucks.amountMinor == 6_450 && starbucks.category == "dining" && starbucks.categorySource == "dictionary")
    #expect(starbucks.effectiveAccountID == OpAuthor.cardAccountID(bank: "dib", last4: "1234"))
    #expect(try b.reader.review(lanes: ReviewLane.allCases).contains { $0.mailboxMessageID == "n1" && $0.unparsed })
    #expect(try b.reader.accounts().map { "\($0.name) \($0.kind)" }.sorted() == ["DIB ···1234 credit_card", "Emirates NBD ···8642 current"])
    #expect(try b.reader.cards().allSatisfy { $0.state == "mine" })
    #expect(try await a.state().serialized() == b.state().serialized())
    // Running the lane again lists nothing new and authors nothing twice.
    let again = await engine.runCycle(trigger: .refresh)
    #expect(again.ops == 0 && again.haltedOn == nil, "\(again)")
  }
}
