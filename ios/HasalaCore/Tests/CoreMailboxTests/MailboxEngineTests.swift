// The engine over FakeGmail (spec 04 §7.4-§7.8; the fetch.ts behaviours §7.5 keeps, each pinned
// here). Every message is synthetic.
import CoreJSON
import CoreMail
import CoreMailbox
import CorePrimitives
import CoreTemplate
import CoreTestSupport
import Foundation
import Testing

let day: Int64 = 86_400_000

@Suite struct ConnectTests {
  @Test func firstConnectLinksStoresTheTokenAndStartsTheScan() async throws {
    let rig = Rig()
    let r = await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90)
    #expect(r == .connected(address: "synthetic.user@example.com"))
    #expect(try rig.keychain.read() == "fake-refresh-token")
    let puts = await rig.server.puts
    #expect(puts.count == 1)
    // Step-up over P = SHA-256(id_token).
    #expect(puts[0].1["p"] == .string(Hex.encode(sha256(Data(puts[0].0.utf8)))))
    #expect(puts[0].1["kind"] == .string("mailbox.link"))
    #expect(await rig.server.linkedProviders == [.gmail])
    let s = await rig.state()
    #expect(s.phase == .scanning && s.backfillDays == 90 && s.scanStartedMs == Rig.t0)
    #expect(s.address == "synthetic.user@example.com")
    #expect(s.profileHistoryID == "1000")
  }

  @Test func aDeniedProfileCheckIsRefusedBeforeTheLink() async throws {
    let rig = Rig()
    rig.gmail.fail("/gmail/v1/users/me/profile", with: [403], reason: "insufficientPermissions")
    #expect(await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90) == .failed(.permissionMissing))
    #expect(await rig.server.linkedProviders.isEmpty)
    #expect(try rig.keychain.read() == nil)
    #expect(await rig.state().phase == .unlinked)
  }

  @Test func aRateLimitedProfileCheckStillLinks() async {
    let rig = Rig()
    rig.gmail.fail("/gmail/v1/users/me/profile", with: [403], reason: "userRateLimitExceeded")
    #expect(await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90) != .failed(.permissionMissing))
    #expect(await rig.server.linkedProviders.isEmpty == false)
  }

  @Test func anAccountWithoutGmailIsRefusedBeforeTheLink() async throws {
    let rig = Rig()
    rig.gmail.noMailbox = true
    #expect(await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90) == .failed(.noMailbox))
    #expect(await rig.server.puts.isEmpty)
    #expect(await rig.server.linkedProviders.isEmpty)
    #expect(try rig.keychain.read() == nil)
    #expect(await rig.state().phase == .unlinked)
    #expect(rig.gmail.requests.filter { $0.path.hasPrefix("/gmail/") }.map(\.path) == ["/gmail/v1/users/me/profile"])
  }

  @Test func aGmailProbeThatFailsOtherwiseDoesNotBlockTheLink() async throws {
    let rig = Rig()
    rig.gmail.fail("/profile", with: [400])
    #expect(await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90) == .connected(address: "synthetic.user@example.com"))
    #expect(await rig.server.linkedProviders == [.gmail])
  }

  @Test func cancelledSheetChangesNothing() async {
    let rig = Rig()
    var p = FakePresenter(gmail: rig.gmail)
    p.cancel = true
    #expect(await rig.engine.connect(presenter: p, backfillDays: 90) == .cancelled)
    #expect(await rig.state().phase == .unlinked)
    #expect(await rig.server.puts.isEmpty)
  }

  @Test func missingGmailScopeIsReported() async throws {
    let rig = Rig()
    rig.gmail.omitGmailScope = true
    #expect(await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90) == .failed(.permissionMissing))
    #expect(try rig.keychain.read() == nil)
  }

  @Test func refusedStepUpLinksNothing() async throws {
    let rig = Rig(stepUpFails: true)
    #expect(await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90) == .failed(.stepUpFailed))
    #expect(await rig.server.puts.isEmpty)
    #expect(try rig.keychain.read() == nil)
  }
}

@Suite struct ScanTests {
  @Test func scanStagesThenAuthorsWithoutACardsStep() async throws {
    let rig = Rig(categorizer: GroceryCategorizer())
    rig.gmail.add(SyntheticMail.dibCard(id: "d1", dateMs: Rig.t0 - 5 * day))
    rig.gmail.add(SyntheticMail.dibCard(id: "d2", amount: "10.00", dateMs: Rig.t0 - 4 * day))
    rig.gmail.add(SyntheticMail.dibCard(id: "d3", last4: "9999", dateMs: Rig.t0 - 3 * day))
    rig.gmail.add(SyntheticMail.enbdAlert(id: "e1", dateMs: Rig.t0 - 2 * day))
    rig.gmail.add(SyntheticMail.bankNotice(id: "n1", dateMs: Rig.t0 - day))
    rig.gmail.add(SyntheticMail.dibCard(id: "old", dateMs: Rig.t0 - 120 * day))  // outside 90 days
    _ = await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90)

    // One run lists the window, stages it, then authors it: no card is asked about.
    let done = await rig.engine.runCycle(trigger: .launch)
    #expect(done.staged == 5)
    #expect(done.ops == 5 && done.review == 1 && done.toReview == 2)
    #expect(done.sortedBy == ["dictionary": 3, "none": 1, "unparsed": 1])
    #expect(done.phase == .active && done.completed)
    #expect(await rig.ledger.authoredCards.isEmpty)
    let drafts = await rig.enqueued()
    let byID = Dictionary(uniqueKeysWithValues: drafts.map { ($0.messageID, $0) })
    #expect(byID["d1"]?.needsReview == false && byID["d1"]?.payload["category"] == .string("groceries"))
    // A card the ledger doesn't know files like a known one, and the gate still records it.
    #expect(byID["d3"]?.needsReview == false && byID["d3"]?.payload["gates"]?["card"] == .string("unknown"))
    #expect(byID["d3"]?.payload["last4"] == .string("9999"))
    #expect(byID["n1"]?.payload["unparsed"] == .bool(true) && byID["n1"]?.needsReview == true)
    #expect(byID["e1"]?.needsReview == false)
    #expect(byID["old"] == nil)
    let s = await rig.state()
    #expect(s.watermarkMs == Rig.t0 && s.profileHistoryID == "1000")
    #expect(await rig.stagedCount() == 0)
    // No history.list and never an unfiltered listing (PO G).
    #expect(!rig.gmail.requests.contains { $0.path.contains("/history") })
    #expect(rig.listRequests.allSatisfy { r in r.query.contains { $0.0 == "q" && $0.1.hasPrefix("{from:") } })
  }

  @Test func aCardMarkedNotMineStillWaitsForReview() async throws {
    let rig = Rig()
    await rig.ledger.setCards([CardKey(bank: "dib", last4: "9999"): .notMine])
    rig.gmail.add(SyntheticMail.dibCard(id: "d1", dateMs: Rig.t0 - 2 * day))
    rig.gmail.add(SyntheticMail.dibCard(id: "d3", last4: "9999", dateMs: Rig.t0 - day))
    await rig.connectAndActivate()
    let byID = Dictionary(uniqueKeysWithValues: (await rig.enqueued()).map { ($0.messageID, $0) })
    #expect(byID["d1"]?.needsReview == false)
    #expect(byID["d3"]?.needsReview == true && byID["d3"]?.payload["gates"]?["card"] == .string("not_mine"))
  }

  @Test func aScanLeftAtTheRetiredCardsStepIsAuthoredOnTheNextCycle() async throws {
    let rig = Rig()
    rig.gmail.add(SyntheticMail.dibCard(id: "d1", dateMs: Rig.t0 - day))
    _ = await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 30)
    // What an older build left behind: the scan staged, waiting for "Are these your cards?".
    var parked = await rig.state()
    parked.phase = .awaitingCards
    var c = MailboxCommit()
    c.state = parked
    try await rig.store.commit(c)
    let r = await rig.engine.runCycle(trigger: .launch)
    #expect(r.phase == .active && r.completed)
  }

  @Test func inMemoryReferenceBehavesTheSame() async {
    let rig = Rig(backend: .memory)
    rig.gmail.add(SyntheticMail.dibCard(id: "d1", dateMs: Rig.t0 - day))
    rig.gmail.add(SyntheticMail.bankNotice(id: "n1", dateMs: Rig.t0 - day))
    await rig.connectAndActivate()
    #expect(await rig.state().phase == .active)
    #expect(Set(await rig.enqueued().map(\.messageID)) == ["d1", "n1"])
    rig.gmail.add(SyntheticMail.dibCard(id: "d2", amount: "2.00", dateMs: rig.clock.nowMs() - 1000))
    let r = await rig.engine.runCycle(trigger: .refresh)
    #expect(r.ops == 1 && r.review == 0 && r.completed)
  }

  @Test func scanWaitsForATrustedSender() async {
    let rig = Rig()
    await rig.ledger.setTrust([:])
    rig.gmail.add(SyntheticMail.dibCard(id: "d1", dateMs: Rig.t0 - day))
    _ = await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 30)
    #expect(await rig.engine.runCycle(trigger: .launch).phase == .scanning)
    await rig.ledger.setTrust(["dib.ae": true])
    let r = await rig.engine.runCycle(trigger: .launch)
    #expect(r.staged == 1 && r.ops == 1 && r.phase == .active)
  }

  @Test func progressIsReportedForTheFirstScanBoard() async {
    let rig = Rig()
    for i in 0..<3 { rig.gmail.add(SyntheticMail.dibCard(id: "d\(i)", dateMs: Rig.t0 - Int64(i + 1) * day)) }
    let seen = ProgressLog()
    await rig.engine.setProgressHandler { seen.append($0) }
    await rig.connectAndActivate()
    let log = seen.all
    #expect(log.contains(MailboxProgress(stage: .downloading, done: 3, total: 3)))
    #expect(log.filter { $0.stage == .authoring } == [MailboxProgress(stage: .authoring, done: 3, total: 3)])
    #expect(log.suffix(2) == [
      MailboxProgress(stage: .authoring, done: 3, total: 3), MailboxProgress(stage: .done, done: 3, total: 3),
    ])
  }

  @Test func stagingCapEndsTheListing() async {
    let rig = Rig { $0.stagingCap = 2 }
    for i in 0..<4 { rig.gmail.add(SyntheticMail.dibCard(id: "d\(i)", dateMs: Rig.t0 - Int64(i + 1) * day)) }
    _ = await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 30)
    let done = await rig.engine.runCycle(trigger: .launch)
    // The two staged rows, then the rest of the window listed again and authored directly.
    #expect(done.staged == 2 && done.haltedOn == .stagingFull)
    #expect(done.ops == 4 && done.review == 0 && done.phase == .active)
    #expect(Set(await rig.enqueued().map(\.messageID)) == ["d0", "d1", "d2", "d3"])
  }

  /// gmail-sync: an account deleted on this iPhone, then a new account linking the SAME
  /// mailbox here. Nothing the first account's lane kept (its accounted ids, watermark,
  /// staged rows, refresh token) belongs to the second one, which has its own store and
  /// Keychain item, so the second scan reads the whole window again and authors it all
  /// under its own grant id.
  @Test func aNewAccountOnTheSameMailboxReadsItInFull() async throws {
    let gmail = FakeGmail()
    gmail.add(SyntheticMail.dibCard(id: "d1", dateMs: Rig.t0 - 5 * day))
    gmail.add(SyntheticMail.enbdAlert(id: "e1", dateMs: Rig.t0 - 2 * day))
    let first = Rig(gmail: gmail) { $0.grantID = "00000000-0000-4000-8000-00000000000a" }
    await first.connectAndActivate()
    #expect(Set(await first.enqueued().map(\.messageID)) == ["d1", "e1"])
    #expect(await first.state().phase == .active)

    // The first account is deleted (its store and Keychain item go); a new one links the
    // same Google account with a new consent.
    gmail.refreshToken = "fake-refresh-token-second-account"
    let second = Rig(gmail: gmail) { $0.grantID = "00000000-0000-4000-8000-00000000000b" }
    let r = await second.engine.connect(presenter: FakePresenter(gmail: gmail), backfillDays: 90)
    #expect(r == .connected(address: "synthetic.user@example.com"))
    let done = await second.engine.runCycle(trigger: .refresh)
    #expect(done.ops == 2 && done.phase == .active && done.haltedOn == nil)
    let drafts = await second.enqueued()
    #expect(Set(drafts.map(\.messageID)) == ["d1", "e1"])
    let grant = MailboxEngineConfig(grantID: "00000000-0000-4000-8000-00000000000b")
      .grantID(provider: .gmail, address: "synthetic.user@example.com")
    #expect(grant.hasPrefix("00000000-0000-4000-8000-00000000000b/mbx-"))
    #expect(drafts.allSatisfy { $0.payload["provenance"]?["grant_id"] == .string(grant) })
    #expect(try second.keychain.read() == "fake-refresh-token-second-account")
  }
}

@Suite struct CycleTests {
  @Test func spamOrMailForAnotherMailboxWaitsForReview() async throws {
    let rig = Rig()
    var spam = SyntheticMail.dibCard(id: "sp1", dateMs: Rig.t0 - 3 * day)
    spam.spam = true
    rig.gmail.add(spam)
    rig.gmail.add(SyntheticMail.dibCard(id: "to1", dateMs: Rig.t0 - 2 * day, to: "someone.else@example.net"))
    rig.gmail.add(SyntheticMail.dibCard(id: "ok1", dateMs: Rig.t0 - day))
    _ = await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90)
    _ = await rig.engine.runCycle(trigger: .launch)
    rig.clock.advance(3_600_000)
    var later = SyntheticMail.dibCard(id: "sp2", dateMs: rig.clock.nowMs() - 60_000)
    later.spam = true
    rig.gmail.add(later)
    rig.gmail.add(SyntheticMail.dibCard(id: "to2", dateMs: rig.clock.nowMs() - 50_000, to: "someone.else@example.net"))
    rig.gmail.historyID = "1001"
    _ = await rig.engine.runCycle(trigger: .silentPush)
    let byID = Dictionary(uniqueKeysWithValues: await rig.enqueued().map { ($0.messageID, $0) })
    #expect(byID.count == 5)
    for id in ["sp1", "to1", "sp2", "to2"] {
      #expect(byID[id]?.needsReview == true && byID[id]?.payload["amount_minor"] == .string("25000"), "\(id)")
    }
    #expect(byID["ok1"]?.needsReview == false)
  }

  @Test func newMailBecomesAnOpOnceAndNeverDownloadsTwice() async throws {
    let rig = Rig()
    await rig.connectAndActivate()
    rig.clock.advance(3_600_000)
    rig.gmail.add(SyntheticMail.dibCard(id: "new1", dateMs: rig.clock.nowMs() - 60_000))
    rig.gmail.historyID = "1001"
    let r = await rig.engine.runCycle(trigger: .silentPush)
    #expect(r.ops == 1 && r.review == 0 && r.completed)  // a card the ledger does not know files itself
    #expect(await rig.ledger.flushes >= 1)
    let s = await rig.state()
    #expect(s.watermarkMs == rig.clock.nowMs() && s.profileHistoryID == "1001")

    rig.gmail.clearRequests()
    rig.gmail.historyID = "1002"
    let again = await rig.engine.runCycle(trigger: .silentPush)
    #expect(again.ops == 0 && again.listed == 1)
    #expect(rig.rawRequests.isEmpty)  // accounted: never re-downloaded
    #expect(await rig.enqueued().count == 1)
  }

  @Test func unchangedHistoryIdSkipsTheListing() async {
    let rig = Rig()
    await rig.connectAndActivate()
    rig.gmail.clearRequests()
    let r = await rig.engine.runCycle(trigger: .silentPush)
    #expect(r.completed && r.listed == 0)
    #expect(rig.listRequests.isEmpty)
    // A pull-to-refresh lists anyway.
    _ = await rig.engine.runCycle(trigger: .refresh)
    #expect(!rig.listRequests.isEmpty)
  }

  @Test func projectedMessagesAreNotDownloaded() async {
    let rig = Rig()
    await rig.connectAndActivate()
    rig.gmail.add(SyntheticMail.dibCard(id: "peer", dateMs: rig.clock.nowMs() - 1000))
    await rig.ledger.setProjected(["peer"])
    rig.gmail.clearRequests()
    let r = await rig.engine.runCycle(trigger: .refresh)
    #expect(r.ops == 0 && r.listed == 1)
    #expect(rig.gmail.requests.allSatisfy { !$0.path.hasSuffix("/peer") })
  }

  @Test func ingestedElsewhereIsADup() async {
    let rig = Rig()
    await rig.connectAndActivate()
    let m = SyntheticMail.dibCard(id: "dup", dateMs: rig.clock.nowMs() - 1000)
    rig.gmail.add(m)
    await rig.ledger.setIngested([Hex.encode(sha256(Data(m.raw)))])
    let r = await rig.engine.runCycle(trigger: .refresh)
    #expect(r.ops == 0 && r.dup == 1 && r.completed)
    #expect(await rig.accounted("dup") == .dup)
  }

  @Test func lookAlikeIsSetAsideWithoutItsBody() async {
    let rig = Rig()
    await rig.connectAndActivate()
    var m = SyntheticMail.lookAlike(id: "fake", dateMs: rig.clock.nowMs() - 1000, listedAs: "emiratesnbd.com")
    m.from = "Emirates NBD <alerts@emiratesnbd.com>"  // what Gmail's from: matched (display name)
    rig.gmail.add(m)
    rig.gmail.clearRequests()
    let r = await rig.engine.runCycle(trigger: .refresh)
    #expect(r.setAside == 1 && r.ops == 0)
    #expect(rig.rawRequests.isEmpty)  // only From + A-R were read
    let status = await rig.engine.status()
    #expect(status.setAside.map(\.domain) == ["promo.example"])
  }

  @Test func goneMessagesAreAccountedAndTheCycleMovesOn() async {
    let rig = Rig()
    await rig.connectAndActivate()
    rig.gmail.add(SyntheticMail.dibCard(id: "deleted", dateMs: rig.clock.nowMs() - 2000))
    rig.gmail.add(SyntheticMail.dibCard(id: "ok", amount: "1.00", dateMs: rig.clock.nowMs() - 1000))
    rig.gmail.fail("/messages/deleted", with: [404])
    let r = await rig.engine.runCycle(trigger: .refresh)
    #expect(r.unreadable == 1 && r.ops == 1 && r.completed)
    #expect(await rig.unreadableReasons() == [.gone])
  }

  @Test func rateLimitRetriesThenSucceeds() async {
    let rig = Rig()
    await rig.connectAndActivate()
    rig.gmail.add(SyntheticMail.dibCard(id: "slow", dateMs: rig.clock.nowMs() - 1000))
    rig.gmail.fail("/messages/slow", with: [429, 503])
    let r = await rig.engine.runCycle(trigger: .refresh)
    #expect(r.ops == 1 && r.completed)
  }

  @Test func persistentFailureKeepsTheWatermark() async {
    let rig = Rig()
    await rig.connectAndActivate()
    let before = await rig.state().watermarkMs
    rig.clock.advance(3_600_000)
    rig.gmail.add(SyntheticMail.dibCard(id: "flaky", dateMs: rig.clock.nowMs() - 1000))
    rig.gmail.fail("/messages/flaky", with: [500, 500, 500])
    let r = await rig.engine.runCycle(trigger: .refresh)
    #expect(r.haltedOn == .gmail && !r.completed)
    #expect(await rig.state().watermarkMs == before)
    // The next run reads it.
    let r2 = await rig.engine.runCycle(trigger: .refresh)
    #expect(r2.ops == 1 && r2.completed)
  }

  @Test func accountFullHaltsWithTheWatermarkIntactAndRetryResumes() async {
    let rig = Rig()
    await rig.connectAndActivate()
    let before = await rig.state().watermarkMs
    rig.clock.advance(3_600_000)
    rig.gmail.add(SyntheticMail.dibCard(id: "big", dateMs: rig.clock.nowMs() - 1000))
    await rig.ledger.setFlush(.accountFull)
    let r = await rig.engine.runCycle(trigger: .refresh)
    #expect(r.haltedOn == .accountFull && r.phase == .halted)
    #expect(await rig.state().watermarkMs == before)
    #expect(await rig.engine.runCycle(trigger: .silentPush).haltedOn == .accountFull)  // stays halted
    await rig.ledger.setFlush(.flushed)
    let retry = await rig.engine.runCycle(trigger: .retry)
    #expect(retry.phase == .active && retry.completed && retry.ops == 0)  // the op was already queued
    #expect(await rig.enqueued().filter { $0.messageID == "big" }.count == 1)
  }

  @Test func accountFullIsAPauseThatProbesAgain() async {
    let rig = Rig()
    await rig.connectAndActivate()
    rig.clock.advance(3_600_000)
    rig.gmail.add(SyntheticMail.dibCard(id: "big", dateMs: rig.clock.nowMs() - 1000))
    await rig.ledger.setFlush(.accountFull)
    #expect(await rig.engine.runCycle(trigger: .refresh).haltedOn == .accountFull)
    rig.clock.advance(60_000)
    #expect(await rig.engine.runCycle(trigger: .timer).haltedOn == .accountFull)
    await rig.ledger.setFlush(.flushed)
    rig.clock.advance(15 * 60_000)
    let timed = await rig.engine.runCycle(trigger: .timer)
    #expect(timed.phase == .active && timed.completed)

    await rig.ledger.setFlush(.accountFull)
    rig.clock.advance(3_600_000)
    rig.gmail.add(SyntheticMail.dibCard(id: "big2", amount: "9.00", dateMs: rig.clock.nowMs() - 1000))
    #expect(await rig.engine.runCycle(trigger: .refresh).haltedOn == .accountFull)
    await rig.ledger.setFlush(.flushed)
    let fg = await rig.engine.runCycle(trigger: .foreground)
    #expect(fg.phase == .active && fg.completed)
  }

  @Test func deadlineCutKeepsTheWatermarkAndResumesWithoutRedownloading() async {
    let rig = Rig { $0.downloadWidth = 1 }
    await rig.connectAndActivate()
    let before = await rig.state().watermarkMs
    for i in 0..<3 { rig.gmail.add(SyntheticMail.dibCard(id: "c\(i)", amount: "\(i + 1).00", dateMs: rig.clock.nowMs() - Int64(i + 1) * 1000)) }
    rig.gmail.historyID = "2000"  // new mail moves the mailbox's historyId
    rig.gmail.fail("/messages/c1", with: [503])  // costs 400 ms of (fake) backoff, pushing past the deadline
    let r = await rig.engine.runCycle(trigger: .appRefresh, deadlineMs: rig.clock.nowMs() + 5_200)
    #expect(!r.completed && r.ops >= 1 && r.ops < 3)
    #expect(await rig.state().watermarkMs == before)
    rig.gmail.clearRequests()
    let r2 = await rig.engine.runCycle(trigger: .appRefresh)
    #expect(r2.completed && r.ops + r2.ops == 3)
    #expect(rig.rawRequests.count == 3 - r.ops)
  }

  @Test func aGmailServiceThatIsTurnedOffHaltsWithItsOwnReason() async {
    let rig = Rig()
    await rig.connectAndActivate()
    rig.gmail.noMailbox = true
    let r = await rig.engine.runCycle(trigger: .refresh)
    #expect(r.haltedOn == .noMailbox)
    #expect(await rig.state().phase == .halted)
  }

  @Test func revokedGrantAsksToReconnect() async {
    let rig = Rig()
    await rig.connectAndActivate()
    await rig.tokens.invalidate()
    rig.gmail.invalidGrant = true
    let r = await rig.engine.runCycle(trigger: .refresh)
    #expect(r.haltedOn == .reconnectRequired && r.phase == .reconnectRequired)
    #expect(try! rig.keychain.read() == nil)
    #expect(await rig.engine.status().hero == .needsYou)
  }

  @Test func lockedKeychainIsNotNow() async {
    let rig = Rig()
    await rig.connectAndActivate()
    await rig.tokens.invalidate()
    rig.keychain.locked = true
    let r = await rig.engine.runCycle(trigger: .appRefresh)
    #expect(r.haltedOn == nil && !r.completed && r.phase == .active)
  }

  @Test func anotherHolderStopsThisDeviceAndForgetsItsOwnToken() async throws {
    let rig = Rig()
    await rig.connectAndActivate()
    await rig.server.setLink(.holder(isThisDevice: false, watchExpiresAtMs: nil))
    let r = await rig.engine.runCycle(trigger: .launch)
    #expect(r.phase == .otherDevice && r.haltedOn == .notHolder)
    #expect(try rig.keychain.read() == nil)
    // Deleted here but never revoked at Google: a revoke would end the new holder's grant too.
    #expect(!rig.gmail.requests.contains { $0.form.contains { $0.0 == "token" } })
    #expect(!rig.gmail.requests.contains { $0.path.hasSuffix("/stop") })  // never users.stop
    #expect(await rig.engine.status().hero == .otherDevice)
  }

  @Test func lostLinkAsksToReconnect() async {
    let rig = Rig()
    await rig.connectAndActivate()
    await rig.server.setLink(.noLink)
    let r = await rig.engine.runCycle(trigger: .launch)
    #expect(r.phase == .reconnectRequired)
  }

  @Test func watchIsRenewedAndReportedOnlyWithATopic() async {
    let rig = Rig()
    await rig.connectAndActivate()
    #expect(rig.gmail.requests.contains { $0.path.hasSuffix("/watch") })
    #expect(await rig.server.watches == [Rig.t0 + 7 * day])
    #expect(await rig.state().watchExpiresAtMs == Rig.t0 + 7 * day)

    let quiet = Rig()
    await quiet.server.setTopic(nil)
    await quiet.connectAndActivate()
    #expect(!quiet.gmail.requests.contains { $0.path.hasSuffix("/watch") })
    #expect(await quiet.engine.status().watchActive == false)
  }

  /// A server whose Pub/Sub push is turned on after the app read a null topic: the topic is read
  /// again once per holder-check interval, and the next due cycle watches and reports.
  @Test func aTopicTheServerGainsLaterIsWatchedWithoutARelaunch() async {
    let rig = Rig()
    await rig.server.setTopic(nil)
    await rig.connectAndActivate()
    #expect(!rig.gmail.requests.contains { $0.path.hasSuffix("/watch") })
    let reads = await rig.server.topicReads
    #expect(reads == 1)

    await rig.server.setTopic("projects/synthetic/topics/hasala-gmail-test")
    _ = await rig.engine.runCycle(trigger: .refresh)
    #expect(await rig.server.topicReads == reads)  // inside the interval: the null topic stands
    #expect(!rig.gmail.requests.contains { $0.path.hasSuffix("/watch") })

    rig.clock.advance(MailboxEngineConfig(grantID: "x").holderCheckIntervalMs)
    _ = await rig.engine.runCycle(trigger: .refresh)
    #expect(await rig.server.topicReads == reads + 1)
    #expect(rig.gmail.requests.contains { $0.path.hasSuffix("/watch") })
    #expect(await rig.server.watches == [Rig.t0 + 7 * day])
    #expect(await rig.engine.status().watchActive)
  }

  /// A clock that jumps back after a null topic was read does not postpone the re-read until it
  /// catches up: the next cycle reads the topic again.
  @Test func aBackwardsClockJumpDoesNotPostponeTheTopicReRead() async {
    let rig = Rig()
    await rig.server.setTopic(nil)
    await rig.connectAndActivate()
    let reads = await rig.server.topicReads
    #expect(reads == 1)

    await rig.server.setTopic("projects/synthetic/topics/hasala-gmail-test")
    rig.clock.advance(-day)
    _ = await rig.engine.runCycle(trigger: .refresh)
    #expect(await rig.server.topicReads == reads + 1)
    #expect(rig.gmail.requests.contains { $0.path.hasSuffix("/watch") })
  }

  /// Route 36's `409 no_watch_topic`: the server turned its Pub/Sub push off after the app read
  /// the topic. The watch nobody relays is stopped, no live watch is shown, and the topic is read
  /// again (null now), so no further watch is made.
  @Test func aWatchTheServerNoLongerRelaysIsStoppedAndTheTopicReadAgain() async {
    let rig = Rig()
    await rig.connectAndActivate()
    #expect(await rig.server.watches == [Rig.t0 + 7 * day])
    #expect(!rig.gmail.requests.contains { $0.path.hasSuffix("/stop") })

    await rig.server.setTopic(nil)
    await rig.server.setWatchRefusal(.noWatchTopic)
    rig.clock.advance(5 * day)  // the watch is due for renewal (inside the 3-day window)
    _ = await rig.engine.runCycle(trigger: .refresh)
    #expect(rig.gmail.requests.filter { $0.path.hasSuffix("/watch") }.count == 2)
    #expect(rig.gmail.requests.contains { $0.path.hasSuffix("/stop") })
    #expect(await rig.state().watchExpiresAtMs == nil)
    #expect(await rig.engine.status().watchActive == false)

    let reads = await rig.server.topicReads
    _ = await rig.engine.runCycle(trigger: .refresh)
    #expect(await rig.server.topicReads == reads + 1)
    #expect(rig.gmail.requests.filter { $0.path.hasSuffix("/watch") }.count == 2)
  }

  @Test func noTrustedSenderListsNothing() async {
    let rig = Rig()
    await rig.ledger.setTrust([:])
    await rig.connectAndActivate()
    _ = await rig.engine.runCycle(trigger: .refresh)
    #expect(rig.listRequests.isEmpty)
  }

  @Test func addASenderTrustsAndImportsWithoutMovingTheWatermark() async throws {
    let rig = Rig()
    await rig.connectAndActivate()
    let before = await rig.state().watermarkMs
    let raw = SyntheticMail.rfc822(
      from: "Alerts <alerts@newbank.example>", subject: "Notice", body: "Hello", dateMs: Rig.t0 - 3 * day,
      authDomain: "newbank.example")
    rig.gmail.add(FakeGmail.Message(id: "nb1", raw: raw, internalDateMs: Rig.t0 - 3 * day, from: "Alerts <alerts@newbank.example>"))
    let r = try await rig.engine.importSender("alerts@NewBank.example").get()
    #expect(r.ops == 1 && r.review == 1)
    #expect(await rig.ledger.authoredTrust.map(\.0) == ["newbank.example"])
    #expect(await rig.state().watermarkMs == before)
    if case .failure(let e) = await rig.engine.importSender("x@gmail.com") { #expect(e == .forwarder) } else { Issue.record("forwarder accepted") }
  }

  @Test func probeSendersListsIdsOnly() async {
    let rig = Rig()
    #expect(await rig.engine.probeSenders(["newbank.example"]) == .notReading)
    await rig.connectAndActivate()
    let raw = SyntheticMail.rfc822(
      from: "Alerts <alerts@newbank.example>", subject: "Notice", body: "Hello", dateMs: Rig.t0 - 3 * day,
      authDomain: "newbank.example")
    rig.gmail.add(FakeGmail.Message(id: "nb1", raw: raw, internalDateMs: Rig.t0 - 3 * day, from: "Alerts <alerts@newbank.example>"))
    let before = rig.gmail.requests.count
    let accounted = await rig.accountedCount()
    let r = await rig.engine.probeSenders(["NewBank.example", "other.example", "bad domain", "newbank.example"])
    #expect(r == .found(["newbank.example"]))
    let made = rig.gmail.requests.dropFirst(before)
    #expect(made.count == 2)
    #expect(made.allSatisfy { $0.path.hasSuffix("/messages") })
    #expect(await rig.ledger.authoredTrust.isEmpty)
    #expect(await rig.accountedCount() == accounted)
  }

  @Test func viewEmailShowsNormalizedTextOnly() async {
    let rig = Rig()
    await rig.connectAndActivate()
    rig.gmail.add(SyntheticMail.enbdAlert(id: "v1", dateMs: Rig.t0))
    let v = await rig.engine.viewEmail(messageID: "v1")
    guard case .ready(let subject, let text) = v else {
      Issue.record("not ready: \(v)")
      return
    }
    #expect(subject.contains("8642"))
    #expect(text.contains("has been debited"))
    #expect(await rig.engine.viewEmail(messageID: "missing") == .gone)
  }

  @Test func disconnectStopsRevokesUnlinksAndClears() async throws {
    let rig = Rig()
    await rig.connectAndActivate()
    #expect(await rig.engine.disconnect())
    #expect(rig.gmail.requests.contains { $0.path.hasSuffix("/stop") })
    // Google's grant is revoked (`POST /revoke token=<refresh>`), not only forgotten here.
    #expect(rig.gmail.requests.contains { $0.form.contains { $0.0 == "token" } })
    #expect(try rig.keychain.read() == nil)
    #expect(await rig.server.deletes == 1)
    #expect(await rig.state().phase == .unlinked)
    #expect(await rig.accountedCount() == 0)
  }

  /// The Disconnect alert says Hasala ends its access at Google: a revoke that didn't go
  /// through (a Google 5xx, offline) stops the disconnect with the token kept, the link and
  /// the tables untouched, and the retry revokes it.
  @Test func aFailedRevokeKeepsTheTokenAndTheLink() async throws {
    let rig = Rig()
    await rig.connectAndActivate()
    let token = try rig.keychain.read()
    #expect(token != nil)
    rig.gmail.fail("/revoke", with: [503])
    #expect(await rig.engine.disconnect() == false)
    #expect(try rig.keychain.read() == token)
    #expect(await rig.server.deletes == 0)
    #expect(await rig.state().phase == .active)
    rig.gmail.offline = true
    #expect(await rig.engine.disconnect() == false)
    #expect(try rig.keychain.read() == token)
    #expect(await rig.server.deletes == 0)
    rig.gmail.offline = false
    rig.gmail.clearRequests()
    #expect(await rig.engine.disconnect())
    #expect(rig.gmail.requests.contains { $0.path.hasSuffix("/revoke") && $0.form.contains { $0 == ("token", token!) } })
    #expect(try rig.keychain.read() == nil)
    #expect(await rig.server.deletes == 1)
    #expect(await rig.state().phase == .unlinked)
  }

  /// A token Google no longer knows (400) is gone either way: the disconnect goes on.
  @Test func aRevokeOfAnUnknownTokenStillDisconnects() async throws {
    let rig = Rig()
    await rig.connectAndActivate()
    rig.gmail.fail("/revoke", with: [400])
    #expect(await rig.engine.disconnect())
    #expect(try rig.keychain.read() == nil)
    #expect(await rig.server.deletes == 1)
  }

  @Test func concurrentTriggersAreSingleFlight() async {
    let rig = Rig()
    await rig.connectAndActivate()
    rig.gmail.add(SyntheticMail.dibCard(id: "x", dateMs: rig.clock.nowMs() - 1000))
    async let a = rig.engine.runCycle(trigger: .refresh)
    async let b = rig.engine.runCycle(trigger: .refresh)
    let (ra, rb) = await (a, b)
    #expect(ra.ops + rb.ops == 1)
    #expect(await rig.enqueued().filter { $0.messageID == "x" }.count == 1)
  }
}

/// The interruptions the review of the first lane found: a reconnect, a takeover or a crash
/// during first-connect setup must resume the phase it cut short, never restart the scan.
@Suite struct InterruptionTests {
  /// A scan that staged two alerts and was cut before authoring them (as a deadline or a
  /// killed app leaves it): the next cycle runs the backfill.
  static func stageTwoAndCut(_ rig: Rig) async throws {
    let d1 = SyntheticMail.dibCard(id: "d1", dateMs: Rig.t0 - 3 * day)
    let e1 = SyntheticMail.enbdAlert(id: "e1", dateMs: Rig.t0 - 2 * day)
    rig.gmail.add(d1)
    rig.gmail.add(e1)
    _ = await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90)
    let trusted = ["dib.ae", "emiratesnbd.com"]
    let templates = BundledTemplates.load(channel: .mail).templates
    var c = MailboxCommit()
    for m in [d1, e1] {
      guard
        case .mail(let p) = MessageDisposer.parse(
          raw: m.raw, messageID: m.id, internalDateMs: m.internalDateMs, topLevelFrom: m.from, templates: templates,
          bankDomains: trusted, trusted: trusted, provider: .gmail, linkedAddress: SyntheticMail.defaultTo, spam: false, analyze: AuthResults.analyze)
      else { throw CancellationError() }
      c.stage.append(p)
    }
    var s = await rig.state()
    s.phase = .authoringBackfill
    c.state = s
    try await rig.store.commit(c)
    #expect(await rig.stagedCount() == 2)
  }

  @Test func reconnectDuringTheBackfillResumesIt() async throws {
    let rig = Rig()
    try await Self.stageTwoAndCut(rig)
    await rig.tokens.invalidate()
    rig.gmail.invalidGrant = true
    let cut = await rig.engine.runCycle(trigger: .launch)
    #expect(cut.phase == .reconnectRequired && cut.ops == 0)
    #expect(await rig.state().haltedDetail == "resume:authoring_backfill")

    rig.gmail.invalidGrant = false
    #expect(await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 30) != .cancelled)
    let s = await rig.state()
    #expect(s.phase == .authoringBackfill && s.scanStartedMs == Rig.t0 && s.backfillDays == 90)
    let done = await rig.engine.runCycle(trigger: .launch)
    #expect(done.phase == .active && done.completed && done.ops == 2 && done.review == 0)
    #expect(await rig.ledger.authoredCards.isEmpty)
    #expect(Set(await rig.enqueued().map(\.messageID)) == ["d1", "e1"])
  }

  @Test func retryAfterReconnectRequiredResumesTheBackfill() async throws {
    let rig = Rig()
    try await Self.stageTwoAndCut(rig)
    await rig.tokens.invalidate()
    rig.gmail.invalidGrant = true
    _ = await rig.engine.runCycle(trigger: .launch)
    // The grant comes back (e.g. a blip at Google): "Try again" resumes the backfill.
    rig.gmail.invalidGrant = false
    try? rig.keychain.write("fake-refresh-token")
    let r = await rig.engine.runCycle(trigger: .retry)
    #expect(r.phase == .active && r.ops == 2)
  }

  @Test func takeoverDuringTheBackfillResumesItAfterReadThemHereInstead() async throws {
    let rig = Rig()
    try await Self.stageTwoAndCut(rig)
    rig.clock.advance(11 * 60_000)  // the holder check is due again
    await rig.server.setLink(.holder(isThisDevice: false, watchExpiresAtMs: nil))
    let cut = await rig.engine.runCycle(trigger: .launch)
    #expect(cut.phase == .otherDevice && cut.ops == 0)
    #expect(try rig.keychain.read() == nil)

    _ = await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90)
    #expect(await rig.state().phase == .authoringBackfill)
    let done = await rig.engine.runCycle(trigger: .launch)
    #expect(done.phase == .active && done.ops == 2)
  }

  @Test func reconnectDuringTheScanKeepsItsWindow() async {
    let rig = Rig()
    rig.gmail.add(SyntheticMail.dibCard(id: "d1", dateMs: Rig.t0 - 3 * day))
    _ = await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90)
    await rig.tokens.invalidate()
    rig.gmail.invalidGrant = true
    #expect(await rig.engine.runCycle(trigger: .launch).phase == .reconnectRequired)
    rig.gmail.invalidGrant = false
    rig.clock.advance(day)
    _ = await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 30)
    let s = await rig.state()
    #expect(s.phase == .scanning && s.scanStartedMs == Rig.t0 && s.backfillDays == 90)
    #expect(await rig.engine.runCycle(trigger: .launch).phase == .active)
  }

}

@Suite struct ListingAndErrorTests {
  @Test func gmailQuota403IsARetryNotAReconnect() async {
    let rig = Rig()
    await rig.connectAndActivate()
    rig.gmail.add(SyntheticMail.dibCard(id: "busy", dateMs: rig.clock.nowMs() - 1000))
    rig.gmail.fail("/messages/busy", with: [403, 403], reason: "userRateLimitExceeded")
    let r = await rig.engine.runCycle(trigger: .refresh)
    #expect(r.ops == 1 && r.completed && r.phase == .active)

    // Persisting past the retries is a transient halt, never "Reconnect Gmail".
    rig.gmail.add(SyntheticMail.dibCard(id: "busier", amount: "3.00", dateMs: rig.clock.nowMs() - 500))
    rig.gmail.fail("/messages/busier", with: [403, 403, 403, 403, 403], reason: "rateLimitExceeded")
    let r2 = await rig.engine.runCycle(trigger: .refresh)
    #expect(r2.haltedOn == .gmail && r2.phase == .active)
  }

  @Test func gmailPermission403AsksToReconnect() async {
    let rig = Rig()
    await rig.connectAndActivate()
    rig.gmail.add(SyntheticMail.dibCard(id: "nope", dateMs: rig.clock.nowMs() - 1000))
    rig.gmail.fail("/messages/nope", with: [403], reason: "insufficientPermissions")
    let r = await rig.engine.runCycle(trigger: .refresh)
    #expect(r.haltedOn == .reconnectRequired && r.phase == .reconnectRequired)
  }

  @Test func anotherClientErrorHaltsAndTryAgainResumes() async {
    let rig = Rig()
    await rig.connectAndActivate()
    let before = await rig.state().watermarkMs
    rig.gmail.add(SyntheticMail.dibCard(id: "odd", dateMs: rig.clock.nowMs() - 1000))
    rig.gmail.fail("/messages/odd", with: [400])
    let r = await rig.engine.runCycle(trigger: .refresh)
    #expect(r.haltedOn == .gmail && r.phase == .halted)
    #expect(await rig.state().watermarkMs == before)
    #expect(await rig.engine.status().hero == .needsYou)
    let retry = await rig.engine.runCycle(trigger: .retry)
    #expect(retry.phase == .active && retry.ops == 1 && retry.completed)
  }

  @Test func deadlineRunsDownloadEachPageBeforeListingTheNext() async {
    let rig = Rig()
    await rig.connectAndActivate()
    rig.gmail.pageSize = 2
    for i in 0..<5 { rig.gmail.add(SyntheticMail.dibCard(id: "p\(i)", amount: "\(i + 1).00", dateMs: rig.clock.nowMs() - Int64(i + 1) * 1000)) }
    rig.gmail.historyID = "3000"
    rig.gmail.clearRequests()
    let r = await rig.engine.runCycle(trigger: .appRefresh, deadlineMs: rig.clock.nowMs() + 60_000)
    #expect(r.completed && r.ops == 5 && r.listed == 5)
    let paths = rig.gmail.requests.map { r in r.path.hasSuffix("/messages") ? "list" : (r.query.contains { $0 == ("format", "raw") } ? "raw" : "") }
    let firstRaw = paths.firstIndex(of: "raw") ?? Int.max
    let lastList = paths.lastIndex(of: "list") ?? -1
    #expect(firstRaw < lastList)  // interleaved, not "list everything first"
    #expect(paths.filter { $0 == "list" }.count == 3)
  }

  @Test func aSpentDeadlineListsNothing() async {
    let rig = Rig()
    await rig.connectAndActivate()
    let before = await rig.state().watermarkMs
    rig.gmail.add(SyntheticMail.dibCard(id: "late", dateMs: rig.clock.nowMs() - 1000))
    rig.gmail.historyID = "3001"
    rig.gmail.clearRequests()
    let r = await rig.engine.runCycle(trigger: .appRefresh, deadlineMs: rig.clock.nowMs() + 1_000)
    #expect(!r.completed && r.listed == 0)
    #expect(rig.listRequests.isEmpty)
    #expect(await rig.state().watermarkMs == before)
  }

  @Test func pagedScanStillFinishesTheBackfill() async {
    let rig = Rig()
    rig.gmail.pageSize = 2
    for i in 0..<5 { rig.gmail.add(SyntheticMail.dibCard(id: "s\(i)", dateMs: Rig.t0 - Int64(i + 1) * day)) }
    _ = await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 30)
    let r = await rig.engine.runCycle(trigger: .processing)
    #expect(r.staged == 5 && r.ops == 5 && r.phase == .active)
  }
}

final class ProgressLog: @unchecked Sendable {
  private let lock = NSLock()
  private var items: [MailboxProgress] = []
  func append(_ p: MailboxProgress) { lock.withLock { items.append(p) } }
  var all: [MailboxProgress] { lock.withLock { items } }
}
