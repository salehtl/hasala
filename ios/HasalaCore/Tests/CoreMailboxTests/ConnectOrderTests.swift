import CoreMailbox
import CoreTestSupport
import Foundation
import Testing

@Suite struct ConnectOrderTests {
  var elsewhere: MailboxLinkStatus { .holder(isThisDevice: false, watchExpiresAtMs: nil) }

  func connect(_ rig: Rig) async -> ConnectResult {
    await rig.engine.connect(presenter: FakePresenter(gmail: rig.gmail), backfillDays: 90)
  }

  @Test func aTokenThatCannotBeKeptLeavesTheOtherIPhonesLinkInPlace() async throws {
    let rig = Rig()
    await rig.connectAndActivate()
    await rig.server.setLink(elsewhere)
    #expect(await rig.engine.runCycle(trigger: .launch).phase == .otherDevice)
    let before = await rig.state()
    let puts = await rig.server.puts.count
    rig.keychain.locked = true
    #expect(await connect(rig) == .failed(.keychain))
    rig.keychain.locked = false
    #expect(await rig.server.puts.count == puts)
    #expect(await rig.server.link == elsewhere)
    #expect(await rig.state() == before)
    #expect(await connect(rig) == .connected(address: SyntheticMail.defaultTo))
    #expect(await rig.server.puts.count == puts + 1)
    #expect(try rig.keychain.read() != nil)
  }

  @Test func aTokenThatCannotBeKeptOnAReconnectMakesNoLink() async throws {
    let rig = Rig()
    await rig.connectAndActivate()
    await rig.tokens.invalidate()
    rig.gmail.invalidGrant = true
    #expect(await rig.engine.runCycle(trigger: .launch).phase == .reconnectRequired)
    rig.gmail.invalidGrant = false
    let before = await rig.state()
    let puts = await rig.server.puts.count
    rig.keychain.locked = true
    #expect(await connect(rig) == .failed(.keychain))
    rig.keychain.locked = false
    #expect(await rig.server.puts.count == puts)
    #expect(await rig.state() == before)
  }

  @Test func aCancelledStepUpLeavesTheOldSignInAlone() async throws {
    let rig = Rig(stepUpFails: true)
    let old = "old-refresh-token"
    try rig.keychain.write(old)
    rig.gmail.refreshToken = "fresh-refresh-token"
    #expect(await connect(rig) == .failed(.stepUpFailed))
    #expect(try rig.keychain.read() == old)
  }

  @Test(arguments: [
    (MailboxServerError.offline, ConnectFailure.offline),
    (.refused(403, "link_rejected"), .serverRefused),
    (.refused(409, "mailbox_in_use"), .mailboxInUse),
  ])
  func aLinkTheServerDoesNotMakePutsTheOldSignInBack(_ refusal: MailboxServerError, _ failure: ConnectFailure) async throws {
    let rig = Rig()
    await rig.connectAndActivate()
    let old = try #require(try rig.keychain.read())
    let before = await rig.state()
    rig.gmail.refreshToken = "fresh-refresh-token"
    await rig.server.setLinkRefusal(refusal)
    #expect(await connect(rig) == .failed(failure))
    #expect(try rig.keychain.read() == old)
    #expect(await rig.state() == before)
  }

  @Test func aLinkTheServerDoesNotMakeLeavesNoTokenWhereThereWasNone() async throws {
    let rig = Rig()
    await rig.server.setLinkRefusal(.offline)
    #expect(await connect(rig) == .failed(.offline))
    #expect(try rig.keychain.read() == nil)
  }

  @Test func aReconnectInstallsTheNewTokenAndReadsWithIt() async throws {
    let rig = Rig()
    await rig.connectAndActivate()
    rig.gmail.refreshToken = "fresh-refresh-token"
    #expect(await connect(rig) == .connected(address: SyntheticMail.defaultTo))
    #expect(try rig.keychain.read() == "fresh-refresh-token")
    await rig.tokens.invalidate()
    #expect(await rig.engine.runCycle(trigger: .launch).phase == .active)
  }
}
