// The engine over FakeGmail (spec 04 §7.4-§7.8; the fetch.ts behaviours §7.5 keeps, each pinned
// here). Every message is synthetic.
import CoreJSON
import CoreMailbox
import CorePrimitives
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
    let s = await rig.store.state
    #expect(s.phase == .scanning && s.backfillDays == 90 && s.scanStartedMs == Rig.t0)
    #expect(s.address == "synthetic.user@example.com")
    #expect(s.profileHistoryID == "1000")
  }

  @Test func cancelledSheetChangesNothing() async {
    let rig = Rig()
    var p = FakePresenter(gmail: rig.gmail)
    p.cancel = true
    #expect(await rig.engine.connect(presenter: p, backfillDays: 90) == .cancelled)
    #expect(await rig.store.state.phase == .unlinked)
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
  @Test func scanStagesThenAuthorsAfterTheCardsAreConfirmed() async throws {
    let rig = Rig(categorizer: GroceryCategorizer())
    rig.gmail.add(SyntheticMail.dibCard(id: "d1", dateMs: Rig.t0 - 5 * day))
    rig.gmail.add(SyntheticMail.dibCard(id: "d2", amount: "10.00", dateMs: Rig.t0 - 4 * day))
    rig.gmail.add(SyntheticMail.dibCard(id: "d3", last4: "9999", dateMs: Rig.t0 - 3 * day))
    rig.gmail.add(SyntheticMail.enbdAlert(id: "e1", dateMs: Rig.t0 - 2 * day))
    rig.gmail.add(SyntheticMail.bankNotice(id: "n1", dateMs: Rig.t0 - day))
    rig.gmail.add(SyntheticMail.dibCard(id: "old", dateMs: Rig.t0 - 120 * day))  // outside 90 days
    _ = await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90)

    let scan = await rig.engine.runCycle(trigger: .launch)
    #expect(scan.staged == 5 && scan.ops == 0)
    #expect(scan.phase == .awaitingCards)
    #expect(await rig.store.enqueued.isEmpty)  // the scan never authors (§7.7 step 7)

    let summary = await rig.engine.scanSummary()
    #expect(summary.cards.map(\.card) == [CardKey(bank: "dib", last4: "1234"), CardKey(bank: "dib", last4: "9999"), CardKey(bank: "enbd", last4: "8642")])
    #expect(summary.cards.map(\.count) == [2, 1, 1])
    #expect(summary.withoutCard == 1)

    let done = await rig.engine.confirmCards([
      CardDecision(card: CardKey(bank: "dib", last4: "1234"), state: .mine),
      CardDecision(card: CardKey(bank: "dib", last4: "9999"), state: .notMine),
      CardDecision(card: CardKey(bank: "enbd", last4: "8642"), state: .mine),
    ])
    #expect(done.ops == 5 && done.review == 2)
    #expect(done.phase == .active && done.completed)
    #expect(await rig.ledger.authoredCards.count == 3)
    let drafts = await rig.store.enqueued
    let byID = Dictionary(uniqueKeysWithValues: drafts.map { ($0.messageID, $0) })
    #expect(byID["d1"]?.needsReview == false && byID["d1"]?.payload["category"] == .string("groceries"))
    #expect(byID["d3"]?.needsReview == true && byID["d3"]?.payload["gates"]?["card"] == .string("not_mine"))
    #expect(byID["n1"]?.payload["unparsed"] == .bool(true))
    #expect(byID["e1"]?.needsReview == false)
    let s = await rig.store.state
    #expect(s.watermarkMs == Rig.t0 && s.profileHistoryID == "1000")
    #expect(await rig.store.staging.isEmpty)
    // No history.list and never an unfiltered listing (PO G).
    #expect(!rig.gmail.requests.contains { $0.path.contains("/history") })
    #expect(rig.listRequests.allSatisfy { r in r.query.contains { $0.0 == "q" && $0.1.hasPrefix("{from:") } })
  }

  @Test func scanWaitsForATrustedSender() async {
    let rig = Rig()
    await rig.ledger.setTrust([:])
    rig.gmail.add(SyntheticMail.dibCard(id: "d1", dateMs: Rig.t0 - day))
    _ = await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 30)
    #expect(await rig.engine.runCycle(trigger: .launch).phase == .scanning)
    await rig.ledger.setTrust(["dib.ae": true])
    let r = await rig.engine.runCycle(trigger: .launch)
    #expect(r.staged == 1 && r.phase == .awaitingCards)
  }

  @Test func stagingCapEndsTheListing() async {
    let rig = Rig { $0.stagingCap = 2 }
    for i in 0..<4 { rig.gmail.add(SyntheticMail.dibCard(id: "d\(i)", dateMs: Rig.t0 - Int64(i + 1) * day)) }
    _ = await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 30)
    let r = await rig.engine.runCycle(trigger: .launch)
    #expect(r.staged == 2 && r.haltedOn == .stagingFull && r.phase == .awaitingCards)
    let done = await rig.engine.confirmCards([CardDecision(card: CardKey(bank: "dib", last4: "1234"), state: .mine)])
    // The two staged rows, then the rest of the window, authored with the gate applied.
    #expect(done.ops == 4 && done.review == 0 && done.phase == .active)
    #expect(Set(await rig.store.enqueued.map(\.messageID)) == ["d0", "d1", "d2", "d3"])
  }
}

@Suite struct CycleTests {
  @Test func newMailBecomesAnOpOnceAndNeverDownloadsTwice() async throws {
    let rig = Rig()
    await rig.connectAndActivate()
    rig.clock.advance(3_600_000)
    rig.gmail.add(SyntheticMail.dibCard(id: "new1", dateMs: rig.clock.nowMs() - 60_000))
    rig.gmail.historyID = "1001"
    let r = await rig.engine.runCycle(trigger: .silentPush)
    #expect(r.ops == 1 && r.review == 1 && r.completed)  // card 1234 not confirmed (no scan mail)
    #expect(await rig.ledger.flushes >= 1)
    let s = await rig.store.state
    #expect(s.watermarkMs == rig.clock.nowMs() && s.profileHistoryID == "1001")

    rig.gmail.clearRequests()
    rig.gmail.historyID = "1002"
    let again = await rig.engine.runCycle(trigger: .silentPush)
    #expect(again.ops == 0 && again.listed == 1)
    #expect(rig.rawRequests.isEmpty)  // accounted: never re-downloaded
    #expect(await rig.store.enqueued.count == 1)
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
    #expect(await rig.store.accountedRows["dup"]?.outcome == .dup)
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
    #expect(await rig.store.unreadable.map(\.reason) == [.gone])
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
    let before = await rig.store.state.watermarkMs
    rig.clock.advance(3_600_000)
    rig.gmail.add(SyntheticMail.dibCard(id: "flaky", dateMs: rig.clock.nowMs() - 1000))
    rig.gmail.fail("/messages/flaky", with: [500, 500, 500])
    let r = await rig.engine.runCycle(trigger: .refresh)
    #expect(r.haltedOn == .gmail && !r.completed)
    #expect(await rig.store.state.watermarkMs == before)
    // The next run reads it.
    let r2 = await rig.engine.runCycle(trigger: .refresh)
    #expect(r2.ops == 1 && r2.completed)
  }

  @Test func accountFullHaltsWithTheWatermarkIntactAndRetryResumes() async {
    let rig = Rig()
    await rig.connectAndActivate()
    let before = await rig.store.state.watermarkMs
    rig.clock.advance(3_600_000)
    rig.gmail.add(SyntheticMail.dibCard(id: "big", dateMs: rig.clock.nowMs() - 1000))
    await rig.ledger.setFlush(.accountFull)
    let r = await rig.engine.runCycle(trigger: .refresh)
    #expect(r.haltedOn == .accountFull && r.phase == .halted)
    #expect(await rig.store.state.watermarkMs == before)
    #expect(await rig.engine.runCycle(trigger: .silentPush).haltedOn == .accountFull)  // stays halted
    await rig.ledger.setFlush(.flushed)
    let retry = await rig.engine.runCycle(trigger: .retry)
    #expect(retry.phase == .active && retry.completed && retry.ops == 0)  // the op was already queued
    #expect(await rig.store.enqueued.filter { $0.messageID == "big" }.count == 1)
  }

  @Test func deadlineCutKeepsTheWatermarkAndResumesWithoutRedownloading() async {
    let rig = Rig { $0.downloadWidth = 1 }
    await rig.connectAndActivate()
    let before = await rig.store.state.watermarkMs
    for i in 0..<3 { rig.gmail.add(SyntheticMail.dibCard(id: "c\(i)", amount: "\(i + 1).00", dateMs: rig.clock.nowMs() - Int64(i + 1) * 1000)) }
    rig.gmail.historyID = "2000"  // new mail moves the mailbox's historyId
    rig.gmail.fail("/messages/c1", with: [503])  // costs 400 ms of (fake) backoff, pushing past the deadline
    let r = await rig.engine.runCycle(trigger: .appRefresh, deadlineMs: rig.clock.nowMs() + 5_200)
    #expect(!r.completed && r.ops >= 1 && r.ops < 3)
    #expect(await rig.store.state.watermarkMs == before)
    rig.gmail.clearRequests()
    let r2 = await rig.engine.runCycle(trigger: .appRefresh)
    #expect(r2.completed && r.ops + r2.ops == 3)
    #expect(rig.rawRequests.count == 3 - r.ops)
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

  @Test func anotherHolderStopsThisDeviceAndRevokesItsOwnToken() async throws {
    let rig = Rig()
    await rig.connectAndActivate()
    await rig.server.setLink(.holder(isThisDevice: false, watchExpiresAtMs: nil))
    let r = await rig.engine.runCycle(trigger: .launch)
    #expect(r.phase == .otherDevice && r.haltedOn == .notHolder)
    #expect(try rig.keychain.read() == nil)
    #expect(rig.gmail.requests.contains { $0.form.contains { $0.0 == "token" } })  // revoke
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
    #expect(await rig.store.state.watchExpiresAtMs == Rig.t0 + 7 * day)

    let quiet = Rig()
    await quiet.server.setTopic(nil)
    await quiet.connectAndActivate()
    #expect(!quiet.gmail.requests.contains { $0.path.hasSuffix("/watch") })
    #expect(await quiet.engine.status().watchActive == false)
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
    let before = await rig.store.state.watermarkMs
    let raw = SyntheticMail.rfc822(
      from: "Alerts <alerts@newbank.example>", subject: "Notice", body: "Hello", dateMs: Rig.t0 - 3 * day,
      authDomain: "newbank.example")
    rig.gmail.add(FakeGmail.Message(id: "nb1", raw: raw, internalDateMs: Rig.t0 - 3 * day, from: "Alerts <alerts@newbank.example>"))
    let r = try await rig.engine.importSender("alerts@NewBank.example").get()
    #expect(r.ops == 1 && r.review == 1)
    #expect(await rig.ledger.authoredTrust.map(\.0) == ["newbank.example"])
    #expect(await rig.store.state.watermarkMs == before)
    if case .failure(let e) = await rig.engine.importSender("x@gmail.com") { #expect(e == .forwarder) } else { Issue.record("forwarder accepted") }
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
    #expect(try rig.keychain.read() == nil)
    #expect(await rig.server.deletes == 1)
    #expect(await rig.store.state.phase == .unlinked)
    #expect(await rig.store.accountedRows.isEmpty)
  }

  @Test func concurrentTriggersAreSingleFlight() async {
    let rig = Rig()
    await rig.connectAndActivate()
    rig.gmail.add(SyntheticMail.dibCard(id: "x", dateMs: rig.clock.nowMs() - 1000))
    async let a = rig.engine.runCycle(trigger: .refresh)
    async let b = rig.engine.runCycle(trigger: .refresh)
    let (ra, rb) = await (a, b)
    #expect(ra.ops + rb.ops == 1)
    #expect(await rig.store.enqueued.filter { $0.messageID == "x" }.count == 1)
  }
}
