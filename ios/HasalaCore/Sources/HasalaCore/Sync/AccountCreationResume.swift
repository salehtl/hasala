// C1 interrupted after `register/finish` (spec 04 §6.2's "C1 interrupted" row,
// R-04): the session survived but the secrets never reached the server, so
// `GET /keys` answers `404 no_keys` and a sign-in answers `has_keys: false`.
//
//   new secrets (a NEW phrase, which the UI shows with S-07 and confirms)
//   → step-up keys.bootstrap with a passkey, T = (new AAK.pub), PRF input
//   → new writer id, DWK and DAK → #23 challenge
//   → #18 bootstrap {auth_kind 0x00, auth_hash 0^32, the asserting
//     credential's PRF wrap when the assertion gave PRF output, step_up}
//   → Keychain, store, roster, E-04 comparison, binding (as C1)
import CoreAuth
import CoreCrypto
import CorePrimitives
import CoreStore
import CoreWire
import Foundation

extension AccountCreation {
  /// Finishes an account whose C1 stopped after `register/finish`. `keys` are new
  /// (never the lost ones); the caller has shown and confirmed their phrase.
  /// The address, `s_srv` and the display name come from `GET /account`.
  public static func bootstrapInterrupted(_ env: AccountEnvironment, keys: NewAccountKeys)
    async throws(CeremonyError) -> EnrolledAccount
  {
    let bearer = try currentBearer(env)
    let account = try await apiStep { () async throws(APIError) in try await env.client.account(bearer: bearer) }
    guard let user = UserID(account.user_id) else { throw .badResponse("account user_id") }
    guard let email = account.email.flatMap({ try? EmailNorm.normalize($0) }),
      let salt = account.password_salt.flatMap({ try? Base64.decode($0) })
    else { throw .badResponse("account email or salt") }
    let aak = try keys.authorityPublicKey()
    let proof = try await StepUpHelper.prove(
      env, params: .keysBootstrap(authorityPublicKey: aak), factor: .passkey, binding: nil,
      reason: "Confirm it's you to finish setting up")
    defer { proof.prf?.wipe() }
    let device = try await NewDevice.mint(env, userID: user)
    var prfWrap: (Data, Data)?
    if let p = proof.prf, let id = proof.credentialID {
      let w = try cryptoStep("prf wrap") {
        try Wrap.sealPRF(body: keys.body, prfOutput: p, userID: user, credentialID: id, random: env.random)
      }
      prfWrap = (id, w)
    }
    let challenge = try await apiStep { () async throws(APIError) in try await env.client.writerChallenge(bearer: bearer) }
    let nonce = try b64(challenge.nonce, "writer nonce")
    var body = try buildBootstrap(
      env, userID: user, emailNorm: email, keys: keys, device: device, authKind: .none, authHash: Data(count: 32),
      prfWrap: prfWrap, nonce: nonce)
    body.step_up = proof.stepUp
    let r = try await apiStep { () async throws(APIError) in try await env.client.bootstrap(body, bearer: bearer) }
    guard r.writer_id == device.writerID.string else { throw .badResponse("bootstrap writer_id") }
    let grant = SessionGrant(
      session_token: bearer, user_id: user.string, expires_at: nil, writer_id: r.writer_id, has_keys: true,
      restricted: false)
    return try await persistAndCompare(
      env, grant: grant, userID: user, device: device, keys: keys, emailNorm: email, serverSalt: salt,
      displayName: account.display_name, recoveryWrap: body.recovery_wrap, recoveryPublicKey: body.recovery_pubkey,
      sessionAlreadyWritten: true)
  }
}
