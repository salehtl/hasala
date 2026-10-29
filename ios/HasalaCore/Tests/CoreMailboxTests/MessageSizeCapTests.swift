import CoreJSON
import CoreMail
import CoreMailbox
import CorePrimitives
import CoreTestSupport
import Foundation
import Testing

@Suite struct MessageSizeCapTests {
  static let padding = [UInt8](repeating: UInt8(ascii: "a"), count: MailboxLimits.maxResponseBytes)

  @Test func aGmailMessageEstimatedOverTheCapIsNeverDownloaded() async throws {
    let rig = Rig()
    await rig.connectAndActivate()
    var big = SyntheticMail.dibCard(id: "big", dateMs: rig.clock.nowMs() - 2000)
    big.sizeEstimate = 30_000_000
    rig.gmail.add(big)
    rig.gmail.add(SyntheticMail.dibCard(id: "ok", amount: "1.00", dateMs: rig.clock.nowMs() - 1000))
    rig.gmail.clearRequests()
    let r = await rig.engine.runCycle(trigger: .refresh)
    #expect(r.unreadable == 1 && r.ops == 1 && r.completed)
    #expect(rig.rawRequests.allSatisfy { !$0.path.hasSuffix("/big") })
    #expect(await rig.accounted("big") == .unreadable)
    let records = try await rig.store.unreadableRecords()
    #expect(records.map(\.reason) == [.overCap])
    #expect(records.first?.domain == BankDomains.domainOf(big.from))
    #expect(records.first?.internalDateMs == big.internalDateMs)

    rig.gmail.clearRequests()
    _ = await rig.engine.runCycle(trigger: .refresh)
    #expect(rig.gmail.requests.allSatisfy { !$0.path.hasSuffix("/big") })
  }

  @Test func aGmailMessageThatUnderstatesItsSizeIsStillOverTheCap() async {
    let rig = Rig()
    await rig.connectAndActivate()
    var big = SyntheticMail.dibCard(id: "big", dateMs: rig.clock.nowMs() - 1000)
    big.raw += Self.padding
    big.sizeEstimate = 2000
    rig.gmail.add(big)
    rig.gmail.clearRequests()
    let r = await rig.engine.runCycle(trigger: .refresh)
    #expect(r.unreadable == 1 && r.ops == 0 && r.completed)
    #expect(rig.rawRequests.count == 1)
    #expect(await rig.unreadableReasons() == [.overCap])
  }

  @Test func aCappedExchangeRefusesARawGmailMessageOverTheCap() async throws {
    let gmail = FakeGmail()
    var big = SyntheticMail.dibCard(id: "big", dateMs: Rig.t0)
    big.raw += Self.padding
    gmail.add(big)
    gmail.add(SyntheticMail.dibCard(id: "ok", dateMs: Rig.t0))
    let http = FakeGmailURLProtocol.exchange(for: gmail, maxResponseBytes: MailboxLimits.maxResponseBytes)
    let client = GmailClient(http: http, accessToken: gmail.accessToken)
    await #expect(throws: MailAPIError.tooLarge(op: "raw")) { try await client.messageRaw(id: "big") }
    let ok = try await client.messageRaw(id: "ok")
    #expect(ok.id == "ok" && !ok.rawBase64URL.isEmpty)
  }

  @Test(arguments: [false, true]) func theExchangeStopsAtTheCap(declared: Bool) async throws {
    let body = Data(repeating: 0x61, count: 5000)
    let fake = FixedAnswer(body: body, declared: declared)
    let capped = FakeGmailURLProtocol.exchange(for: fake, maxResponseBytes: 4096)
    let req = HTTPRequest(method: .get, url: URL(string: "https://gmail.googleapis.com/x")!)
    await #expect(throws: HTTPExchangeError.tooLarge) { try await capped.send(req) }
    let roomy = FakeGmailURLProtocol.exchange(for: fake, maxResponseBytes: 5000)
    #expect(try await roomy.send(req).body == body)
    let open = FakeGmailURLProtocol.exchange(for: fake)
    #expect(try await open.send(req).body == body)
  }

  @Test func anOutlookMessageOverTheCapIsAccountedOnceAndNeverDownloadedAgain() async {
    let t0 = OutlookRig.t0
    let rig = OutlookRig(viaURLSession: true, maxResponseBytes: MailboxLimits.maxResponseBytes)
    var big = SyntheticOutlookMail.dibCard(id: "AAkALgAA-big", dateMs: t0 - 2 * day)
    big.raw += Self.padding
    rig.graph.add(big)
    rig.graph.add(SyntheticOutlookMail.dibCard(id: "AAkALgAA-d1", amount: "5.00", dateMs: t0 - day))
    await rig.connectAndActivate()
    #expect(rig.accounted("AAkALgAA-big") == .unreadable)
    #expect(await rig.unreadableReasons() == [.overCap])
    #expect(rig.byID()["AAkALgAA-d1"] != nil)
    #expect(await rig.state().phase == .active)
    let before = rig.rawRequests.count
    rig.clock.advance(60_000)
    _ = await rig.engine.runCycle(trigger: .refresh)
    #expect(rig.rawRequests.count == before)
  }
}

struct FixedAnswer: HTTPExchange {
  let body: Data
  let declared: Bool

  func send(_ request: HTTPRequest) async throws(HTTPExchangeError) -> HTTPResponse {
    HTTPResponse(status: 200, body: body, headers: declared ? [("Content-Length", String(body.count))] : [])
  }
}
