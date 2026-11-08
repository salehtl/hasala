import CoreMailbox
import CoreTestSupport
import Foundation
import Testing

@Suite struct ImportTokenFailureTests {
  let sender = "emiratesnbd.com"

  func active() async -> Rig {
    let rig = Rig()
    await rig.ledger.setTrust(["dib.ae": true])
    await rig.connectAndActivate()
    await rig.tokens.invalidate()
    return rig
  }

  func keepsItsImport(_ rig: Rig) async throws {
    #expect(try await rig.store.pendingImports().map(\.domain) == [sender])
    #expect(await rig.state().phase == .active)
  }

  @Test func aKeychainThatCannotBeReadIsNotASignInProblem() async throws {
    let rig = await active()
    rig.keychain.locked = true
    let r = await rig.engine.backfill(senders: [sender])
    rig.keychain.locked = false
    #expect(r.haltedOn == nil && !r.completed, "\(r)")
    try await keepsItsImport(rig)
  }

  @Test func aTokenEndpointThatDoesNotAnswerIsOffline() async throws {
    let rig = await active()
    rig.gmail.fail("/token", with: [500])
    let r = await rig.engine.backfill(senders: [sender])
    #expect(r.haltedOn == .offline && !r.completed, "\(r)")
    try await keepsItsImport(rig)
  }

  @Test func aRefusedGrantStillAsksForASignIn() async throws {
    let rig = await active()
    rig.gmail.invalidGrant = true
    let r = await rig.engine.backfill(senders: [sender])
    #expect(r.haltedOn == .reconnectRequired && !r.completed, "\(r)")
  }

  @Test func importingPastMailReadsTheFailureTheSameWay() async throws {
    let rig = Rig()
    _ = await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90, pastMail: .skip())
    _ = await rig.engine.runCycle(trigger: .launch)
    await rig.tokens.invalidate()
    rig.keychain.locked = true
    let r = await rig.engine.importPastMail()
    rig.keychain.locked = false
    #expect(r.haltedOn == nil && !r.completed, "\(r)")
  }
}
