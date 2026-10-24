// Signup and account creation (spec 04 §6.2 signup steps 1–6, C1, C1-P;
// spec 01 §10.3; `02` §10.7).
//
//   signup:  #43 signup/begin → (not proven) #44 signup/verify
//   C1-P:    S ← stretch; secrets, DAK, writer id; the phrase confirmed by the UI;
//            ONE #45 password/register with the bootstrap; Keychain; E-04 compare
//   C1:      #3 register/begin (C_reg recomputed, a mismatch refused before the sheet);
//            the passkey sheet (UV, PRF); #4 register/finish; the session written AT ONCE (R-04);
//            the phrase confirmed by the UI; #23 + #18 bootstrap; Keychain; E-04 compare
//
// Nothing is published before the UI confirms the phrase: the caller runs the
// confirmation between `NewAccountKeys.generate` and the bootstrap step.
import CoreAuth
import CoreCrypto
import CorePrimitives
import CoreStore
import CoreWire
import Foundation

/// A signup ceremony in progress (`02` #43's answer, normalized).
public struct Signup: Sendable, Hashable {
  public let id: String
  public let userID: UserID
  public let emailNorm: String
  public let displayName: String
  public let emailProven: Bool
  /// `s_srv` for this address.
  public let serverSalt: Data
  /// The signup nonce (C1-P's bootstrap signs over it).
  public let nonce: Data
}

/// The secrets of a new account, in memory for the ceremony only (01 §11.5).
public final class NewAccountKeys: @unchecked Sendable {
  public let entropy: SecureBytes
  public let body: KeyBody

  init(entropy: SecureBytes, body: KeyBody) {
    self.entropy = entropy
    self.body = body
  }

  /// A fresh phrase entropy `E` and body (AMK, AAK seed).
  public static func generate(random: some RandomSource) throws(CeremonyError) -> NewAccountKeys {
    do {
      return NewAccountKeys(entropy: try Phrase.generate(random: random), body: try KeyBody.generate(random: random))
    } catch {
      throw .crypto("generate")
    }
  }

  /// The twelve words to show (§6.7), never stored.
  public func words() throws(CeremonyError) -> [String] {
    do { return try Phrase.words(entropy: entropy) } catch { throw .crypto("words") }
  }

  public func authorityPublicKey() throws(CeremonyError) -> Data {
    do { return try body.authorityPublicKey() } catch { throw .crypto("aak") }
  }

  /// Zeroes `E`, AMK and the AAK seed (step 15).
  public func wipe() {
    entropy.wipe()
    body.wipe()
  }
}

/// A device that has a bound session, its writer, its keys in the Keychain and
/// its store: what `SyncContext` is built from.
public struct EnrolledAccount: Sendable {
  public let userID: UserID
  public let writerID: WriterID
  public let store: LedgerStore
  public let binding: AccountBinding
}

/// The state between C1's `register/finish` and its bootstrap.
public struct RegisteredPasskey: @unchecked Sendable {  // `prf` is wiped by the bootstrap's caller
  public let signup: Signup
  public let userID: UserID
  public let credentialID: Data
  /// `SHA256(rawAttestationObject)` = `auth_hash` (R-01).
  public let attestationHash: Data
  /// The creation's PRF output, when the authenticator gave one.
  public let prf: SecureBytes?
  public let backup: BackupFlags?
}

public enum AccountCreation {
  // MARK: Signup (#43, #44)

  public static func beginSignup(
    _ env: AccountEnvironment, inviteCode: String, email: String, displayName: String, inviteLinkKey: String?
  ) async throws(CeremonyError) -> Signup {
    guard let code = AuthInput.inviteCode(inviteCode) else { throw .badInviteCode }
    let emailNorm: String
    do { emailNorm = try EmailNorm.normalize(email) } catch { throw .badEmail }
    guard case .success(let name) = DisplayName.validate(displayName) else { throw .badName }
    let r = try await apiStep { () async throws(APIError) in
      try await env.client.signupBegin(
        SignupBeginRequest(inviteCode: code, email: emailNorm, displayName: name, inviteLinkKey: inviteLinkKey))
    }
    guard let user = UserID(r.user_id) else { throw .badResponse("signup user_id") }
    let salt = try b64(r.salt, "signup salt")
    let nonce = try b64(r.nonce, "signup nonce")
    guard salt.count == 32, nonce.count == 32 else { throw .badResponse("signup salt/nonce length") }
    return Signup(
      id: r.signup_id, userID: user, emailNorm: emailNorm, displayName: name, emailProven: r.email_proven,
      serverSalt: salt, nonce: nonce)
  }

  public static func verifySignup(_ env: AccountEnvironment, _ s: Signup, code: String) async throws(CeremonyError) {
    try await apiStep { () async throws(APIError) in try await env.client.signupVerify(signupID: s.id, code: code) }
  }

  // MARK: C1-P

  /// C1-P steps 4–10, after the UI has shown and confirmed the phrase.
  public static func createWithPassword(
    _ env: AccountEnvironment, signup: Signup, password: String, keys: NewAccountKeys
  ) async throws(CeremonyError) -> EnrolledAccount {
    let s: SecureBytes
    do {
      s = try PasswordStretch.stretch(password: password, serverSalt: signup.serverSalt, emailNorm: signup.emailNorm)
    } catch {
      throw .crypto("stretch")
    }
    defer { s.wipe() }
    let device = try await NewDevice.mint(env, userID: signup.userID)
    let authHash = StepUpParams.verifierHash(s)
    let body = try buildBootstrap(
      env, userID: signup.userID, emailNorm: signup.emailNorm, keys: keys, device: device, authKind: .password,
      authHash: authHash, prfWrap: nil, nonce: signup.nonce)
    let grant = try await apiStep { () async throws(APIError) in
      try await env.client.passwordRegister(
        PasswordRegisterRequest(signupID: signup.id, verifierB64: s.withUnsafeBytes { Base64.encode($0) }, bootstrap: body))
    }
    guard grant.user_id == signup.userID.string else { throw .badResponse("register user_id") }
    return try await persistAndCompare(
      env, grant: grant, userID: signup.userID, device: device, keys: keys, emailNorm: signup.emailNorm,
      serverSalt: signup.serverSalt, displayName: signup.displayName, recoveryWrap: body.recovery_wrap,
      recoveryPublicKey: body.recovery_pubkey)
  }

  // MARK: C1

  /// C1 steps 5–9: the passkey is created and the session is written at once
  /// (R-04). The bootstrap follows the phrase confirmation.
  public static func registerPasskey(_ env: AccountEnvironment, signup: Signup, keys: NewAccountKeys)
    async throws(CeremonyError) -> RegisteredPasskey
  {
    guard let passkeys = env.passkeys else { throw .passkey(.unsupported) }
    let aak = try keys.authorityPublicKey()
    let begin = try await apiStep { () async throws(APIError) in
      try await env.client.registerBegin(
        RegisterBeginRequest(signupID: signup.id, authorityPublicKeyB64: Base64.encode(aak)))
    }
    let nonce = try b64(begin.nonce, "register nonce")
    let options: CreationOptions
    do { options = try begin.options.decoded() } catch { throw .badResponse("register options") }
    // Step 6: recompute C_reg and refuse a different challenge before any sheet.
    guard let mine = try? SigningMessage.registerChallenge(nonce: nonce, authorityPublicKey: aak),
      constantTimeEquals(mine, options.challenge)
    else { throw .challengeMismatch }
    let reg: RawRegistration
    do { reg = try await passkeys.register(options, prfSalt: KeyDerivation.prfSalt) } catch { throw .passkey(error) }
    let grant = try await apiStep { () async throws(APIError) in
      try await env.client.registerFinish(RegisterFinishRequest(ceremonyID: begin.ceremony_id, credential: reg.credential))
    }
    guard grant.user_id == signup.userID.string else { throw .badResponse("register user_id") }
    try writeSession(env, grant)
    return RegisteredPasskey(
      signup: signup, userID: signup.userID, credentialID: reg.credentialID,
      attestationHash: sha256(reg.rawAttestationObject), prf: reg.prfFirst, backup: reg.backupFlags)
  }

  /// C1 steps 11–15 (16: TODO below).
  public static func bootstrapPasskey(
    _ env: AccountEnvironment, registered: RegisteredPasskey, keys: NewAccountKeys, phraseUnseen: Bool = false
  ) async throws(CeremonyError) -> EnrolledAccount {
    let bearer = try currentBearer(env)
    let user = registered.userID
    let device = try await NewDevice.mint(env, userID: user)
    var prfWrap: (Data, Data)?
    if let p = registered.prf {
      let w = try cryptoStep("prf wrap") {
        try Wrap.sealPRF(
          body: keys.body, prfOutput: p, userID: user, credentialID: registered.credentialID, random: env.random)
      }
      prfWrap = (registered.credentialID, w)
    }
    let challenge = try await apiStep { () async throws(APIError) in try await env.client.writerChallenge(bearer: bearer) }
    let nonce = try b64(challenge.nonce, "writer nonce")
    var body = try buildBootstrap(
      env, userID: user, emailNorm: registered.signup.emailNorm, keys: keys, device: device, authKind: .passkey,
      authHash: registered.attestationHash, prfWrap: prfWrap, nonce: nonce)
    if phraseUnseen { body.phrase_unseen = true }
    let r = try await apiStep { () async throws(APIError) in try await env.client.bootstrap(body, bearer: bearer) }
    guard r.writer_id == device.writerID.string else { throw .badResponse("bootstrap writer_id") }
    let grant = SessionGrant(
      session_token: bearer, user_id: user.string, expires_at: nil, writer_id: r.writer_id, has_keys: true,
      restricted: false)
    // TODO(WS-14, C1 step 16): with no PRF output at creation, run step-up
    // `keys.wrap.put` with PRF (a second prompt) and POST /keys/wraps with
    // `dwk_sig`; until then such an account unlocks a new iPhone with the phrase.
    return try await persistAndCompare(
      env, grant: grant, userID: user, device: device, keys: keys, emailNorm: registered.signup.emailNorm,
      serverSalt: registered.signup.serverSalt, displayName: registered.signup.displayName,
      recoveryWrap: body.recovery_wrap, recoveryPublicKey: body.recovery_pubkey, sessionAlreadyWritten: true)
  }

  // MARK: Shared

  /// The BootstrapPayload (01 §10.3.1) and `02` §10.1's body, signed by the AAK
  /// (BootstrapMessage and RegistrationMessage over `nonce`).
  static func buildBootstrap(
    _ env: AccountEnvironment, userID: UserID, emailNorm: String, keys: NewAccountKeys, device: NewDevice,
    authKind: AuthKind, authHash: Data, prfWrap: (Data, Data)?, nonce: Data
  ) throws(CeremonyError) -> BootstrapBody {
    try cryptoStep("bootstrap") {
      let body = keys.body
      let aak = try body.authorityPublicKey()
      let rkPub = try KeyDerivation.recoveryPublicKey(entropy: keys.entropy)
      let commit = try body.amkCommitment(userID: userID)
      let recoveryWrap = try Wrap.sealRecovery(body: body, entropy: keys.entropy, userID: userID, random: env.random)
      let box = try PhraseBox.seal(
        entropy: keys.entropy, amk: body.amk, userID: userID, recoveryPublicKey: rkPub, random: env.random)
      let payload = try BootstrapPayload(
        userID: userID, amkCommitment: commit, authorityPublicKey: aak, recoveryPublicKey: rkPub,
        recoveryWrap: recoveryWrap, phraseBox: box, emailNorm: emailNorm, authKind: authKind, authHash: authHash,
        writerPublicKey: device.dwkPublic, writerDAKPublicKey: device.dakPublic, writerID: device.writerID,
        prfWrap: prfWrap.map { (credentialID: $0.0, wrap: $0.1) }
      ).encoded()
      let authoritySig = try body.signWithAuthority(try SigningMessage.bootstrap(nonce: nonce, payload: payload))
      let registrationSig = try body.signWithAuthority(
        try SigningMessage.registration(
          nonce: nonce, writerID: device.writerID, dwkPublicKey: device.dwkPublic, dakPublicKey: device.dakPublic))
      return BootstrapBody(
        amkCommitment: Base64.encode(commit), authorityPubkey: Base64.encode(aak), recoveryPubkey: Base64.encode(rkPub),
        recoveryWrap: Base64.encode(recoveryWrap), phraseBox: Base64.encode(box),
        emailHash: Base64.encode(EmailNorm.hash(emailNorm)), authKind: Int(authKind.rawValue),
        authHash: Base64.encode(authHash),
        prfWrap: prfWrap.map { BootstrapPRFWrapJSON(credentialIDB64URL: Base64.encodeURL($0.0), wrapB64: Base64.encode($0.1)) },
        writer: WriterJSON(
          writerID: device.writerID.string, pubkeyB64: Base64.encode(device.dwkPublic),
          dakPubkeyB64: Base64.encode(device.dakPublic)),
        nonce: Base64.encode(nonce), authoritySig: Base64.encode(authoritySig),
        registrationSig: Base64.encode(registrationSig))
    }
  }

  static func writeSession(_ env: AccountEnvironment, _ grant: SessionGrant) throws(CeremonyError) {
    let record: SessionRecord
    do {
      record = try SessionRecord.minted(
        token: grant.session_token, userID: grant.user_id,
        expiresAt: RFC3339.seconds(grant.expires_at) ?? (env.clock.nowMs() / 1000 + 90 * 86400), random: env.random)
    } catch {
      throw .crypto("session tag")
    }
    try secretStep { () throws(SecretStoreError) in try env.secrets.writeSession(record) }
  }

  static func currentBearer(_ env: AccountEnvironment) throws(CeremonyError) -> String {
    guard let s = try secretStep({ () throws(SecretStoreError) in try env.secrets.session() }) else {
      throw .api(.refused(APIFailure(status: 401, code: "unauthorized")))
    }
    return s.token
  }

  /// Step 10/15 of C1-P/C1: the Keychain (session, `K_1`; the DWK went in at
  /// mint), the store, the pinned roster; then E-04's comparison; then the
  /// binding item. A difference raises the integrity alarm and stops
  /// onboarding: the binding is never written, so boot never opens the
  /// account (it stays at `onboardingKeys`, C1's interrupted path).
  static func persistAndCompare(
    _ env: AccountEnvironment, grant: SessionGrant, userID: UserID, device: NewDevice, keys: NewAccountKeys,
    emailNorm: String, serverSalt: Data, displayName: String?, recoveryWrap: String, recoveryPublicKey: String,
    sessionAlreadyWritten: Bool = false
  ) async throws(CeremonyError) -> EnrolledAccount {
    if !sessionAlreadyWritten { try writeSession(env, grant) }
    let k1 = try cryptoStep("K_1") { try keys.body.epochKey1(userID: userID) }
    defer { k1.wipe() }
    let aak = try keys.authorityPublicKey()
    let commit = try cryptoStep("commit") { try keys.body.amkCommitment(userID: userID) }
    let account = try await Enrolment.persist(
      env, userID: userID, device: device, epochKey: k1, emailNorm: emailNorm, serverSalt: serverSalt,
      displayName: displayName, authorityPublicKey: aak,
      beforeBinding: { () async throws(CeremonyError) in
        try await compareAfterBootstrap(
          env, commit: commit, authorityPublicKey: aak, recoveryPublicKey: recoveryPublicKey,
          recoveryWrap: recoveryWrap, emailNorm: emailNorm)
      })
    keys.wipe()
    return account
  }

  /// E-04: `GET /keys` and `GET /account` must equal this device's values. An
  /// address that is missing from the answer is a difference (`02` #40 always
  /// returns it to the account's own session).
  static func compareAfterBootstrap(
    _ env: AccountEnvironment, commit: Data, authorityPublicKey: Data, recoveryPublicKey: String,
    recoveryWrap: String, emailNorm: String
  ) async throws(CeremonyError) {
    let bearer = try currentBearer(env)
    let k = try await apiStep { () async throws(APIError) in try await env.client.keys(bearer: bearer) }
    guard k.amk_commitment == Base64.encode(commit), k.authority_pubkey == Base64.encode(authorityPublicKey),
      k.recovery_pubkey == recoveryPublicKey, k.recovery_wrap == recoveryWrap
    else { throw .integrityAlarm("keys differ after bootstrap") }
    let a = try await apiStep { () async throws(APIError) in try await env.client.account(bearer: bearer) }
    guard let e = a.email, (try? EmailNorm.normalize(e)) == emailNorm else {
      throw .integrityAlarm("address differs after bootstrap")
    }
  }
}
