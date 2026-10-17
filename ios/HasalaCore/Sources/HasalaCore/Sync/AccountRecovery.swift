// Access recovery with the twelve words and an email code, to a new passkey
// (C4; spec 04 §6.2, `02` routes #7, #48, #8; server/internal/auth/recovery.go).
//
//   begin:   E ← the words; RK.pub = Ed25519.pub(HKDF(E, 0^32, D04)); #7
//            recover/begin {recovery_pubkey} → the ceremony and the address hint
//   verify:  #48 recover/verify {code, kind: passkey} → the recover nonce, the
//            account's published keys, its recovery wrap and the creation options;
//            the wrap is opened with E and the commitments checked HERE, before
//            any prompt (a server that answers another account's keys is refused)
//   finish:  a new writer (DWK, DAK; no prompt); the passkey sheet (UV, PRF);
//            a PRF wrap when the authenticator gave PRF output; RK signs
//            RecoverySigninMessage (D18) over the raw creation bytes and the wrap,
//            the AAK signs RegistrationMessage over the recover nonce; #8
//            recover/finish → a session bound to the new writer (every other
//            session is revoked); then the session, K_1, the store and the pinned
//            roster, and the binding last, as every enrolment ends
//
// Only a new passkey: a new password needs the address for its stretch
// (01 §10.6 salt = s_srv ‖ email_norm), and #48 answers only the masked hint.
import CoreAuth
import CoreCrypto
import CorePrimitives
import CoreStore
import CoreWire
import Foundation

/// A recovery ceremony in progress. Holds the phrase entropy (and, once verified, the
/// unwrapped body) in memory only; `wipe()` zeroes both.
public final class Recovery: @unchecked Sendable {  // mutated by one ceremony at a time
  public let ceremonyID: String
  /// "m•••@g•••.com"
  public let emailHint: String
  let entropy: SecureBytes
  let recoveryPublicKey: Data
  fileprivate(set) var verified: Verified?

  struct Verified {
    let nonce: Data
    let userID: UserID
    let body: KeyBody
    let options: CreationOptions
  }

  init(ceremonyID: String, emailHint: String, entropy: SecureBytes, recoveryPublicKey: Data) {
    self.ceremonyID = ceremonyID
    self.emailHint = emailHint
    self.entropy = entropy
    self.recoveryPublicKey = recoveryPublicKey
  }

  /// The account the code was verified for (nil before `verify`).
  public var userID: UserID? { verified?.userID }

  public func wipe() {
    entropy.wipe()
    verified?.body.wipe()
  }
}

public enum AccountRecovery {
  /// #7. `.badPhrase` when the words aren't a phrase; the server answers 404
  /// `not_found` for words that are no active account's.
  public static func begin(_ env: AccountEnvironment, typed: String) async throws(CeremonyError) -> Recovery {
    let entropy: SecureBytes
    do { entropy = try Phrase.entropy(typed: typed) } catch { throw .badPhrase }
    let rk: Data
    do { rk = try KeyDerivation.recoveryPublicKey(entropy: entropy) } catch {
      entropy.wipe()
      throw .crypto("recovery key")
    }
    do {
      let r: RecoverBeginAnswer = try await env.client.api.call(
        .post, "/api/v1/auth/recover/begin", json: RecoverBeginBody(recovery_pubkey: Base64.encode(rk)))
      return Recovery(ceremonyID: r.ceremony_id, emailHint: r.email_hint, entropy: entropy, recoveryPublicKey: rk)
    } catch {
      entropy.wipe()
      throw .api(error)
    }
  }

  /// #48 for a new passkey. A wrong code throws the server's `code_rejected` (the
  /// ceremony stays verifiable until it expires). The commitments of the unwrapped
  /// body are checked against the answer before this returns.
  public static func verifyForPasskey(_ env: AccountEnvironment, _ r: Recovery, code: String)
    async throws(CeremonyError)
  {
    let a: RecoverVerifyAnswer = try await apiStep { () async throws(APIError) in
      try await env.client.api.call(
        .post, "/api/v1/auth/recover/verify",
        json: RecoverVerifyBody(ceremony_id: r.ceremonyID, code: code, kind: "passkey"))
    }
    guard let user = UserID(a.user_id) else { throw .badResponse("recover user_id") }
    let nonce = try b64(a.nonce, "recover nonce")
    guard nonce.count == 32 else { throw .badResponse("recover nonce length") }
    let published = PublishedAccountKeys(
      userID: user, recoveryPublicKey: r.recoveryPublicKey, amkCommitment: try b64(a.amk_commitment, "amk_commitment"),
      authorityPublicKey: try b64(a.authority_pubkey, "authority_pubkey"))
    let body: KeyBody
    do {
      body = try AccountUnlock.withPhrase(
        entropy: r.entropy, recoveryWrap: try b64(a.recovery_wrap, "recovery_wrap"), published: published)
    } catch let e as CeremonyError {
      throw e
    } catch {
      // The server matched these words' key (#7), so a wrap or a commitment that
      // doesn't open is the server's answer, not the person's typing.
      throw .integrityAlarm("recovery commitments")
    }
    guard let wire = a.options, let options = try? wire.decoded() else {
      body.wipe()
      throw .badResponse("recover options")
    }
    r.verified?.body.wipe()
    r.verified = Recovery.Verified(nonce: nonce, userID: user, body: body, options: options)
  }

  /// #8 with a new passkey, then this iPhone's enrolment. One passkey sheet.
  public static func finishWithPasskey(_ env: AccountEnvironment, _ r: Recovery) async throws(CeremonyError)
    -> EnrolledAccount
  {
    guard let v = r.verified else { throw .badResponse("recovery not verified") }
    guard let passkeys = env.passkeys else { throw .passkey(.unsupported) }
    let device = try await NewDevice.mint(env, userID: v.userID)
    let reg: RawRegistration
    do { reg = try await passkeys.register(v.options, prfSalt: KeyDerivation.prfSalt) } catch { throw .passkey(error) }
    defer { reg.prfFirst?.wipe() }
    var prfWrap: Data?
    if let p = reg.prfFirst {
      prfWrap = try cryptoStep("prf wrap") {
        try Wrap.sealPRF(body: v.body, prfOutput: p, userID: v.userID, credentialID: reg.credentialID, random: env.random)
      }
    }
    let (rkSig, registrationSig) = try cryptoStep("recovery signatures") {
      let rkSeed = try KeyDerivation.recoveryKeySeed(entropy: r.entropy)
      defer { rkSeed.wipe() }
      let rkSig = try Ed25519.sign(
        seed: rkSeed,
        message: try SigningMessage.recoverySigninPasskey(
          nonce: v.nonce, clientDataJSON: reg.rawClientDataJSON, attestationObject: reg.rawAttestationObject,
          prfWrap: prfWrap))
      let registrationSig = try v.body.signWithAuthority(
        try SigningMessage.registration(
          nonce: v.nonce, writerID: device.writerID, dwkPublicKey: device.dwkPublic, dakPublicKey: device.dakPublic))
      return (rkSig, registrationSig)
    }
    let w = WriterJSON(
      writerID: device.writerID.string, pubkeyB64: Base64.encode(device.dwkPublic),
      dakPubkeyB64: Base64.encode(device.dakPublic))
    let grant: SessionGrant = try await apiStep { () async throws(APIError) in
      try await env.client.api.call(
        .post, "/api/v1/auth/recover/finish",
        json: RecoverFinishBody(
          ceremony_id: r.ceremonyID, kind: "passkey", credential: reg.credential,
          prf_wrap: prfWrap.map {
            BootstrapPRFWrapJSON(credentialIDB64URL: Base64.encodeURL(reg.credentialID), wrapB64: Base64.encode($0))
          },
          rk_sig: Base64.encode(rkSig),
          writer: RecoverWriterBody(
            writer_id: w.writer_id, alg: w.alg, pubkey: w.pubkey, dak_pubkey: w.dak_pubkey,
            registration_sig: Base64.encode(registrationSig))))
    }
    guard grant.user_id == v.userID.string, grant.writer_id == device.writerID.string else {
      throw .badResponse("recover session")
    }
    try AccountCreation.writeSession(env, grant)
    let account = try await apiStep { () async throws(APIError) in
      try await env.client.account(bearer: grant.session_token)
    }
    guard let email = account.email.flatMap({ try? EmailNorm.normalize($0) }),
      let salt = account.password_salt.flatMap({ try? Base64.decode($0) })
    else { throw .badResponse("account email or salt") }
    let k1 = try cryptoStep("K_1") { try v.body.epochKey1(userID: v.userID) }
    defer { k1.wipe() }
    let aak = try cryptoStep("aak") { try v.body.authorityPublicKey() }
    let enrolled = try await Enrolment.persist(
      env, userID: v.userID, device: device, epochKey: k1, emailNorm: email, serverSalt: salt,
      displayName: account.display_name, authorityPublicKey: aak)
    r.wipe()
    return enrolled
  }
}

// MARK: Wire (`02` #7, #48, #8; server/internal/api/routes_recover.go)

struct RecoverBeginBody: Encodable, Sendable {
  let recovery_pubkey: String
}

struct RecoverBeginAnswer: Decodable, Sendable {
  let ceremony_id: String
  let email_hint: String
}

struct RecoverVerifyBody: Encodable, Sendable {
  let ceremony_id: String
  let code: String
  let kind: String
}

struct RecoverVerifyAnswer: Decodable, Sendable {
  let nonce: String
  let user_id: String
  let amk_commitment: String
  let authority_pubkey: String
  let recovery_wrap: String
  let current_epoch: Int
  let options: WireCreationOptions?
}

struct RecoverWriterBody: Encodable, Sendable {
  let writer_id: String
  let alg: String
  let pubkey: String
  let dak_pubkey: String
  let registration_sig: String
}

struct RecoverFinishBody: Encodable, Sendable {
  let ceremony_id: String
  let kind: String
  let credential: PublicKeyCredentialJSON
  let prf_wrap: BootstrapPRFWrapJSON?
  let rk_sig: String
  let writer: RecoverWriterBody
}
