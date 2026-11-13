import CoreMailbox
import CoreTestSupport
import Foundation
import Testing

@Suite struct AddSenderWritesTests {
  static let day: Int64 = 86_400_000
  let address = "alerts@newbank.example"

  func faulty() throws -> (OutlookRig, UnreadableStateStore) {
    var wrapped: UnreadableStateStore?
    let rig = OutlookRig(wrapStore: { base in
      let store = UnreadableStateStore(base)
      wrapped = store
      return store
    })
    return (rig, try #require(wrapped))
  }

  @Test func aTrustThatCouldNotBeWrittenKeepsNoAddressAndQueuesNoImport() async throws {
    let rig = OutlookRig()
    await rig.connectAndActivate()
    await rig.ledger.setTrustFails(true)

    let r = try await rig.engine.importSender(address).get()

    #expect(r.haltedOn == .offline)
    #expect(try await rig.store.senderAddresses().isEmpty)
    #expect(try await rig.store.pendingImports().isEmpty)
  }

  @Test func anImportThatCouldNotBeQueuedKeepsNoAddressAndATryAgainFinishesIt() async throws {
    let (rig, store) = try faulty()
    await rig.connectAndActivate()
    await rig.ledger.setTrust(["dib.ae": true, "newbank.example": true])
    rig.graph.add(SyntheticOutlookMail.lookAlike(id: "AAkALgAA-nb1", dateMs: OutlookRig.t0 - 3 * Self.day, address: address))
    await store.setImportWriteFails(true)

    let failed = try await rig.engine.importSender(address).get()

    #expect(failed.haltedOn == .offline)
    #expect(try await rig.store.senderAddresses().isEmpty)
    #expect(await rig.engine.status().unlisted == ["newbank.example"])

    await store.setImportWriteFails(false)
    let again = try await rig.engine.importSender(address).get()

    #expect(again.completed && again.listed == 1)
    #expect(try await rig.store.senderAddresses() == [address])
    #expect(rig.accounted("AAkALgAA-nb1") != nil)
    #expect(await rig.engine.status().unlisted.isEmpty)
  }

  @Test func anAddressTypedBeforeTheScanEndsIsKeptWithNoImportOfItsOwn() async throws {
    let rig = OutlookRig()
    _ = await rig.connect()
    #expect(await rig.state().watermarkMs == nil)

    _ = try await rig.engine.importSender(address).get()

    #expect(try await rig.store.senderAddresses() == [address])
    #expect(try await rig.store.pendingImports().isEmpty)
    #expect(await rig.ledger.authoredTrust.map(\.0) == ["newbank.example"])
  }
}
