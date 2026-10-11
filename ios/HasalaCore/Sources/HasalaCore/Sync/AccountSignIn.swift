// Sign-in (spec 04 §6.2 C2, C2-P, C2b, C2b-P; §6.4), sign-out (§4.7 row 1)
// and the step-up helper (§6.3).
//
// A bound iPhone (one with a binding and its DWK) always signs in WITH its
// writer: `device = {writer_id, Ed25519(DWK, SessionBindMessage(challenge, writer_id))}`
// where the challenge is the passkey ceremony's `options.challenge` (#6) or
// the password ceremony's `nonce` (#47, E-05).
import CoreAuth
import CoreCrypto
import CorePrimitives
import CoreStore
import CoreWire
import Foundation

public struct SignInResult: Sendable {
  public let grant: SessionGrant
  /// The address and salt of a password sign-in (the binding needs both).
  public let emailNorm: String?
  public let serverSalt: Data?
  /// The passkey assertion of a passkey sign-in (its PRF output unlocks, C2).
  public let assertion: RawAssertion?

  public var userID: UserID? { UserID(grant.user_id) }
  public var hasKeys: Bool { grant.has_keys ?? false }
  public var restricted: Bool { grant.restricted ?? false }
  public var boundWriter: WriterID? { grant.writer_id.flatMap(WriterID.init) }
}

public enum AccountSignIn {
  /// C2-P / C2b-P. `bound` is this iPhone's binding when it has a live writer.
  public static func withPassword(
    _ env: AccountEnvironment, email: String, password: String, bound: AccountBinding?
  ) async throws(CeremonyError) -> SignInResult {
    let emailNorm: String
    do { emailNorm = try EmailNorm.normalize(email) } catch { throw .badEmail }
    let begin = try await apiStep { () async throws(APIError) in try await env.client.passwordLoginBegin(email: emailNorm) }
    let salt = try b64(begin.salt, "login salt")
    let nonce = try b64(begin.nonce, "login nonce")
    let s: SecureBytes
    do { s = try PasswordStretch.stretch(password: password, serverSalt: salt, emailNorm: emailNorm) } catch {
      throw .crypto("stretch")
    }
    defer { s.wipe() }
    let device = try binding(env, bound: bound, challenge: nonce)
    let grant = try await apiStep { () async throws(APIError) in
      try await env.client.passwordLoginFinish(
        PasswordLoginFinishRequest(
          ceremonyID: begin.ceremony_id, verifierB64: s.withUnsafeBytes { Base64.encode($0) }, device: device))
    }
    try AccountCreation.writeSession(env, grant)
    return SignInResult(grant: grant, emailNorm: emailNorm, serverSalt: salt, assertion: nil)
  }

  /// C2 / C2b. `wantPRF` asks the assertion for the PRF output (an unbound
  /// iPhone that will unlock with Face ID).
  public static func withPasskey(_ env: AccountEnvironment, bound: AccountBinding?, wantPRF: Bool)
    async throws(CeremonyError) -> SignInResult
  {
    guard let passkeys = env.passkeys else { throw .passkey(.unsupported) }
    let begin = try await apiStep { () async throws(APIError) in try await env.client.loginBegin() }
    let options: AssertionOptions
    do { options = try begin.options.decoded() } catch { throw .badResponse("login options") }
    let assertion: RawAssertion
    do {
      assertion = try await passkeys.assert(
        challenge: options.challenge, allowCredentialIDs: options.allowCredentialIDs,
        prfSalt: wantPRF ? KeyDerivation.prfSalt : nil)
    } catch {
      throw .passkey(error)
    }
    let device = try binding(env, bound: bound, challenge: options.challenge)
    let grant = try await apiStep { () async throws(APIError) in
      try await env.client.loginFinish(
        LoginFinishRequest(ceremonyID: begin.ceremony_id, credential: assertion.credential, device: device))
    }
    try AccountCreation.writeSession(env, grant)
    return SignInResult(grant: grant, emailNorm: nil, serverSalt: nil, assertion: assertion)
  }

  /// The SessionBind proof for a bound iPhone, or `nil` when unbound.
  static func binding(_ env: AccountEnvironment, bound: AccountBinding?, challenge: Data) throws(CeremonyError)
    -> DeviceBindingJSON?
  {
    guard let bound, let u = bound.userID, let w = bound.writerID else { return nil }
    guard let seed = try secretStep({ () throws(SecretStoreError) in try env.secrets.writerSeed(userID: u, writerID: w) })
    else { return nil }
    defer { seed.wipe() }
    let sig = try cryptoStep("session bind") {
      try DWK.sign(seed: seed, message: try SigningMessage.sessionBind(loginChallenge: challenge, writerID: w))
    }
    return DeviceBindingJSON(writerID: w.string, sigB64: Base64.encode(sig))
  }

  /// §4.7 row 1: `POST /auth/logout` BEFORE the session item goes; offline →
  /// keep it with `pending_logout: true` and treat the app as signed out.
  /// Returns whether the server confirmed (`204` or `401`).
  @discardableResult
  public static func signOut(_ env: AccountEnvironment) async -> Bool {
    guard let s = try? env.secrets.session() else { return true }
    do {
      try await env.client.logout(bearer: s.token)
    } catch {
      if error.failure?.status == 401 {
        try? env.secrets.deleteSession()
        return true
      }
      var pending = s
      pending.pending_logout = true
      try? env.secrets.writeSession(pending)
      return false
    }
    try? env.secrets.deleteSession()
    return true
  }
}

/// The step-up helper (spec 04 §6.3; 01 §10.2; `02` §8.1).
public enum StepUpHelper {
  /// What the proof needs from the user, gathered by the "Confirm it's you"
  /// sheet before this runs.
  public enum Factor: Sendable {
    /// The passkey sheet (the provider prompts).
    case passkey
    /// The current password and the DAK (Face ID or the passcode).
    case device(password: String)
    /// The emailed code and the DAK (`password.reset` only). Call
    /// `beginDeviceCode` first, then `proveDeviceCode` per typed code.
    case deviceCode
  }

  public struct Proof: @unchecked Sendable {  // `prf` is handed to one ceremony, which wipes it
    public let stepUp: StepUpJSON
    /// The PRF output of a passkey proof that asked for it.
    public let prf: SecureBytes?
    public let credentialID: Data?
  }

  /// Runs steps 1–5 for `params` with `factor`, returning the `step_up` object
  /// for the guarded request. `C` is recomputed and compared BEFORE any prompt.
  public static func prove(
    _ env: AccountEnvironment, params: StepUpParams, factor: Factor, binding: AccountBinding?, reason: String
  ) async throws(CeremonyError) -> Proof {
    let kind: StepUpProofKind =
      switch factor {
      case .passkey: .passkey
      case .device: .device
      case .deviceCode: .deviceCode
      }
    guard params.proofKinds.contains(kind) else { throw kind == .passkey ? .noDeviceKey : .needsPasskey }
    let bearer = try AccountCreation.currentBearer(env)
    let paramsHash = StepUp.paramsHash(params)
    let begin = try await apiStep { () async throws(APIError) in
      try await env.client.stepUpBegin(
        StepUpBeginRequest(action: params.action, paramsHashHex: Hex.encode(paramsHash), proofKind: kind.rawValue),
        bearer: bearer)
    }
    guard let nonce = try? Base64.decodeURL(begin.nonce), let challenge = try? Base64.decodeURL(begin.challenge) else {
      throw .badResponse("step-up begin")
    }
    guard StepUp.serverChallengeMatches(challenge, nonce: nonce, params: params) else { throw .challengeMismatch }
    switch factor {
    case .passkey:
      guard let passkeys = env.passkeys else { throw .passkey(.unsupported) }
      let allow = (begin.allow_credentials ?? []).compactMap { try? Base64.decodeURL($0) }
      let a: RawAssertion
      do {
        a = try await passkeys.assert(
          challenge: challenge, allowCredentialIDs: allow, prfSalt: params.usesPRF ? KeyDerivation.prfSalt : nil)
      } catch {
        throw .passkey(error)
      }
      return Proof(
        stepUp: StepUpJSON(nonce: begin.nonce, proof: .passkey(a.credential)), prf: a.prfFirst,
        credentialID: a.credentialID)
    case .device(let password):
      guard let binding, let u = binding.userID, let w = binding.writerID, let salt = binding.serverSalt else {
        throw .noDeviceKey
      }
      let s: SecureBytes
      do { s = try PasswordStretch.stretch(password: password, serverSalt: salt, emailNorm: binding.email_norm) } catch {
        throw .crypto("stretch")
      }
      defer { s.wipe() }
      let sig = try await dakSign(env, challenge: challenge, userID: u, writerID: w, reason: reason)
      return Proof(
        stepUp: StepUpJSON(
          nonce: begin.nonce,
          proof: .device(writerID: w.string, sigB64: Base64.encode(sig), verifierB64: s.withUnsafeBytes { Base64.encode($0) })),
        prf: nil, credentialID: nil)
    case .deviceCode:
      guard let binding, let u = binding.userID, let w = binding.writerID else { throw .noDeviceKey }
      // The DAK signs ONCE; a wrong code re-sends the same signature (≤ 5 tries).
      let sig = try await dakSign(env, challenge: challenge, userID: u, writerID: w, reason: reason)
      return Proof(
        stepUp: StepUpJSON(nonce: begin.nonce, proof: .deviceCode(writerID: w.string, sigB64: Base64.encode(sig), code: "")),
        prf: nil, credentialID: nil)
    }
  }

  /// A `device_code` proof with the typed code, reusing the stored signature.
  public static func withCode(_ proof: Proof, code: String) -> StepUpJSON {
    let p = proof.stepUp.proof
    return StepUpJSON(
      nonce: proof.stepUp.nonce,
      proof: .deviceCode(writerID: p.writer_id ?? "", sigB64: p.sig ?? "", code: code))
  }

  static func dakSign(_ env: AccountEnvironment, challenge: Data, userID: UserID, writerID: WriterID, reason: String)
    async throws(CeremonyError) -> Data
  {
    let message = try cryptoStep("device step-up") { try SigningMessage.deviceStepUp(challenge: challenge, writerID: writerID) }
    do {
      return try await env.approvalKeys.sign(message, userID: userID, writerID: writerID, reason: reason)
    } catch {
      throw error == .missing ? .noDeviceKey : .approvalKey(error)
    }
  }
}

/// §4.7 rows 2–3: everything this iPhone holds for an account. The server
/// side (revocation, deletion) is the caller's, and happens first.
public enum AccountWipe {
  public static func wipe(_ env: AccountEnvironment, userID: UserID, writerID: WriterID?) {
    try? env.secrets.wipeAccount(userID: userID, writerID: writerID)
    if let dir = env.storeDirectory(for: userID) { try? FileManager.default.removeItem(at: dir) }
  }
}
