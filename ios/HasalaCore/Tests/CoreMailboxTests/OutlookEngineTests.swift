// The engine over an OutlookProvider and FakeGraph: the Gmail engine tests' behaviours, for
// Graph (docs/decisions/outlook-mailbox.md). Every message is synthetic; ids are short
// immutable-id-shaped strings.
import CoreJSON
import CoreMail
import CoreMailbox
import CorePrimitives
import CoreTestSupport
import Foundation
import Testing

@Suite struct OutlookConnectTests {
  @Test func connectLinksOutlookAndKeepsTheClientState() async throws {
    let rig = OutlookRig()
    #expect(await rig.connect() == .connected(address: "synthetic.user@outlook.example"))
    #expect(await rig.server.linkedProviders == [.outlook])
    #expect(try rig.keychain.read() == "fake-ms-refresh-0")
    #expect(try rig.link.read() == OutlookLinkState(clientState: OutlookServer.clientState))
    let s = await rig.state()
    #expect(s.phase == .scanning && s.address == "synthetic.user@outlook.example" && s.profileHistoryID == nil)
    // The mailbox was proven before anything was linked; no message was read.
    #expect(rig.graph.graphRequests.map(\.path) == ["/v1.0/me/mailFolders/inbox"])
  }

  @Test func anAccountWithoutAMailboxIsRefusedBeforeTheLink() async throws {
    let rig = OutlookRig()
    rig.graph.noMailbox = true
    #expect(await rig.connect() == .failed(.noMailbox))
    #expect(await rig.server.linkedProviders.isEmpty)
    #expect(try rig.keychain.read() == nil && rig.link.read() == nil)
    #expect(await rig.state().phase == .unlinked)
  }

  @Test func missingMailReadIsReported() async throws {
    let rig = OutlookRig()
    rig.graph.omitMailScope = true
    #expect(await rig.connect() == .failed(.permissionMissing))
    #expect(try rig.keychain.read() == nil)
  }

  @Test func aWorkAccountIsRefused() async {
    let rig = OutlookRig()
    rig.graph.tid = "11111111-1111-4111-8111-111111111111"
    #expect(await rig.connect() == .failed(.google))
    #expect(await rig.server.linkedProviders.isEmpty)
  }

  @Test func aCancelledSheetChangesNothing() async {
    let rig = OutlookRig()
    var p = OutlookPresenter(graph: rig.graph)
    p.cancel = true
    #expect(await rig.engine.connect(presenter: p, backfillDays: 90) == .cancelled)
    #expect(await rig.server.linkedProviders.isEmpty)
  }
}

@Suite struct OutlookScanTests {
  static let day: Int64 = 86_400_000
  let t0 = OutlookRig.t0

  func seed(_ g: FakeGraph) {
    g.add(SyntheticOutlookMail.dibCard(id: "AAkALgAA-d1", dateMs: t0 - 5 * Self.day))
    g.add(SyntheticOutlookMail.dibCard(id: "AAkALgAA-d2", amount: "10.00", dateMs: t0 - 4 * Self.day))
    g.add(SyntheticOutlookMail.enbdAlert(id: "AAkALgAA-e1", dateMs: t0 - 2 * Self.day))
    g.add(SyntheticOutlookMail.bankNotice(id: "AAkALgAA-n1", dateMs: t0 - Self.day))
    g.add(SyntheticOutlookMail.dibCard(id: "AAkALgAA-old", dateMs: t0 - 120 * Self.day))
  }

  @Test func theScanReadsOnlyTrustedSendersAndWaitsForReviewWhileTrustIsUnproven() async throws {
    let rig = OutlookRig()
    seed(rig.graph)
    _ = await rig.connect()
    let r = await rig.engine.runCycle(trigger: .launch)
    #expect(r.staged == 4 && r.ops == 4 && r.phase == .active && r.completed)
    let byID = rig.byID()
    #expect(Set(byID.keys) == ["AAkALgAA-d1", "AAkALgAA-d2", "AAkALgAA-e1", "AAkALgAA-n1"])
    // The gate is closed: the rule passes, the row still waits for review.
    #expect(byID.values.allSatisfy { $0.needsReview })
    let d1 = try #require(byID["AAkALgAA-d1"])
    #expect(d1.payload["gates"]?["ar"] == .string("pass") && d1.payload["gates"]?["sender"] == .string("untrusted"))
    #expect(d1.payload["provenance"]?["provider"] == .string("outlook"))
    #expect(d1.payload["provenance"]?["message_id"] == .string("AAkALgAA-d1"))
    #expect(d1.payload["amount_minor"] == .string("25000"))
    // Every Graph request asked for immutable ids; every listing carried the sender filter.
    #expect(rig.graph.graphRequests.allSatisfy { $0.prefer == "IdType=\"ImmutableId\"" })
    #expect(!rig.listRequests.isEmpty)
    for l in rig.listRequests {
      let f = try #require(l.query.first { $0.0 == "$filter" }?.1)
      #expect(f.hasPrefix("receivedDateTime ge ") && f.contains("endswith(from/emailAddress/address,'@dib.ae')"))
      #expect(f.contains("endswith(from/emailAddress/address,'.dib.ae')"))
      #expect(l.query.contains { $0 == ("$select", "id,receivedDateTime,from") })
      #expect(!l.query.contains { $0.0 == "$orderby" || $0.0 == "$search" })
    }
    // The listing named every id's From and time: no metadata request, one $value per message.
    #expect(rig.metadataRequests.isEmpty)
    #expect(rig.rawRequests.count == 4)
    #expect(await rig.state().watermarkMs == t0)
  }

  @Test func withTrustProvenAVerifiedAlertFilesItself() async throws {
    let rig = OutlookRig(trustProven: true)
    rig.graph.add(SyntheticOutlookMail.dibCard(id: "AAkALgAA-d1", dateMs: t0 - Self.day))
    rig.graph.add(SyntheticOutlookMail.dibCard(id: "AAkALgAA-noeop", amount: "1.00", dateMs: t0 - Self.day, eop: false))
    rig.graph.add(SyntheticOutlookMail.dibCard(id: "AAkALgAA-spoof", amount: "2.00", dateMs: t0 - Self.day, spoofedAbove: true))
    await rig.connectAndActivate()
    let byID = rig.byID()
    #expect(byID["AAkALgAA-d1"]?.needsReview == false)
    #expect(byID["AAkALgAA-d1"]?.payload["gates"]?["sender"] == .string("trusted"))
    #expect(byID["AAkALgAA-noeop"]?.needsReview == true && byID["AAkALgAA-noeop"]?.payload["gates"]?["ar"] == .string("no_eop"))
    #expect(byID["AAkALgAA-spoof"]?.needsReview == true && byID["AAkALgAA-spoof"]?.payload["gates"]?["ar"] == .string("multiple_ar"))
  }

  @Test func aSecondCycleDownloadsNothingTwice() async {
    let rig = OutlookRig()
    seed(rig.graph)
    await rig.connectAndActivate()
    let before = rig.rawRequests.count
    rig.clock.advance(60_000)
    let r = await rig.engine.runCycle(trigger: .refresh)
    #expect(r.completed && r.ops == 0 && r.listed == 2)  // the 2-day overlap re-lists e1 and n1
    #expect(rig.rawRequests.count == before)
    // New mail is read on the next cycle (no change detector: every cycle lists).
    rig.graph.add(SyntheticOutlookMail.dibCard(id: "AAkALgAA-d3", amount: "7.00", dateMs: rig.clock.nowMs() - 1_000))
    let next = await rig.engine.runCycle(trigger: .silentPush)
    #expect(next.ops == 1 && rig.rawRequests.count == before + 1)
  }

  @Test func lookAlikeSendersAreNeverListed() async {
    let rig = OutlookRig()
    rig.graph.add(SyntheticOutlookMail.lookAlike(id: "AAkALgAA-x1", dateMs: t0 - Self.day, address: "offers@notdib.ae"))
    rig.graph.add(SyntheticOutlookMail.lookAlike(id: "AAkALgAA-x2", dateMs: t0 - Self.day, address: "a@dib.ae.evil.example"))
    rig.graph.add(SyntheticOutlookMail.dibCard(id: "AAkALgAA-d1", dateMs: t0 - Self.day, fromDomain: "alerts.dib.ae"))
    await rig.connectAndActivate()
    #expect(Set(rig.byID().keys) == ["AAkALgAA-d1"])  // a subdomain of a trusted domain is a member
    #expect(rig.rawRequests.allSatisfy { !$0.path.contains("-x") })
    #expect(rig.accounted("AAkALgAA-x1") == nil && rig.accounted("AAkALgAA-x2") == nil)
  }

  @Test func aListingThatIgnoredTheFilterHaltsAndReadsNothing() async {
    let rig = OutlookRig()
    rig.graph.add(SyntheticOutlookMail.dibCard(id: "AAkALgAA-d1", dateMs: t0 - Self.day))
    await rig.connectAndActivate()
    let watermark = await rig.state().watermarkMs
    let raws = rig.rawRequests.count
    rig.graph.add(SyntheticOutlookMail.lookAlike(id: "AAkALgAA-x1", dateMs: t0, address: "friend@personal.example"))
    rig.graph.add(SyntheticOutlookMail.dibCard(id: "AAkALgAA-d2", amount: "3.00", dateMs: t0))
    rig.graph.ignoreFilter = true
    rig.clock.advance(60_000)
    let r = await rig.engine.runCycle(trigger: .refresh)
    #expect(r.haltedOn == .gmail && !r.completed)
    let s = await rig.state()
    #expect(s.phase == .halted && s.watermarkMs == watermark)
    #expect(rig.rawRequests.count == raws)
    #expect(rig.accounted("AAkALgAA-x1") == nil && rig.accounted("AAkALgAA-d2") == nil)
  }

  @Test func aMessageThatIsGoneIsAccounted() async {
    let rig = OutlookRig()
    rig.graph.add(SyntheticOutlookMail.dibCard(id: "AAkALgAA-gone", dateMs: t0 - Self.day))
    rig.graph.add(SyntheticOutlookMail.dibCard(id: "AAkALgAA-d1", amount: "5.00", dateMs: t0 - Self.day))
    rig.graph.fail("AAkALgAA-gone/$value", with: [404], code: "ErrorItemNotFound")
    await rig.connectAndActivate()
    #expect(rig.accounted("AAkALgAA-gone") == .gone)
    #expect(await rig.unreadableReasons() == [.gone])
    #expect(await rig.state().phase == .active)
  }

  @Test func retryAfterStopsTheRunAndHoldsTheNextOne() async {
    let rig = OutlookRig()
    seed(rig.graph)
    _ = await rig.connect()
    rig.graph.fail("/$value", with: [429], retryAfter: 30)
    let r = await rig.engine.runCycle(trigger: .launch)
    #expect(r.haltedOn == .gmail && !r.completed)
    #expect(rig.clock.nowMs() == t0)  // no 400 ms / 1200 ms retry sleeps
    let requests = rig.graph.requests.count
    let held = await rig.engine.runCycle(trigger: .retry)
    #expect(held.haltedOn == .gmail && rig.graph.requests.count == requests)
    rig.clock.advance(31_000)
    let resumed = await rig.engine.runCycle(trigger: .launch)
    #expect(resumed.phase == .active && resumed.completed && resumed.haltedOn == nil)
  }

  @Test func aThrottleWithoutRetryAfterUsesTheBackoff() async {
    let rig = OutlookRig()
    rig.graph.add(SyntheticOutlookMail.dibCard(id: "AAkALgAA-d1", dateMs: t0 - Self.day))
    _ = await rig.connect()
    rig.graph.fail("/$value", with: [429])
    let r = await rig.engine.runCycle(trigger: .launch)
    #expect(r.phase == .active && r.completed)
    #expect(rig.clock.nowMs() == t0 + 1_000)  // a 429's first wait (`rateLimitBackoffMs`)
  }

  @Test func downloadsNeverExceedThreeAtOnce() async {
    let rig = OutlookRig()
    for i in 0..<9 {
      rig.graph.add(SyntheticOutlookMail.dibCard(id: "AAkALgAA-w\(i)", amount: "\(i + 1).00", dateMs: t0 - Int64(i + 1) * 60_000))
    }
    rig.graph.rawDelayMs = 20
    await rig.connectAndActivate()
    #expect(rig.rawRequests.count == 9)
    #expect(rig.graph.maxInFlight <= OutlookProvider.downloadWidth)
  }

  @Test func listingPagesFollowNextLink() async {
    let rig = OutlookRig()
    rig.graph.pageSize = 2
    seed(rig.graph)
    await rig.connectAndActivate()
    #expect(rig.byID().count == 4)
    #expect(rig.listRequests.contains { r in r.query.contains { $0.0 == "$skiptoken" } })
  }

  @Test func invalidGrantAsksForAReconnect() async throws {
    let rig = OutlookRig()
    await rig.connectAndActivate()
    rig.graph.invalidGrant = true
    rig.clock.advance(2 * 3_600_000)  // the cached access token expired
    let r = await rig.engine.runCycle(trigger: .refresh)
    #expect(r.haltedOn == .reconnectRequired && r.phase == .reconnectRequired)
    #expect(try rig.keychain.read() == nil)
  }

  @Test func theRotatedRefreshTokenIsStored() async throws {
    let rig = OutlookRig()
    await rig.connectAndActivate()
    rig.clock.advance(2 * 3_600_000)
    _ = await rig.engine.runCycle(trigger: .refresh)
    #expect(try rig.keychain.read() == "fake-ms-refresh-1")
  }

  @Test func aMailboxThatDisappearsHaltsWithItsOwnReason() async {
    let rig = OutlookRig()
    await rig.connectAndActivate()
    rig.graph.noMailbox = true
    let r = await rig.engine.runCycle(trigger: .refresh)
    #expect(r.haltedOn == .noMailbox)
    #expect(await rig.state().phase == .halted)
    #expect(await rig.engine.status().haltedOn == .noMailbox)
  }

  @Test func throughURLSessionRetryAfterStillArrives() async {
    let rig = OutlookRig(viaURLSession: true)
    rig.graph.add(SyntheticOutlookMail.dibCard(id: "AAkALgAA-d1", dateMs: t0 - Self.day))
    #expect(await rig.connect() == .connected(address: "synthetic.user@outlook.example"))
    rig.graph.fail("/$value", with: [503], retryAfter: 5)
    let r = await rig.engine.runCycle(trigger: .launch)
    #expect(r.haltedOn == .gmail && rig.clock.nowMs() == t0)
    rig.clock.advance(6_000)
    #expect(await rig.engine.runCycle(trigger: .launch).phase == .active)
    #expect(rig.byID()["AAkALgAA-d1"] != nil)
  }
}

@Suite struct OutlookSubscriptionTests {
  let t0 = OutlookRig.t0
  let lifetime = GraphClient.subscriptionLifetimeMs

  @Test func theFirstCycleSubscribesWithTheLinksClientState() async throws {
    let rig = OutlookRig()
    await rig.connectAndActivate()
    let subs = rig.graph.subscriptions
    #expect(subs.count == 1)
    let s = try #require(subs.first)
    #expect(s.resource == "me/messages" && s.changeType == "created" && s.clientState == OutlookServer.clientState)
    #expect(s.notificationURL == OutlookServer.notificationURL && s.lifecycleURL == OutlookServer.lifecycleURL)
    #expect(s.expiresAtMs == t0 + lifetime)
    #expect(await rig.server.watches == [t0 + lifetime])
    #expect(try rig.link.read()?.subscriptionID == s.id)
    #expect(await rig.engine.status().watchActive)
  }

  @Test func noPushNoSubscription() async {
    let rig = OutlookRig()
    await rig.server.setPushOn(false)
    await rig.connectAndActivate()
    #expect(rig.graph.subscriptions.isEmpty && rig.subscriptionRequests("POST").isEmpty)
    #expect(await !rig.engine.status().watchActive)
  }

  @Test func renewalPatchesWhenLessThanThreeDaysRemain() async throws {
    let rig = OutlookRig()
    await rig.connectAndActivate()
    let id = try #require(rig.graph.subscriptions.first?.id)
    rig.clock.advance(86_400_000)
    _ = await rig.engine.runCycle(trigger: .refresh)
    #expect(rig.subscriptionRequests("PATCH").isEmpty)
    rig.clock.advance(3 * 86_400_000 + 3_600_000)  // 2 d 22 h left
    _ = await rig.engine.runCycle(trigger: .refresh)
    #expect(rig.subscriptionRequests("PATCH").count == 1)
    let s = try #require(rig.graph.subscriptions.first)
    #expect(s.id == id && s.expiresAtMs == rig.clock.nowMs() + lifetime)
    #expect(await rig.server.watches.last == rig.clock.nowMs() + lifetime)
    #expect(rig.subscriptionRequests("POST").count == 1)
  }

  @Test func aSubscriptionGraphLostIsCreatedAgain() async throws {
    let rig = OutlookRig()
    await rig.connectAndActivate()
    let old = try #require(rig.graph.subscriptions.first?.id)
    _ = try await GraphClient(http: rig.graph, accessToken: "t", link: MemoryOutlookLinkStore(), nowMs: { 0 })
      .deleteSubscription(id: old)
    rig.clock.advance(5 * 86_400_000)
    _ = await rig.engine.runCycle(trigger: .refresh)
    let now = try #require(rig.graph.subscriptions.first)
    #expect(now.id != old && rig.graph.subscriptions.count == 1)
    #expect(try rig.link.read()?.subscriptionID == now.id)
  }

  @Test func anotherIPhonesSubscriptionIsReplacedOnConflict() async throws {
    let rig = OutlookRig()
    rig.graph.addSubscription(
      FakeGraph.Subscription(
        id: "sub-other-iphone", resource: "me/messages", changeType: "created",
        notificationURL: OutlookServer.notificationURL, lifecycleURL: OutlookServer.lifecycleURL,
        clientState: "b2xkLWNsaWVudC1zdGF0ZQ", expiresAtMs: t0 + 86_400_000))
    await rig.connectAndActivate()
    let subs = rig.graph.subscriptions
    #expect(subs.count == 1 && subs[0].id != "sub-other-iphone" && subs[0].clientState == OutlookServer.clientState)
    #expect(rig.subscriptionRequests("DELETE").map(\.path) == ["/v1.0/subscriptions/sub-other-iphone"])
  }

  @Test func disconnectDeletesTheSubscriptionAndBothKeychainItems() async throws {
    let rig = OutlookRig()
    await rig.connectAndActivate()
    let id = try #require(rig.graph.subscriptions.first?.id)
    #expect(await rig.engine.disconnect())
    #expect(rig.graph.subscriptions.isEmpty)
    #expect(rig.subscriptionRequests("DELETE").map(\.path) == ["/v1.0/subscriptions/\(id)"])
    #expect(try rig.keychain.read() == nil && rig.link.read() == nil)
    #expect(await rig.server.deletes == 1)
    #expect(await rig.state().phase == .unlinked)
    // Microsoft has no revoke endpoint: nothing but token requests went to login.microsoftonline.com.
    #expect(rig.graph.requests.filter { !$0.path.hasPrefix("/v1.0") }.allSatisfy { $0.path.hasSuffix("/oauth2/v2.0/token") })
  }

  @Test func aTakeoverEndsOnlyThisIPhonesSubscription() async throws {
    let rig = OutlookRig()
    await rig.connectAndActivate()
    let mine = try #require(rig.graph.subscriptions.first?.id)
    // The other iPhone linked and subscribed (its 409 replaced nothing yet in this script).
    rig.graph.addSubscription(
      FakeGraph.Subscription(
        id: "sub-new-holder", resource: "me/messages", changeType: "created",
        notificationURL: OutlookServer.notificationURL, lifecycleURL: OutlookServer.lifecycleURL,
        clientState: "bmV3LWNsaWVudC1zdGF0ZQ", expiresAtMs: t0 + 86_400_000))
    await rig.server.setLink(.holder(isThisDevice: false, watchExpiresAtMs: nil))
    let r = await rig.engine.runCycle(trigger: .launch)
    #expect(r.phase == .otherDevice)
    #expect(rig.graph.subscriptions.map(\.id) == ["sub-new-holder"])
    #expect(rig.subscriptionRequests("DELETE").map(\.path) == ["/v1.0/subscriptions/\(mine)"])
    #expect(try rig.keychain.read() == nil && rig.link.read() == nil)
  }

  @Test func aLinkDeletedElsewhereForgetsTheClientState() async throws {
    let rig = OutlookRig()
    await rig.connectAndActivate()
    await rig.server.setLink(.noLink)
    let r = await rig.engine.runCycle(trigger: .launch)
    #expect(r.phase == .reconnectRequired)
    #expect(try rig.link.read() == nil && rig.graph.subscriptions.isEmpty)
  }

  @Test func aServerWithoutAClientStateLinksWithoutPush() async throws {
    let rig = OutlookRig()
    await rig.server.setReturnsClientState(false)
    await rig.connectAndActivate()
    #expect(try rig.link.read() == nil)
    #expect(rig.graph.subscriptions.isEmpty)
    #expect(await rig.server.watches.isEmpty)
    #expect(await rig.state().phase == .active)
  }
}

@Suite struct GraphClientTests {
  let graph = FakeGraph()
  var client: GraphClient { GraphClient(http: graph, accessToken: "t", link: MemoryOutlookLinkStore(), nowMs: { 0 }) }

  @Test func anUnfilteredListingIsRefusedLocally() async {
    await #expect(throws: MailAPIError.unfilteredListing) { try await client.list(senders: [], since: 0, pageToken: nil) }
    await #expect(throws: MailAPIError.unfilteredListing) {
      try await client.list(senders: ["dib.ae') or true or ('"], since: 0, pageToken: nil)
    }
    let many = (0...GraphClient.maxDomainsPerList).map { "bank\($0).example" }
    await #expect(throws: MailAPIError.unfilteredListing) { try await client.list(senders: many, since: 0, pageToken: nil) }
    #expect(graph.requests.isEmpty)
  }

  @Test func aNextLinkToAnotherOriginIsNeverFollowed() async {
    await #expect(throws: MailAPIError.status(200, op: "list")) {
      try await client.list(senders: ["dib.ae"], since: 0, pageToken: "https://evil.example/v1.0/me/messages?$skiptoken=1")
    }
    #expect(graph.requests.isEmpty)
  }

  @Test func theFilterMatchesBankDomainsMembership() {
    let q = GraphClient.listQuery(["dib.ae"], sinceSec: 1_780_000_000)
    #expect(
      q[0].1
        == "receivedDateTime ge 2026-05-28T20:26:40Z and (endswith(from/emailAddress/address,'@dib.ae') or endswith(from/emailAddress/address,'.dib.ae'))"
    )
  }

  @Test func graphErrorsMapToTheEngineErrors() {
    func res(_ s: Int, _ code: String?, retry: String? = nil) -> HTTPResponse {
      let body = code.map { "{\"error\":{\"code\":\"\($0)\",\"message\":\"m\"}}" } ?? ""
      return HTTPResponse(status: s, body: Data(body.utf8), headers: retry.map { [("Retry-After", $0)] } ?? [])
    }
    #expect(GraphClient.failure(res(404, "MailboxNotEnabledForRESTAPI"), op: "x") == .noMailbox)
    #expect(GraphClient.failure(res(401, "MailboxNotEnabledForRESTAPI"), op: "x") == .noMailbox)
    #expect(GraphClient.failure(res(429, nil, retry: "12"), op: "x") == .throttled(retryAfterSec: 12, op: "x"))
    #expect(GraphClient.failure(res(503, nil, retry: " 7 "), op: "x") == .throttled(retryAfterSec: 7, op: "x"))
    #expect(GraphClient.failure(res(429, nil), op: "x") == .status(429, op: "x"))
    #expect(GraphClient.failure(res(400, "ErrorItemNotFound"), op: "x") == .status(404, op: "x"))
    #expect(MailAPIError.throttled(retryAfterSec: 1, op: "x").status == 429)
  }
}

@Suite struct OutlookSwitchTests {
  /// What a Gmail lane left in the shared mailbox tables.
  func seedGmailLane(_ rig: OutlookRig) async throws {
    var s = MailboxState()
    s.phase = .active
    s.watermarkMs = OutlookRig.t0 - 86_400_000
    s.address = "someone@gmail.example"
    var c = MailboxCommit()
    c.state = s
    c.healthBumps = [("gmail-only.example", OutlookRig.t0)]
    try await rig.store.commit(c)
  }

  @Test func switchingStartsAFreshScanOnlyOnceTheLinkIsMade() async throws {
    let rig = OutlookRig()
    try await seedGmailLane(rig)
    var cancelled = OutlookPresenter(graph: rig.graph)
    cancelled.cancel = true
    #expect(await rig.engine.connect(presenter: cancelled, backfillDays: 90, replacing: true) == .cancelled)
    #expect(await rig.state().phase == .active)
    #expect(try await rig.store.bankHealth().count == 1)

    rig.graph.add(SyntheticOutlookMail.dibCard(id: "AAkALgAA-d1", dateMs: OutlookRig.t0 - 86_400_000))
    let r = await rig.engine.connect(presenter: OutlookPresenter(graph: rig.graph), backfillDays: 30, replacing: true)
    #expect(r == .connected(address: "synthetic.user@outlook.example"))
    let s = await rig.state()
    #expect(s.phase == .scanning && s.watermarkMs == nil && s.backfillDays == 30)
    #expect(s.address == "synthetic.user@outlook.example")
    #expect(try await rig.store.bankHealth().isEmpty)
    let done = await rig.engine.runCycle(trigger: .launch)
    #expect(done.phase == .active && done.ops == 1)
  }

  @Test func endGrantForgetsTheProviderButNotTheTables() async throws {
    let rig = OutlookRig()
    await rig.connectAndActivate()
    let before = await rig.state()
    await rig.engine.endGrant()
    #expect(rig.graph.subscriptions.isEmpty)
    #expect(try rig.keychain.read() == nil && rig.link.read() == nil)
    #expect(await rig.state() == before)
    #expect(await rig.server.deletes == 0)
  }
}
