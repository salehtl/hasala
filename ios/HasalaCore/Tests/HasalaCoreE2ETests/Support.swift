// Test worlds for the protocol suites: one FakeServer (or, with
// HASALA_E2E_URL, a local hasalad), and one AccountEnvironment per simulated
// iPhone (its own Keychain, DAK and passkeys).
import CoreAuth
import CoreCrypto
import CoreSoftAuth
import CoreSync
import CoreTestSupport
import Foundation
import Testing

let invite = "ABCDEFGHIJKLMNOPQRSTUVWX"
let password = "correct horse battery staple"

final class Phone: Sendable {
  let env: AccountEnvironment
  let keychain = MemorySecretStore()
  let dak = SoftwareApprovalKeySigner()
  let passkeys: SoftPasskey

  init(transport: any Transport, clock: FakeClock, seed: String, passkeys: SoftPasskey = SoftPasskey()) {
    self.passkeys = passkeys
    env = AccountEnvironment(
      client: AuthClient(transport: transport), secrets: Secrets(store: keychain, apiHost: "api.hasala.app"),
      approvalKeys: dak, passkeys: passkeys, clock: clock, random: SeededRandom(seed: seed),
      apiBase: "https://api.hasala.app", accountsDirectory: nil)
  }

  var binding: AccountBinding? { try? env.secrets.binding() }
}

struct World {
  let server = FakeServer()
  let clock = FakeClock()

  init() { server.addInvite(invite) }

  func phone(_ seed: String, passkeys: SoftPasskey = SoftPasskey()) -> Phone {
    Phone(transport: server, clock: clock, seed: seed, passkeys: passkeys)
  }

  /// Signup + C1-P on `phone`; returns the account, its keys' phrase and a context.
  func passwordAccount(_ phone: Phone, email: String = "maya@example.com") async throws -> (
    EnrolledAccount, [String], SyncContext
  ) {
    let signup = try await AccountCreation.beginSignup(
      phone.env, inviteCode: "abcd-efgh-ijkl-mnop-qrst-uvwx", email: email, displayName: "Maya", inviteLinkKey: nil)
    try await AccountCreation.verifySignup(phone.env, signup, code: try #require(server.lastCode))
    let keys = try NewAccountKeys.generate(random: phone.env.random)
    let words = try keys.words()
    let account = try await AccountCreation.createWithPassword(phone.env, signup: signup, password: password, keys: keys)
    return (account, words, Enrolment.context(phone.env, account: account))
  }
}

/// A valid parent-free op (home_currency_set) with a distinct id.
func op(_ i: Int, currency: String = "AED") -> Op {
  Op(
    v: 4, type: .homeCurrencySet, opID: "01J000000000000000000000\(String(format: "%02d", i % 100))",
    authoredAt: "2026-10-11T08:00:00.000Z", payload: .object(JSONObject([("currency", .string(currency))])))
}

/// Enqueues ops straight into the store (the Outbox's own tests cover it).
func enqueue(_ ctx: SyncContext, _ ops: [Op]) throws {
  try ctx.store.enqueue(
    ops.map {
      PendingOp(
        opID: $0.opID, opJSON: try! canonical($0), opType: $0.type.rawValue, entityKind: nil, entityID: nil,
        enqueuedAt: 0)
    })
}

func canonical(_ op: Op) throws -> Data {
  let blob = try OpCodec.encodeBlobOps([op])
  let doc = try JSONParser.parse(blob)
  return Data(JSONWriter().bytes(doc["ops"]!.arrayValue![0]))
}

/// Every op the store holds, opened (what a fold would read).
func storedOps(_ ctx: SyncContext) throws -> [Op] {
  let key = try EpochKey(epoch: 1, key: try #require(try ctx.secrets.epochKey(userID: ctx.userID, epoch: 1)))
  let opener = Opener(epochHWM: 1, keys: [key])
  var out: [Op] = []
  for r in try ctx.store.wireRows(after: 0, limit: 10_000) where r.disposition == .folded {
    let env = try Envelope(userID: ctx.userID, writerID: r.writerID, counter: r.counter)
    guard case .opened(let p) = opener.open(r.blob, envelope: env, prevHash: r.prevHash) else { continue }
    out += try OpCodec.decodeBlobOps(p)
  }
  return out
}
