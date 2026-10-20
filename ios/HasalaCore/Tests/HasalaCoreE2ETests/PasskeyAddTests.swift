import CoreAuth
import CoreCrypto
import CoreSoftAuth
import CoreSync
import CoreTestSupport
import Foundation
import Testing

struct SplitPasskeys: PasskeyProvider {
  let asserting: SoftPasskey
  let creating: SoftPasskey

  func register(_ options: CreationOptions, prfSalt: Data?) async throws(PasskeyError) -> RawRegistration {
    try await creating.register(options, prfSalt: prfSalt)
  }

  func assert(challenge: Data, allowCredentialIDs: [Data], prfSalt: Data?) async throws(PasskeyError) -> RawAssertion {
    try await asserting.assert(challenge: challenge, allowCredentialIDs: allowCredentialIDs, prfSalt: prfSalt)
  }
}

@Suite("Adding a passkey (passkey.add)")
struct PasskeyAddTests {
  @Test("a password account adds a passkey with its password and the DAK; with the words' body it unlocks a new iPhone")
  func passwordAccountWithBody() async throws {
    let w = World()
    let shared = SoftPasskey()
    let a = w.phone("a", passkeys: shared)
    let (account, words, _) = try await w.passwordAccount(a)
    let body = try await Enrolment.unlockWithPhrase(a.env, userID: account.userID, typed: words.joined(separator: " "))
    defer { body.wipe() }
    let added = try await AccountPasskeys.add(
      a.env, binding: try #require(a.binding), factor: .device(password: password), body: body, reason: "x")
    #expect(added.unlocksData)
    #expect(a.dak.signatureCount == 1)
    let token = try #require(try a.env.secrets.session()).token
    let info = try await a.env.client.account(bearer: token)
    #expect(info.has_passkey == true && info.has_password == true)
    let wraps = try await a.env.client.keyWraps(bearer: token).wraps
    #expect(wraps.map(\.credential_id) == [Base64.encodeURL(added.credentialID)])

    _ = try await StepUpHelper.prove(a.env, params: .sessionLogoutAll, factor: .passkey, binding: a.binding, reason: "x")

    let b = w.phone("b", passkeys: shared)
    let r = try await AccountSignIn.withPasskey(b.env, bound: nil, wantPRF: true)
    let assertion = try #require(r.assertion)
    #expect(assertion.credentialID == added.credentialID)
    let opened = try await Enrolment.unlockWithPRF(
      b.env, userID: account.userID, credentialID: assertion.credentialID, prf: assertion.prfFirst)
    defer { opened.wipe() }
    let enrolled = try await Enrolment.enrolWriter(b.env, userID: account.userID, body: opened, emailNorm: nil, serverSalt: nil)
    #expect(enrolled.writerID != account.writerID)
  }

  @Test("without a body, or without PRF, the passkey signs in but carries no wrap")
  func noWrap() async throws {
    for prf in [true, false] {
      let w = World()
      let shared = SoftPasskey()
      shared.setPRFSupported(prf)
      let a = w.phone("a", passkeys: shared)
      let (account, words, _) = try await w.passwordAccount(a)
      let body: KeyBody? =
        prf ? nil : try await Enrolment.unlockWithPhrase(a.env, userID: account.userID, typed: words.joined(separator: " "))
      defer { body?.wipe() }
      let added = try await AccountPasskeys.add(
        a.env, binding: try #require(a.binding), factor: .device(password: password), body: body, reason: "x")
      #expect(!added.unlocksData)
      let token = try #require(try a.env.secrets.session()).token
      #expect(try await a.env.client.keyWraps(bearer: token).wraps.isEmpty)
      #expect(try await a.env.client.account(bearer: token).has_passkey == true)
      let b = w.phone("b", passkeys: shared)
      let r = try await AccountSignIn.withPasskey(b.env, bound: nil, wantPRF: true)
      #expect(r.userID == account.userID)
    }
  }

  @Test("a wrong password adds nothing and the passkey sheet never opens")
  func wrongPassword() async throws {
    let w = World()
    let shared = SoftPasskey()
    let a = w.phone("a", passkeys: shared)
    _ = try await w.passwordAccount(a)
    let binding = try #require(a.binding)
    do throws(CeremonyError) {
      _ = try await AccountPasskeys.add(
        a.env, binding: binding, factor: .device(password: "not my password at all"), body: nil, reason: "x")
      Issue.record("expected step_up_failed")
    } catch {
      #expect(error.failure?.code == "step_up_failed")
    }
    let token = try #require(try a.env.secrets.session()).token
    #expect(try await a.env.client.account(bearer: token).has_passkey == false)
    let b = w.phone("b", passkeys: shared)
    await #expect(throws: CeremonyError.self) {
      _ = try await AccountSignIn.withPasskey(b.env, bound: nil, wantPRF: false)
    }
  }

  @Test("a password account cannot prove passkey.add with a passkey it does not have")
  func passkeyFactorWithoutAPasskey() async throws {
    let w = World()
    let a = w.phone("a")
    _ = try await w.passwordAccount(a)
    await #expect(throws: CeremonyError.self) {
      _ = try await AccountPasskeys.add(a.env, binding: try #require(a.binding), factor: .passkey, body: nil, reason: "x")
    }
    let token = try #require(try a.env.secrets.session()).token
    #expect(try await a.env.client.account(bearer: token).has_passkey == false)
  }

  @Test("a passkey account's second passkey is wrapped with the body its own step-up opens")
  func passkeyAccountSecondPasskey() async throws {
    let w = World()
    let first = SoftPasskey()
    let second = SoftPasskey()
    let a = w.phone("a", passkeys: first)
    let signup = try await AccountCreation.beginSignup(
      a.env, inviteCode: invite, email: "maya@example.com", displayName: "Maya", inviteLinkKey: nil)
    try await AccountCreation.verifySignup(a.env, signup, code: try #require(w.server.lastCode))
    let keys = try NewAccountKeys.generate(random: a.env.random)
    let reg = try await AccountCreation.registerPasskey(a.env, signup: signup, keys: keys)
    let account = try await AccountCreation.bootstrapPasskey(a.env, registered: reg, keys: keys)
    let env = AccountEnvironment(
      client: a.env.client, secrets: a.env.secrets, approvalKeys: a.dak,
      passkeys: SplitPasskeys(asserting: first, creating: second), clock: w.clock, random: a.env.random,
      apiBase: a.env.apiBase, accountsDirectory: nil)
    let added = try await AccountPasskeys.add(env, binding: try #require(a.binding), factor: .passkey, body: nil, reason: "x")
    #expect(added.unlocksData)
    #expect(a.dak.signatureCount == 0)

    let b = w.phone("b", passkeys: second)
    let r = try await AccountSignIn.withPasskey(b.env, bound: nil, wantPRF: true)
    let assertion = try #require(r.assertion)
    let opened = try await Enrolment.unlockWithPRF(
      b.env, userID: account.userID, credentialID: assertion.credentialID, prf: assertion.prfFirst)
    opened.wipe()
  }
}
