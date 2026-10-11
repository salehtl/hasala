// Unlock and enrolment on a new iPhone (spec 04 §6.2 C2, C2-P, C3; spec 01
// §10.4–§10.5; `02` §10.2), and the persistence every enrolment ends with.
//
//   unlock:  GET /keys → the phrase (RK.pub check S-15, recovery wrap) or the
//            PRF wrap of the asserting credential → the commitments → the body
//   enrol:   new writer id, DWK and DAK (no prompt) → #23 challenge → #24
//            register (the AAK signs RegistrationMessage; binds the session)
//   persist: Keychain DWK and K_1, the store (store_meta, sync_state with
//            meta.log_generation), the roster verified under AAK.pub and pinned,
//            then the binding item last (boot reads it as "enrolled")
import CoreAuth
import CoreCrypto
import CorePrimitives
import CoreStore
import CoreWire
import Foundation

/// A new writer's keys (spec 01 §4.8–§4.9): the writer id is minted once per
/// enrolment, the DWK seed stays in memory until it is in the Keychain, and
/// the DAK is created in the Secure Enclave with no prompt.
public struct NewDevice: @unchecked Sendable {
  public let writerID: WriterID
  public let dwkSeed: SecureBytes
  public let dwkPublic: Data
  public let dakPublic: Data

  public static func mint(_ env: AccountEnvironment, userID: UserID) async throws(CeremonyError) -> NewDevice {
    let w: WriterID
    do { w = try WriterID.mint(random: env.random) } catch { throw .crypto("writer id") }
    let (seed, pub) = DWK.generate()
    let dak: Data
    do { dak = try await env.approvalKeys.create(userID: userID, writerID: w) } catch { throw .approvalKey(error) }
    guard DAK.isValidPublicKey(dak) else { throw .approvalKey(.unavailable) }
    return NewDevice(writerID: w, dwkSeed: seed, dwkPublic: pub, dakPublic: dak)
  }
}

public enum Enrolment {
  /// `GET /keys` as the published values the unlock checks against.
  static func published(_ env: AccountEnvironment, userID: UserID, bearer: String) async throws(CeremonyError)
    -> (PublishedAccountKeys, recoveryWrap: Data, epoch: UInt32)
  {
    let k = try await apiStep { () async throws(APIError) in try await env.client.keys(bearer: bearer) }
    let p = PublishedAccountKeys(
      userID: userID, recoveryPublicKey: try b64(k.recovery_pubkey, "recovery_pubkey"),
      amkCommitment: try b64(k.amk_commitment, "amk_commitment"),
      authorityPublicKey: try b64(k.authority_pubkey, "authority_pubkey"))
    guard k.current_epoch >= 1 else { throw .badResponse("current_epoch") }
    return (p, try b64(k.recovery_wrap, "recovery_wrap"), UInt32(k.current_epoch))
  }

  /// C3: the twelve words open the recovery wrap.
  public static func unlockWithPhrase(_ env: AccountEnvironment, userID: UserID, typed: String)
    async throws(CeremonyError) -> KeyBody
  {
    let entropy: SecureBytes
    do { entropy = try Phrase.entropy(typed: typed) } catch { throw .badPhrase }
    defer { entropy.wipe() }
    let bearer = try AccountCreation.currentBearer(env)
    let (p, wrap, _) = try await published(env, userID: userID, bearer: bearer)
    do {
      return try AccountUnlock.withPhrase(entropy: entropy, recoveryWrap: wrap, published: p)
    } catch {
      switch error {
      case .notThisAccountsPhrase: throw .notThisAccountsPhrase
      case .accountKeysMismatch, .phraseBoxMismatch: throw .integrityAlarm("commitments")
      default: throw .notThisAccountsPhrase
      }
    }
  }

  /// C2: the PRF output of the asserting credential opens its wrap. No wrap,
  /// or no PRF output → `.noPRF` (the UI falls back to the phrase).
  public static func unlockWithPRF(
    _ env: AccountEnvironment, userID: UserID, credentialID: Data, prf: SecureBytes?
  ) async throws(CeremonyError) -> KeyBody {
    guard let prf else { throw .noPRF }
    let bearer = try AccountCreation.currentBearer(env)
    let (p, _, _) = try await published(env, userID: userID, bearer: bearer)
    let wraps = try await apiStep { () async throws(APIError) in try await env.client.keyWraps(bearer: bearer) }
    let id = Base64.encodeURL(credentialID)
    guard let w = wraps.wraps.first(where: { $0.credential_id == id }) else { throw .noPRF }
    do {
      return try AccountUnlock.withPRF(
        prfOutput: prf, credentialID: credentialID, prfWrap: try b64(w.wrap, "wrap"), published: p)
    } catch let e as CeremonyError {
      throw e
    } catch {
      // A PRF wrap that fails to open is never deleted (W14); fall back.
      if case .accountKeysMismatch = error as? UnwrapError { throw .integrityAlarm("commitments") }
      throw .noPRF
    }
  }

  /// C2/C3 tail: enrol this iPhone as a new writer with the unlocked body.
  /// `emailNorm` and `serverSalt` come from the sign-in that made the session;
  /// when unknown (a passkey sign-in) they are read from `GET /account`.
  public static func enrolWriter(
    _ env: AccountEnvironment, userID: UserID, body: KeyBody, emailNorm: String?, serverSalt: Data?,
    displayName: String? = nil
  ) async throws(CeremonyError) -> EnrolledAccount {
    let bearer = try AccountCreation.currentBearer(env)
    var email = emailNorm
    var salt = serverSalt
    var name = displayName
    if email == nil || salt == nil || name == nil {
      let a = try await apiStep { () async throws(APIError) in try await env.client.account(bearer: bearer) }
      if email == nil { email = a.email.flatMap { try? EmailNorm.normalize($0) } }
      if salt == nil { salt = a.password_salt.flatMap { try? Base64.decode($0) } }
      if name == nil { name = a.display_name }
    }
    guard let email, let salt else { throw .badResponse("account email or salt") }
    let device = try await NewDevice.mint(env, userID: userID)
    let challenge = try await apiStep { () async throws(APIError) in try await env.client.writerChallenge(bearer: bearer) }
    let nonce = try b64(challenge.nonce, "writer nonce")
    let sig = try cryptoStep("registration") {
      try body.signWithAuthority(
        try SigningMessage.registration(
          nonce: nonce, writerID: device.writerID, dwkPublicKey: device.dwkPublic, dakPublicKey: device.dakPublic))
    }
    let r = try await apiStep { () async throws(APIError) in
      try await env.client.writerRegister(
        WriterRegisterRequest(
          writerID: device.writerID.string, pubkeyB64: Base64.encode(device.dwkPublic),
          dakPubkeyB64: Base64.encode(device.dakPublic), nonceB64: Base64.encode(nonce), sigB64: Base64.encode(sig)),
        bearer: bearer)
    }
    guard r.writer_id == device.writerID.string else { throw .badResponse("register writer_id") }
    let k1 = try cryptoStep("K_1") { try body.epochKey1(userID: userID) }
    defer { k1.wipe() }
    let aak = try cryptoStep("aak") { try body.authorityPublicKey() }
    return try await persist(
      env, userID: userID, device: device, epochKey: k1, emailNorm: email, serverSalt: salt, displayName: name,
      authorityPublicKey: aak)
  }

  /// The end of every enrolment (C1, C1-P, C2, C2-P, C3).
  static func persist(
    _ env: AccountEnvironment, userID: UserID, device: NewDevice, epochKey: SecureBytes, emailNorm: String,
    serverSalt: Data, displayName: String?, authorityPublicKey: Data
  ) async throws(CeremonyError) -> EnrolledAccount {
    try secretStep { () throws(SecretStoreError) in
      try env.secrets.writeWriterSeed(device.dwkSeed, userID: userID, writerID: device.writerID)
      try env.secrets.writeEpochKey(epochKey, userID: userID, epoch: 1)
    }
    device.dwkSeed.wipe()
    let bearer = try AccountCreation.currentBearer(env)
    let meta = try? await env.client.meta()
    var store = try env.openStore(for: userID)
    // A store left by an earlier writer of this account (re-enrolment after
    // `unenrolled`) carries that writer's authored head and pending ops; the
    // new writer starts its own chain, so the old store is removed (it is
    // rebuilt from the server; the old writer's unsent ops cannot be sent).
    if let old = try? store.meta(), old.writerID != device.writerID || old.userID != userID,
      let dir = env.storeDirectory(for: userID)
    {
      try? FileManager.default.removeItem(at: dir)
      store = try env.openStore(for: userID)
    }
    do {
      if try store.meta() == nil {
        try store.create(
          StoreMeta(
            userID: userID, writerID: device.writerID, apiBase: env.apiBase, keyEpoch: 1, createdAt: env.clock.nowMs()),
          epochHWM: 1, logGeneration: meta?.log_generation.flatMap { $0 >= 1 ? $0 : nil })
      }
    } catch {
      throw .store(error)
    }
    let roster: PinnedRoster
    do {
      roster = try await RosterService.fetch(client: env.client, bearer: bearer, authorityPublicKey: authorityPublicKey)
    } catch {
      if case .halted = error { throw .integrityAlarm("key history") }
      throw .api(.transport(.offline(.unknown)))
    }
    guard roster.writers[device.writerID.string] != nil else { throw .integrityAlarm("own writer not in key history") }
    do { try store.setRoster(roster.encoded()) } catch { throw .store(error) }
    let binding = AccountBinding(
      userID: userID, writerID: device.writerID, apiBase: env.apiBase, keyEpoch: 1, emailNorm: emailNorm,
      serverSalt: serverSalt, displayName: displayName)
    try secretStep { () throws(SecretStoreError) in try env.secrets.writeBinding(binding) }
    return EnrolledAccount(userID: userID, writerID: device.writerID, store: store, binding: binding)
  }

  /// Opens an enrolled account's sync context from its binding.
  public static func context(_ env: AccountEnvironment, binding: AccountBinding) throws(CeremonyError) -> SyncContext {
    guard let u = binding.userID, let w = binding.writerID else { throw .badResponse("binding ids") }
    let store = try env.openStore(for: u)
    return SyncContext(
      userID: u, writerID: w, store: store, secrets: env.secrets, client: env.client, clock: env.clock,
      random: env.random)
  }

  public static func context(_ env: AccountEnvironment, account: EnrolledAccount) -> SyncContext {
    SyncContext(
      userID: account.userID, writerID: account.writerID, store: account.store, secrets: env.secrets,
      client: env.client, clock: env.clock, random: env.random)
  }
}
