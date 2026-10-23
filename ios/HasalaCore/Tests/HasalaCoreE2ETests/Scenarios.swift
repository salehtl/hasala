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
//   outlook  the same, with FakeGraph's alerts through an OutlookProvider: the
//            rows carry provenance "outlook" and, while the Outlook trust gate is
//            closed, all wait in Review
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
    func putLink(provider: MailProviderID, idToken: String, stepUp: JSONValue) async throws(MailboxServerError)
      -> MailboxLinkResult
    {
      linked = true
      return MailboxLinkResult(status: .holder(isThisDevice: true, watchExpiresAtMs: nil))
    }
    func putWatch(expiresAtMs: Int64) async throws(MailboxServerError) {}
    func deleteLink(stepUp: JSONValue) async throws(MailboxServerError) { linked = false }
    func pushConfig(provider: MailProviderID) async throws(MailboxServerError) -> MailboxPushConfig { .none }
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

  // MARK: Outlook

  struct GraphConsentPresenter: MailAuthSessionPresenter {
    let graph: FakeGraph
    func authorize(url: URL, callbackScheme: String) async throws(MailOAuthError) -> URL { graph.consent(authorizeURL: url) }
  }

  /// The Outlook lane of `a`, composed as the app composes it (its Keychain items in A's secrets).
  static func outlookMailbox(_ a: Runtime, graph: FakeGraph, clock: any CoreTime.Clock)
    -> (MailboxEngine, RuntimeMailboxLedger)
  {
    let oauth = MicrosoftOAuthClient(
      config: MicrosoftOAuthConfig(clientID: "00000000-0000-4000-8000-00000000c11e", redirectScheme: "msauth.app.hasala.ios"),
      http: graph)
    let provider = OutlookProvider(
      oauth: oauth, http: graph, link: SecretsOutlookLinkStore(secrets: a.context.secrets, userID: a.context.userID),
      clock: clock)
    let tokens = RefreshingMailTokenProvider(
      oauth: oauth,
      store: SecretsMailRefreshTokenStore(secrets: a.context.secrets, userID: a.context.userID, provider: .outlook),
      clock: clock)
    let authoring = MailboxAuthoring(observer: a.observer)
    let persistence = LedgerMailboxPersistence(store: a.context.store, authoring: authoring, nowMs: { clock.nowMs() })
    let ledger = RuntimeMailboxLedger(engine: a.engine, observer: a.observer, outbox: a.outbox, authoring: authoring)
    let engine = MailboxEngine(
      config: MailboxEngineConfig(grantID: a.context.userID.string), provider: provider, tokens: tokens,
      store: persistence, ledger: ledger, server: LinkServer(), stepUp: ApprovedStepUp(),
      categorizer: PipelineCategorizer(projection: a.projection, dictionary: bundledDictionary),
      templates: BundledTemplates.load().templates, clock: clock, random: a.context.random, sleep: { _ in })
    return (engine, ledger)
  }

  static func outlookToReplay(_ a: Runtime, _ b: Runtime, clock: any CoreTime.Clock) async throws {
    let day: Int64 = 86_400_000
    let now = clock.nowMs()
    try await a.bootstrap()
    #expect(await a.run(.authored).stop == nil)
    let graph = FakeGraph()
    let d1 = SyntheticOutlookMail.dibCard(
      id: "AAkALgAA-e2e-d1", amount: "64.50", day: dibDay(now - 2 * day), merchant: "STARBUCKS DIFC", last4: "1234",
      dateMs: now - 2 * day)
    graph.add(d1)
    graph.add(SyntheticOutlookMail.enbdAlert(id: "AAkALgAA-e2e-e1", amount: "12.34", dateMs: now - day / 2))
    graph.add(SyntheticOutlookMail.bankNotice(id: "AAkALgAA-e2e-n1", dateMs: now - day / 4))
    let (engine, ledger) = outlookMailbox(a, graph: graph, clock: clock)
    try await ledger.authorSenderTrust(domain: "dib.ae", trusted: true)
    try await ledger.authorSenderTrust(domain: "emiratesnbd.com", trusted: true)

    let connected = await engine.connect(presenter: GraphConsentPresenter(graph: graph), backfillDays: 30)
    guard case .connected = connected else {
      Issue.record("connect: \(connected)")
      return
    }
    #expect(try a.context.secrets.store.read(.mailRefresh(provider: .outlook, userID: a.context.userID)) != nil)
    let done = await engine.runCycle(trigger: .launch)
    #expect(done.phase == .active && done.ops == 3 && done.haltedOn == nil, "\(done)")
    #expect(try a.context.store.pendingCount() == 0)
    #expect(await ledger.isIngested(MessageDisposer.ingestID(d1.raw)))

    #expect(await b.run(.launch).stop == nil)
    let review = try b.reader.review(lanes: ReviewLane.allCases)
    #expect(Set(review.compactMap(\.mailboxMessageID)) == ["AAkALgAA-e2e-e1", "AAkALgAA-e2e-n1"])
    let rows = try await b.state().txns.values
    let starbucks = try #require(rows.first { $0.mailboxMessageID == "AAkALgAA-e2e-d1" })
    #expect(starbucks.amountMinor == 6_450 && !starbucks.unparsed && !starbucks.needsReview)
    #expect(rows.first { $0.mailboxMessageID == "AAkALgAA-e2e-e1" }?.needsReview == false)
    #expect(try await a.state().serialized() == b.state().serialized())
    let again = await engine.runCycle(trigger: .refresh)
    #expect(again.ops == 0 && again.haltedOn == nil, "\(again)")
  }

  /// "DD-MM-YYYY" of the local day of `ms` (DIB's body date).
  static func dibDay(_ ms: Int64) -> String {
    let d = LocalClock.localDate(ms)!
    return String(format: "%02d-%02d-%04d", d.day, d.month, d.year)
  }

  /// A 90-day first scan of `count` synthetic alerts (DIB cards, ENBD debits and
  /// statement notices), connected and read the way the setup's first scan reads it:
  /// `runFirstScan` until the window is in. Every alert lands as an op, through the real
  /// persistence, op author, outbox and sync, and uploads.
  static func gmailBackfill(_ a: Runtime, clock: any CoreTime.Clock, count: Int = 500) async throws {
    let day: Int64 = 86_400_000
    let now = clock.nowMs()
    try await a.bootstrap()
    #expect(await a.run(.authored).stop == nil)
    let gmail = FakeGmail()
    for i in 0..<count {
      let t = now - Int64(i) * (89 * day / Int64(count)) - 60_000
      switch i % 5 {
      case 0, 1:
        gmail.add(
          SyntheticMail.dibCard(
            id: "d\(i)", amount: "\(10 + i).50", day: dibDay(t), merchant: "SYNTHETIC SHOP \(i % 37)",
            last4: i % 2 == 0 ? "1234" : "5678", dateMs: t))
      case 2, 3: gmail.add(SyntheticMail.enbdAlert(id: "e\(i)", amount: "\(i).25", dateMs: t))
      default: gmail.add(SyntheticMail.bankNotice(id: "n\(i)", dateMs: t))
      }
    }
    let (engine, ledger) = mailbox(a, gmail: gmail, clock: clock)
    try await ledger.authorSenderTrust(domain: "dib.ae", trusted: true)
    try await ledger.authorSenderTrust(domain: "alerts@emiratesnbd.com", trusted: true)
    guard case .connected = await engine.connect(presenter: ConsentPresenter(gmail: gmail), backfillDays: 90) else {
      Issue.record("connect")
      return
    }
    let last = await engine.runFirstScan().last ?? CycleReport()
    #expect(last.phase == .active && last.haltedOn == nil, "\(last)")
    #expect(try a.context.store.pendingCount() == 0)
    #expect(try a.reader.activity(limit: 1_000).count + (try a.reader.review(lanes: ReviewLane.allCases).filter(\.unparsed).count) == count)
  }

  static func dibTransferNotices(_ a: Runtime, _ b: Runtime, clock: any CoreTime.Clock) async throws {
    let day: Int64 = 86_400_000
    let now = clock.nowMs()
    try await a.bootstrap()
    #expect(await a.run(.authored).stop == nil)
    let gmail = FakeGmail()
    let t1 = now - day
    gmail.add(SyntheticMail.dibTransferNotice(id: "t1", day: dibDay(t1), dateMs: t1))
    gmail.add(SyntheticMail.dibDebitAlert(id: "x1", day: dibDay(t1 + 180_000), dateMs: t1 + 180_000))
    let t2 = now - day / 2
    gmail.add(SyntheticMail.dibTransferNotice(id: "t2", amount: "2718.28", day: dibDay(t2), dateMs: t2))
    gmail.add(
      SyntheticMail.dibTransferNotice(id: "t3", amount: "1414.21", day: dibDay(t2 + 60_000), status: "قيد التنفيذ", dateMs: t2 + 60_000))
    let (engine, ledger) = mailbox(a, gmail: gmail, clock: clock)
    try await ledger.authorSenderTrust(domain: "dib.ae", trusted: true)
    guard case .connected = await engine.connect(presenter: ConsentPresenter(gmail: gmail), backfillDays: 30) else {
      Issue.record("connect")
      return
    }
    let done = await engine.runCycle(trigger: .launch)
    #expect(done.ops == 3 && done.setAside == 1 && done.haltedOn == nil, "\(done)")

    #expect(await b.run(.launch).stop == nil)
    let rows = try b.reader.activity(limit: 50)
    let notice = try #require(rows.first { $0.mailboxMessageID == "t1" })
    #expect(!rows.contains { $0.mailboxMessageID == "x1" })
    #expect(notice.direction == "debit" && notice.amountMinor == 314_159 && !notice.heldCopy)
    let state = try await b.state()
    let alert = try #require(state.txns.values.first { $0.mailboxMessageID == "x1" })
    #expect(alert.mergedInto == notice.id && alert.mergeKind == "transfer" && alert.copyOf == notice.id)
    let other = try #require(rows.first { $0.mailboxMessageID == "t2" })
    #expect(!other.heldCopy && other.direction == "debit" && other.amountMinor == 271_828)
    #expect(try b.reader.review(lanes: [.copy]).isEmpty)
    let lines = try b.reader.moneyLines(from: CivilDate(year: 2000, month: 1, day: 1)!, to: CivilDate(year: 2100, month: 1, day: 1)!)
    #expect(lines.filter { $0.txnID == notice.id }.count == 1 && !lines.contains { $0.txnID == alert.id })
    #expect(try !b.reader.review(lanes: ReviewLane.allCases).contains { $0.mailboxMessageID == "t3" })
    #expect(!rows.contains { $0.mailboxMessageID == "t3" })
    #expect(await engine.status().setAside.contains { $0.domain == "dib.ae" && $0.count == 1 })
    #expect(await engine.readerCounts()["dib"]?.pendingSetAside == 1)
    #expect(try await a.state().serialized() == b.state().serialized())
  }

  static func realDIBMail(_ a: Runtime, clock: any CoreTime.Clock, root: URL) async throws {
    let dir = root.appendingPathComponent("server/internal/origin/testdata", isDirectory: true)
    let manifest = try JSONParser.parse([UInt8](try Data(contentsOf: dir.appendingPathComponent("manifest.json"))))
    try await a.bootstrap()
    #expect(await a.run(.authored).stop == nil)
    let gmail = FakeGmail()
    var added = 0
    for f in manifest["fixtures"]?.arrayValue ?? [] where f["dkim_d"]?.stringValue == "dib.ae" {
      guard let name = f["file"]?.stringValue, let received = f["received_at"]?.stringValue else { continue }
      let ms = try parseInstantMs(received)
      guard ms >= clock.nowMs() - 89 * 86_400_000 else { continue }
      let raw = [UInt8](try Data(contentsOf: dir.appendingPathComponent(name)))
      let lines = String(decoding: raw.prefix(64 * 1024), as: UTF8.self)
        .split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
      let header = lines.prefix { !$0.isEmpty }
      let from = header.first { $0.lowercased().hasPrefix("from:") }
        .map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) } ?? ""
      gmail.add(FakeGmail.Message(id: name, raw: raw, internalDateMs: ms, from: from))
      added += 1
    }
    #expect(added >= 3)
    let (engine, ledger) = mailbox(a, gmail: gmail, clock: clock)
    try await ledger.authorSenderTrust(domain: "dib.ae", trusted: true)
    guard case .connected = await engine.connect(presenter: ConsentPresenter(gmail: gmail), backfillDays: 90) else {
      Issue.record("connect")
      return
    }
    let done = await engine.runCycle(trigger: .launch)
    #expect(done.ops == added && done.haltedOn == nil, "\(done)")
    let rows = try a.reader.activity(limit: 50)
    #expect(rows.count == added)
    let held = rows.filter(\.heldCopy)
    #expect(held.count == 1)
    let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
    for h in held {
      let other = try #require(h.copyOf.flatMap { byID[$0] })
      #expect(h.amountMinor == other.amountMinor && h.direction == "debit" && other.direction == "debit")
      #expect(h.mailboxMessageID != other.mailboxMessageID)
    }
    for r in rows {
      let own = r.merchantRaw.uppercased().contains("OWN ACCOUNT")
      #expect((r.category == "transfer") == own, "\(r.id)")
    }
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
    // The first scan lists, stages and authors in one run: there is no cards step.
    let done = await engine.runCycle(trigger: .launch)
    #expect(done.staged == 4, "\(done)")
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
    #expect(starbucks.effectiveAccountID == nil)  // no card was linked, and none is needed
    #expect(try b.reader.review(lanes: ReviewLane.allCases).contains { $0.mailboxMessageID == "n1" && $0.unparsed })
    #expect(try b.reader.accounts().isEmpty && b.reader.cards().isEmpty)
    #expect(try await a.state().serialized() == b.state().serialized())
    // Running the lane again lists nothing new and authors nothing twice.
    let again = await engine.runCycle(trigger: .refresh)
    #expect(again.ops == 0 && again.haltedOn == nil, "\(again)")
  }
}
