import CoreMailbox
import CoreTestSupport
import Foundation
import Testing

@Suite struct StoppedLaneEntryTests {
  func stopped() async -> Rig {
    let rig = Rig()
    await rig.connectAndActivate()
    await rig.engine.stop()
    rig.gmail.clearRequests()
    return rig
  }

  @Test func aStoppedLaneTrustsNoSenderAndQueuesNoImport() async throws {
    let rig = await stopped()
    #expect(try await rig.engine.importSender("newbank.example").get() == CycleReport())
    #expect(await rig.ledger.authoredTrust.isEmpty)
    #expect(try await rig.store.pendingImports().isEmpty)
    #expect(rig.gmail.requests.isEmpty)
  }

  @Test func aLaneThatStoppedItselfTrustsNoSender() async throws {
    let rig = Rig()
    await rig.connectAndActivate()
    await rig.server.setLinkProvider(.outlook)
    _ = await rig.engine.runCycle(trigger: .launch)
    #expect(await rig.engine.stopped)
    #expect(try await rig.engine.importSender("newbank.example").get() == CycleReport())
    #expect(await rig.ledger.authoredTrust.isEmpty)
  }

  @Test func aStoppedLaneKeepsNoTypedAddress() async throws {
    let rig = OutlookRig()
    await rig.connectAndActivate()
    await rig.engine.stop()
    #expect(try await rig.engine.importSender("alerts@newbank.example").get() == CycleReport())
    #expect(try await rig.store.senderAddresses().isEmpty)
    #expect(await rig.ledger.authoredTrust.isEmpty)
  }

  @Test func aStoppedLaneStillSaysWhatIsWrongWithATypedSender() async {
    let rig = await stopped()
    guard case .failure(let e) = await rig.engine.importSender("x@gmail.com") else {
      Issue.record("forwarder accepted")
      return
    }
    #expect(e == .forwarder)
  }

  @Test func aStoppedLaneDoesNotProbeTheMailbox() async {
    let rig = await stopped()
    #expect(await rig.engine.probeSenders(["dib.ae"]) == .offline)
    #expect(rig.gmail.requests.isEmpty)
  }

  @Test func aStoppedLaneDoesNotOpenAnEmail() async {
    let rig = await stopped()
    #expect(await rig.engine.viewEmail(messageID: "m1") == .offline)
    #expect(rig.gmail.requests.isEmpty)
  }

  @Test func aConnectOpensThoseAgain() async throws {
    let rig = await stopped()
    _ = await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90)
    _ = try await rig.engine.importSender("newbank.example").get()
    #expect(await rig.ledger.authoredTrust.map(\.0) == ["newbank.example"])
    #expect(await rig.engine.probeSenders(["dib.ae"]) != .offline)
  }
}
