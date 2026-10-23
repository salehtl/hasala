// FakeServer: signup, creation, sign-in, step-up, bootstrap and writers
// (`02` §7 #3–#6, #9, #16, #18, #23–#24, #43–#47; §8; §9.4; §10.1–§10.2;
// §10.7–§10.8).
import CoreAuth
import CoreCrypto
import CorePrimitives
import CoreWire
import CryptoKit
import Foundation

extension FakeServer {
  // MARK: Signup (#43, #44)

  func signupBegin(_ r: APIRequest) -> APIResponse {
    guard let b = Self.decode(r, SignupBeginRequest.self) else { return Self.error(400, "bad_request") }
    guard let email = try? EmailNorm.normalize(b.email) else { return Self.error(400, "bad_email") }
    guard case .success(let name) = DisplayName.validate(b.display_name) else {
      return Self.error(400, "bad_name", "display_name: characters")
    }
    let addressed: String?? = state.withLock { $0.invites[b.invite_code] }
    guard let addressed else { return Self.error(403, "not_invited") }
    if let a = addressed, a != email { return Self.error(403, "not_invited") }
    let proven = b.invite_link_key != nil && addressed != nil
    let id = token()
    let codeBytes = [UInt8]((try? random.bytes(3)) ?? Data(count: 3))
    var codeValue = 0
    for b in codeBytes { codeValue = codeValue << 8 | Int(b) }
    let code = String(format: "%06d", codeValue % 1_000_000)
    let user = UserID(raw: Data((try? random.bytes(16)) ?? Data(count: 16)))!
    let n = nonce()
    state.withLock { s in
      s.signups[id] = SignupCeremony(
        id: id, userID: user, emailNorm: email, displayName: name, proven: proven, verified: proven, code: code, nonce: n)
      s.lastCode = proven ? nil : code
    }
    struct Out: Encodable {
      let signup_id: String
      let user_id: String
      let email_proven: Bool
      let salt: String
      let nonce: String
      let expires_at: String
    }
    return Self.ok(
      Out(
        signup_id: id, user_id: user.string, email_proven: proven, salt: Base64.encode(sSrv(email)),
        nonce: Base64.encode(n), expires_at: "2026-10-11T00:30:00Z"))
  }

  func signupVerify(_ r: APIRequest) -> APIResponse {
    guard let b = Self.decode(r, SignupVerifyRequest.self) else { return Self.error(400, "bad_request") }
    let ok = state.withLock { s -> Bool in
      guard let c = s.signups[b.signup_id], !c.claimed, c.code == b.code else { return false }
      s.signups[b.signup_id]?.verified = true
      return true
    }
    return ok ? APIResponse(status: 204) : Self.error(403, "code_rejected")
  }

  /// A verified (or proven), unclaimed signup whose address has no account.
  func claimable(_ id: String) -> Result<SignupCeremony, APIResponse> {
    state.withLock { s in
      guard let c = s.signups[id], c.verified, !c.claimed else { return .failure(Self.error(403, "code_rejected")) }
      if s.users.values.contains(where: { $0.emailNorm == c.emailNorm }) {
        return .failure(c.proven ? Self.error(409, "email_in_use") : Self.error(403, "code_rejected"))
      }
      return .success(c)
    }
  }

  // MARK: Creation with a passkey (#3, #4)

  func registerBegin(_ r: APIRequest) -> APIResponse {
    guard let b = Self.decode(r, RegisterBeginRequest.self), let aak = try? Base64.decode(b.authority_pubkey),
      aak.count == 32
    else { return Self.error(400, "bad_request") }
    guard case .success(let c) = claimable(b.signup_id) else {
      if case .failure(let e) = claimable(b.signup_id) { return e }
      return Self.error(403, "code_rejected")
    }
    let n = nonce()
    let challenge = (try? SigningMessage.registerChallenge(nonce: n, authorityPublicKey: aak)) ?? Data()
    let id = token()
    state.withLock { $0.registerCeremonies[id] = (c.id, aak, challenge) }
    let options = WireCreationOptions(
      CreationOptions(challenge: challenge, rpID: Self.rpID, userID: nonce(), userName: "Hasala"))
    return Self.ok(RegisterBeginResponse(ceremony_id: id, nonce: Base64.encode(n), options: options))
  }

  func registerFinish(_ r: APIRequest) -> APIResponse {
    guard let b = Self.decode(r, RegisterFinishRequest.self),
      let cer = state.withLock({ s in s.registerCeremonies.removeValue(forKey: b.ceremony_id) })
    else { return Self.error(403, "passkey_rejected") }
    guard let cred = verifyRegistration(b.credential, challenge: cer.challenge) else {
      return Self.error(403, "passkey_rejected")
    }
    guard case .success(let c) = claimable(cer.signup) else { return Self.error(403, "code_rejected") }
    let user = User(id: c.userID, emailNorm: c.emailNorm, displayName: c.displayName, authorityPending: cer.aak)
    let backup = b.credential.response.attestationObject.flatMap { try? Base64.decodeURL($0) }
      .flatMap(BackupFlags.fromAttestationObject)
    state.withLock { s in
      s.signups[c.id]?.claimed = true
      s.users[c.userID] = user
      s.credentials[cred.id] = Credential(
        id: cred.id, userID: c.userID, publicKey: cred.key, attestationHash: cred.attHash, signCount: 0,
        backupEligible: backup?.eligible == true, backedUp: backup?.backedUp == true)
      s.invites = s.invites.filter { _ in true }
    }
    return grant(mintSession(c.userID, writer: nil), user: user, writer: nil, status: 201)
  }

  // MARK: Creation with a password (#45)

  func passwordRegister(_ r: APIRequest) -> APIResponse {
    guard let b = Self.decode(r, PasswordRegisterRequest.self), let s = try? Base64.decode(b.verifier), s.count == 32
    else { return Self.error(400, "bad_request") }
    let c: SignupCeremony
    switch claimable(b.signup_id) {
    case .success(let x): c = x
    case .failure(let e): return e
    }
    let boot = b.bootstrap
    guard boot.auth_kind == 2, (try? Base64.decode(boot.auth_hash)) == sha256(s) else {
      return Self.error(400, "bad_request", "auth_hash")
    }
    guard (try? Base64.decode(boot.nonce)) == c.nonce else { return Self.error(400, "bad_signature") }
    var user = User(id: c.userID, emailNorm: c.emailNorm, displayName: c.displayName)
    user.passwordHash = sha256(s)
    let applied = applyBootstrap(boot, to: &user, nonce: c.nonce, authKind: .password)
    guard case .success(let writer) = applied else {
      if case .failure(let e) = applied { return e }
      return Self.error(400, "bad_request")
    }
    state.withLock { st in
      st.signups[c.id]?.claimed = true
      st.users[c.userID] = user
    }
    return grant(mintSession(c.userID, writer: writer), user: user, writer: writer, status: 201)
  }

  // MARK: Sign-in (#5, #6, #46, #47)

  func loginBegin() -> APIResponse {
    let challenge = nonce()
    let id = token()
    state.withLock { $0.loginCeremonies[id] = challenge }
    return Self.ok(
      LoginBeginResponse(
        ceremony_id: id, options: WireAssertionOptions(AssertionOptions(challenge: challenge, rpID: Self.rpID, allowCredentialIDs: []))))
  }

  func loginFinish(_ r: APIRequest) -> APIResponse {
    guard let b = Self.decode(r, LoginFinishRequest.self),
      let challenge = state.withLock({ $0.loginCeremonies.removeValue(forKey: b.ceremony_id) })
    else { return Self.error(403, "passkey_rejected") }
    guard let cred = verifyAssertion(b.credential, challenge: challenge, owner: nil) else {
      return Self.error(403, "passkey_rejected")
    }
    return bindAndGrant(user: cred.userID, device: b.device, challenge: challenge)
  }

  func passwordLoginBegin(_ r: APIRequest) -> APIResponse {
    guard let b = Self.decode(r, EmailRequest.self) else { return Self.error(400, "bad_request") }
    guard let email = try? EmailNorm.normalize(b.email) else { return Self.error(400, "bad_email") }
    let id = token()
    let n = nonce()
    state.withLock { $0.passwordCeremonies[id] = (email, n) }
    return Self.ok(PasswordLoginBeginResponse(ceremony_id: id, salt: Base64.encode(sSrv(email)), nonce: Base64.encode(n)))
  }

  func passwordLoginFinish(_ r: APIRequest) -> APIResponse {
    guard let b = Self.decode(r, PasswordLoginFinishRequest.self), let s = try? Base64.decode(b.verifier) else {
      return Self.error(400, "bad_request")
    }
    guard let cer = state.withLock({ $0.passwordCeremonies.removeValue(forKey: b.ceremony_id) }) else {
      return Self.error(403, "password_rejected")
    }
    let user = state.withLock { st in st.users.values.first { $0.emailNorm == cer.email } }
    // §10.8 step 2: the device binding is checked before S.
    if let d = b.device {
      guard let user, let w = user.writers[d.writer_id], let sig = try? Base64.decode(d.sig),
        let msg = try? SigningMessage.sessionBind(loginChallenge: cer.nonce, writerID: w.id),
        Ed25519.verify(publicKey: w.dwk, signature: sig, message: msg)
      else { return Self.error(400, "bad_signature") }
      if w.revoked != nil { return Self.error(403, "writer_revoked") }
    }
    guard let user, let h = user.passwordHash, h == sha256(s) else { return Self.error(403, "password_rejected") }
    let writer = b.device.flatMap { WriterID($0.writer_id) }
    return grant(mintSession(user.id, writer: writer), user: user, writer: writer)
  }

  func bindAndGrant(user id: UserID, device: DeviceBindingJSON?, challenge: Data) -> APIResponse {
    guard let user = state.withLock({ $0.users[id] }) else { return Self.error(403, "passkey_rejected") }
    var writer: WriterID?
    if let d = device {
      guard let w = user.writers[d.writer_id] else { return Self.error(409, "other_account_device") }
      guard let sig = try? Base64.decode(d.sig),
        let msg = try? SigningMessage.sessionBind(loginChallenge: challenge, writerID: w.id),
        Ed25519.verify(publicKey: w.dwk, signature: sig, message: msg)
      else { return Self.error(400, "bad_signature") }
      if w.revoked != nil { return Self.error(403, "writer_revoked") }
      writer = w.id
    }
    return grant(mintSession(id, writer: writer), user: user, writer: writer)
  }

  // MARK: Step-up (#9) and one guarded route (#16)

  func stepUpBegin(_ r: APIRequest, token: String, sess: Session) -> APIResponse {
    guard let b = Self.decode(r, StepUpBeginRequest.self), let ph = try? Hex.decode(b.params_hash), ph.count == 32,
      SigningMessage_actions.contains(b.action)
    else { return Self.error(400, "bad_request") }
    if b.proof_kind != "passkey" {
      guard let w = sess.writerID, let user = state.withLock({ $0.users[sess.userID] }),
        let writer = user.writers[w.string], writer.revoked == nil
      else { return Self.error(403, "writer_unbound") }
    }
    let n = nonce()
    guard let c = try? StepUp.challenge(nonce: n, action: b.action, paramsHash: ph) else {
      return Self.error(400, "bad_request")
    }
    state.withLock {
      $0.stepUps[n] = StepUpChallenge(
        userID: sess.userID, token: token, action: b.action, paramsHash: ph, kind: b.proof_kind)
    }
    let allow = state.withLock { s in s.credentials.values.filter { $0.userID == sess.userID }.map { Base64.encodeURL($0.id) } }
    return Self.ok(
      StepUpBeginResponse(
        nonce: Base64.encodeURL(n), challenge: Base64.encodeURL(c), expires_at: nil,
        rp_id: b.proof_kind == "passkey" ? Self.rpID : nil, allow_credentials: b.proof_kind == "passkey" ? allow : nil))
  }

  /// `02` §8.1 step 5, for the action and tuple the route recomputes.
  func consumeStepUp(_ su: StepUpJSON?, token: String, sess: Session, action: String, tuple: [Data]) -> APIResponse? {
    guard let su else { return Self.error(403, "step_up_required") }
    guard let n = try? Base64.decodeURL(su.nonce) else { return Self.error(403, "step_up_failed") }
    let row: StepUpChallenge? = state.withLock { s in
      guard let c = s.stepUps[n], !c.used else { return nil }
      s.stepUps[n]?.used = true
      return c
    }
    let ph = StepUp.paramsHash(action: action, tuple: tuple)
    guard let row, row.userID == sess.userID, row.token == token, row.action == action, row.paramsHash == ph,
      row.kind == su.proof.kind, let c = try? StepUp.challenge(nonce: n, action: action, paramsHash: ph)
    else { return Self.error(403, "step_up_failed") }
    switch su.proof.kind {
    case "passkey":
      guard let a = su.proof.assertion, verifyAssertion(a, challenge: c, owner: sess.userID) != nil else {
        return Self.error(403, "step_up_failed")
      }
    case "device":
      guard let w = sess.writerID, w.string == su.proof.writer_id, let user = state.withLock({ $0.users[sess.userID] }),
        let writer = user.writers[w.string], writer.revoked == nil, let sig = su.proof.sig.flatMap({ try? Base64.decode($0) }),
        let msg = try? SigningMessage.deviceStepUp(challenge: c, writerID: w),
        DAK.verify(publicKey: writer.dak, signature: sig, message: msg)
      else { return Self.error(403, "step_up_failed") }
      guard let s = su.proof.verifier.flatMap({ try? Base64.decode($0) }), let h = user.passwordHash, h == sha256(s) else {
        return Self.error(403, "step_up_failed")
      }
    default:
      return Self.error(403, "step_up_failed")
    }
    return nil
  }

  func logoutAll(_ r: APIRequest, token: String, sess: Session) -> APIResponse {
    struct Body: Decodable { let step_up: StepUpJSON? }
    guard let b = Self.decode(r, Body.self) else { return Self.error(400, "bad_request") }
    if let refusal = consumeStepUp(b.step_up, token: token, sess: sess, action: "session.logout_all", tuple: []) {
      return refusal
    }
    state.withLock { s in
      for (t, x) in s.sessions where x.userID == sess.userID { s.sessions[t]?.revoked = true }
    }
    return APIResponse(status: 204)
  }

  // MARK: Passkey add (#10, #11)

  func passkeyAddBegin(_ r: APIRequest, token: String, sess: Session) -> APIResponse {
    guard let b = Self.decode(r, PasskeyAddBeginRequest.self), let n = try? Base64.decodeURL(b.step_up.nonce) else {
      return Self.error(400, "bad_request")
    }
    guard let w = sess.writerID, let user = state.withLock({ $0.users[sess.userID] }), user.writers[w.string]?.revoked == nil
    else { return Self.error(403, "writer_unbound") }
    if let refusal = consumeStepUp(b.step_up, token: token, sess: sess, action: "passkey.add", tuple: []) {
      return refusal
    }
    let challenge = nonce()
    let id = self.token()
    let existing = state.withLock { s in
      s.addCeremonies[id] = (sess.userID, challenge, n)
      return s.credentials.values.filter { $0.userID == sess.userID }.map(\.id)
    }
    let options = WireCreationOptions(
      CreationOptions(
        challenge: challenge, rpID: Self.rpID, userID: sess.userID.raw, userName: "Hasala", excludeCredentialIDs: existing))
    return Self.ok(PasskeyAddBeginResponse(ceremony_id: id, options: options))
  }

  func passkeyAddFinish(_ r: APIRequest, sess: Session) -> APIResponse {
    guard let b = Self.decode(r, PasskeyAddFinishRequest.self),
      let cer = state.withLock({ s in s.addCeremonies.removeValue(forKey: b.ceremony_id) }), cer.user == sess.userID
    else { return Self.error(403, "passkey_rejected") }
    guard let cred = verifyRegistration(b.credential, challenge: cer.challenge),
      let cdRaw = try? Base64.decodeURL(b.credential.response.clientDataJSON),
      let attRaw = b.credential.response.attestationObject.flatMap({ try? Base64.decodeURL($0) })
    else { return Self.error(403, "passkey_rejected") }
    var wrap: Data?
    if let p = b.prf_wrap {
      guard let id = try? Base64.decodeURL(p.credential_id), id == cred.id, let w = try? Base64.decode(p.wrap),
        p.wrap_version == 1
      else { return Self.error(400, "bad_request", "prf_wrap") }
      wrap = w
    }
    guard let w = sess.writerID, let user = state.withLock({ $0.users[sess.userID] }), let writer = user.writers[w.string],
      writer.revoked == nil
    else { return Self.error(403, "writer_unbound") }
    guard let sig = try? Base64.decode(b.dwk_sig),
      let msg = try? SigningMessage.passkeyAdd(
        nonce: cer.nonce, clientDataJSON: cdRaw, attestationObject: attRaw, prfWrap: wrap),
      Ed25519.verify(publicKey: writer.dwk, signature: sig, message: msg)
    else { return Self.error(400, "bad_signature") }
    let idB64 = Base64.encodeURL(cred.id)
    state.withLock { s in
      s.credentials[cred.id] = Credential(
        id: cred.id, userID: sess.userID, publicKey: cred.key, attestationHash: cred.attHash, signCount: 0)
      if let p = b.prf_wrap {
        s.users[sess.userID]?.wraps[idB64] = .init(credential_id: idB64, wrap: p.wrap, wrap_version: 1)
      }
    }
    return Self.ok(PasskeyAddResponse(credential_id: idB64), status: 201)
  }

  // MARK: Bootstrap (#18) and writers (#24)

  func bootstrap(_ r: APIRequest, token: String, sess: Session) -> APIResponse {
    guard let b = Self.decode(r, BootstrapBody.self) else { return Self.error(400, "bad_request") }
    guard var user = state.withLock({ $0.users[sess.userID] }) else { return Self.error(401, "unauthorized") }
    if user.keys != nil { return Self.error(409, "keys_exist") }
    guard let aak = try? Base64.decode(b.authority_pubkey) else { return Self.error(400, "bad_request") }
    let kind: AuthKind
    if user.authorityPending == aak {
      let oldest = state.withLock { s in s.credentials.values.first { $0.userID == user.id } }
      guard b.auth_kind == 1, let o = oldest, (try? Base64.decode(b.auth_hash)) == o.attestationHash else {
        return Self.error(400, "bad_request", "auth_hash")
      }
      kind = .passkey
    } else {
      if let refusal = consumeStepUp(b.step_up, token: token, sess: sess, action: "keys.bootstrap", tuple: [aak]) {
        return refusal
      }
      guard b.auth_kind == 0 else { return Self.error(400, "bad_request") }
      kind = .none
    }
    guard let n = try? Base64.decode(b.nonce),
      state.withLock({ $0.writerNonces.removeValue(forKey: n) }) == sess.userID
    else { return Self.error(400, "bad_signature") }
    if b.phrase_unseen == true {
      let synced = state.withLock { s in
        s.credentials.values.contains { $0.userID == user.id && $0.backupEligible && $0.backedUp }
      }
      guard kind == .passkey, b.prf_wrap != nil, synced else { return Self.error(400, "bad_request", "phrase_unseen") }
    }
    switch applyBootstrap(b, to: &user, nonce: n, authKind: kind) {
    case .failure(let e): return e
    case .success(let w):
      user.authorityPending = nil
      if b.phrase_unseen == true { user.phraseUnseenSince = "2026-10-22T08:00:00Z" }
      state.withLock { s in
        s.users[user.id] = user
        s.sessions[token]?.writerID = w
      }
      return Self.ok(BootstrapResponse(writer_id: w.string, current_epoch: 1), status: 201)
    }
  }

  /// §10.1 checks 3 and 6 and the insertions, onto `user`.
  func applyBootstrap(_ b: BootstrapBody, to user: inout User, nonce: Data, authKind: AuthKind) -> Result<
    WriterID, APIResponse
  > {
    func d(_ s: String) -> Data? { try? Base64.decode(s) }
    guard let commit = d(b.amk_commitment), let aak = d(b.authority_pubkey), let rk = d(b.recovery_pubkey),
      let wrap = d(b.recovery_wrap), let box = d(b.phrase_box), let emailHash = d(b.email_hash),
      let authHash = d(b.auth_hash), let w = WriterID(b.writer.writer_id), let dwk = d(b.writer.pubkey),
      let dak = d(b.writer.dak_pubkey), let aSig = d(b.authority_sig), let rSig = d(b.registration_sig)
    else { return .failure(Self.error(400, "bad_request")) }
    guard emailHash == EmailNorm.hash(user.emailNorm) else { return .failure(Self.error(400, "bad_request", "email_hash")) }
    guard DAK.isValidPublicKey(dak) else { return .failure(Self.error(400, "bad_request", "dak")) }
    var prf: (Data, Data)?
    if let p = b.prf_wrap {
      guard let id = try? Base64.decodeURL(p.credential_id), let wr = d(p.wrap) else {
        return .failure(Self.error(400, "bad_request"))
      }
      prf = (id, wr)
    }
    let payload = BootstrapPayload(
      userID: user.id, amkCommitment: commit, authorityPublicKey: aak, recoveryPublicKey: rk, recoveryWrap: wrap,
      phraseBox: box, emailNorm: user.emailNorm, authKind: authKind, authHash: authHash, writerPublicKey: dwk,
      writerDAKPublicKey: dak, writerID: w, prfWrap: prf.map { (credentialID: $0.0, wrap: $0.1) })
    guard let bytes = try? payload.encoded(), let bm = try? SigningMessage.bootstrap(nonce: nonce, payload: bytes),
      Ed25519.verify(publicKey: aak, signature: aSig, message: bm),
      let rm = try? SigningMessage.registration(nonce: nonce, writerID: w, dwkPublicKey: dwk, dakPublicKey: dak),
      Ed25519.verify(publicKey: aak, signature: rSig, message: rm)
    else { return .failure(Self.error(400, "bad_signature")) }
    user.keys = KeysResponse(
      format_version: 1, amk_commitment: b.amk_commitment, authority_pubkey: b.authority_pubkey,
      recovery_pubkey: b.recovery_pubkey, recovery_wrap: b.recovery_wrap, current_epoch: 1)
    user.phraseBox = box
    if let p = b.prf_wrap {
      user.wraps[p.credential_id] = .init(credential_id: p.credential_id, wrap: p.wrap, wrap_version: 1)
    }
    addWriter(&user, id: w, dwk: dwk, dak: dak, nonce: nonce, sig: rSig)
    return .success(w)
  }

  func addWriter(_ user: inout User, id: WriterID, dwk: Data, dak: Data, nonce: Data, sig: Data) {
    let hid = state.withLock { s -> Int64 in
      s.historyID += 1
      return s.historyID
    }
    user.writers[id.string] = Writer(id: id, dwk: dwk, dak: dak, revoked: nil, registeredAt: "2026-10-11T00:00:00Z")
    user.history.append(
      KeyHistoryRow(
        id: hid, writerID: id.string, pubkey: dwk, dak: dak, event: "registered", authorizedBy: "authority",
        authorizer: nil, finalCounter: nil, finalHead: nil, nonce: nonce, signature: sig))
  }

  func writerRegister(_ r: APIRequest, token: String, sess: Session) -> APIResponse {
    guard let b = Self.decode(r, WriterRegisterRequest.self) else { return Self.error(400, "bad_request") }
    guard var user = state.withLock({ $0.users[sess.userID] }) else { return Self.error(401, "unauthorized") }
    guard let keys = user.keys, let aak = try? Base64.decode(keys.authority_pubkey) else {
      return Self.error(403, "keys_required")
    }
    guard let w = WriterID(b.writer_id) else { return Self.error(400, "bad_writer_id") }
    guard let dwk = try? Base64.decode(b.pubkey), dwk.count == 32, user.writers[w.string] == nil,
      let dak = try? Base64.decode(b.dak_pubkey), DAK.isValidPublicKey(dak)
    else { return Self.error(400, "bad_request") }
    guard let n = try? Base64.decode(b.nonce), state.withLock({ $0.writerNonces.removeValue(forKey: n) }) == sess.userID,
      let sig = try? Base64.decode(b.sig),
      let msg = try? SigningMessage.registration(nonce: n, writerID: w, dwkPublicKey: dwk, dakPublicKey: dak),
      Ed25519.verify(publicKey: aak, signature: sig, message: msg)
    else { return Self.error(400, "bad_signature") }
    if sess.writerID != nil { return Self.error(409, "session_bound") }
    addWriter(&user, id: w, dwk: dwk, dak: dak, nonce: n, sig: sig)
    state.withLock { s in
      s.users[user.id] = user
      s.sessions[token]?.writerID = w
    }
    return Self.ok(WriterIDResponse(writer_id: w.string), status: 201)
  }

  // MARK: Device removal (#25, §9.5) and deletion (#41, §15.2)

  func writerRevoke(_ r: APIRequest, token: String, sess: Session) -> APIResponse {
    guard let b = Self.decode(r, WriterRevokeRequest.self), let target = WriterID(b.writer_id),
      let signerID = WriterID(b.signer_writer_id), let n = try? Base64.decode(b.nonce),
      let counter = Int64(b.final_counter), let head = try? Base64.decode(b.final_head), head.count == 32,
      let sig = try? Base64.decode(b.sig)
    else { return Self.error(400, "bad_request") }
    guard state.withLock({ $0.writerNonces.removeValue(forKey: n) }) == sess.userID else {
      return Self.error(400, "bad_signature")
    }
    if let refusal = consumeStepUp(
      b.step_up, token: token, sess: sess, action: "writer.revoke", tuple: [target.bytes])
    {
      return refusal
    }
    guard var user = state.withLock({ $0.users[sess.userID] }), let t = user.writers[target.string], t.revoked == nil,
      let signer = user.writers[signerID.string], signer.revoked == nil
    else { return Self.error(400, "bad_request") }
    let stored = user.log.last { $0.writerID == target.string }
    guard (stored?.counter ?? 0) == counter, (stored?.blobHash ?? Data(count: 32)) == head else {
      return Self.error(409, "head_moved")
    }
    guard let msg = try? SigningMessage.revocation(nonce: n, writerID: target, finalCounter: counter, finalHead: Hash32(head)!),
      Ed25519.verify(publicKey: signer.dwk, signature: sig, message: msg)
    else { return Self.error(400, "bad_signature") }
    user.writers[target.string]?.revoked = (counter, head)
    let hid = state.withLock { s -> Int64 in
      s.historyID += 1
      return s.historyID
    }
    user.history.append(
      KeyHistoryRow(
        id: hid, writerID: target.string, pubkey: t.dwk, dak: nil, event: "revoked", authorizedBy: "device",
        authorizer: signerID.string, finalCounter: counter, finalHead: head, nonce: n, signature: sig))
    state.withLock { s in
      s.users[user.id] = user
      for (k, x) in s.sessions where x.writerID == target { s.sessions[k]?.revoked = true }
    }
    return APIResponse(status: 204)
  }

  func deleteAccount(_ r: APIRequest, token: String, sess: Session) -> APIResponse {
    guard let b = Self.decode(r, DeleteAccountRequest.self), let w = WriterID(b.writer_id),
      let sig = try? Base64.decode(b.sig), let n = try? Base64.decodeURL(b.step_up.nonce)
    else { return Self.error(400, "bad_request") }
    if let refusal = consumeStepUp(
      b.step_up, token: token, sess: sess, action: "account.delete", tuple: [Data(sess.userID.string.utf8)])
    {
      return refusal
    }
    guard let user = state.withLock({ $0.users[sess.userID] }), let writer = user.writers[w.string],
      let msg = try? SigningMessage.deletion(nonce: n, userID: sess.userID),
      Ed25519.verify(publicKey: writer.dwk, signature: sig, message: msg)
    else { return Self.error(400, "bad_signature") }
    state.withLock { $0.users[sess.userID]?.deleted = true }
    return APIResponse(status: 204)
  }

  // MARK: WebAuthn (what go-webauthn's verdict depends on here)

  struct ClientData: Decodable {
    let type: String
    let challenge: String
    let origin: String
  }

  func checkClientData(_ raw: Data, type: String, challenge: Data) -> Bool {
    guard let cd = try? JSONDecoder().decode(ClientData.self, from: raw) else { return false }
    return cd.type == type && (try? Base64.decodeURL(cd.challenge)) == challenge && cd.origin == Self.origin
  }

  func verifyRegistration(_ c: PublicKeyCredentialJSON, challenge: Data) -> (id: Data, key: P256.Signing.PublicKey, attHash: Data)? {
    guard let cdRaw = try? Base64.decodeURL(c.response.clientDataJSON),
      checkClientData(cdRaw, type: "webauthn.create", challenge: challenge),
      let attRaw = c.response.attestationObject.flatMap({ try? Base64.decodeURL($0) })
    else { return nil }
    var off = 0
    guard let att = CBORValue.decode(attRaw, offset: &off), let auth = att[.text("authData")]?.bytes else { return nil }
    let a = [UInt8](auth)
    guard a.count >= 55, Data(a[0..<32]) == Data(SHA256.hash(data: Data(Self.rpID.utf8))) else { return nil }
    let flags = a[32]
    guard flags & 0x01 != 0, flags & 0x04 != 0, flags & 0x40 != 0 else { return nil }
    let idLen = Int(a[53]) << 8 | Int(a[54])
    guard a.count >= 55 + idLen else { return nil }
    let id = Data(a[55..<(55 + idLen)])
    var o = 0
    guard let cose = CBORValue.decode(Data(a[(55 + idLen)...]), offset: &o), let x = cose[.int(-2)]?.bytes,
      let y = cose[.int(-3)]?.bytes, let key = try? P256.Signing.PublicKey(x963Representation: Data([4]) + x + y)
    else { return nil }
    return (id, key, sha256(attRaw))
  }

  /// Verifies an assertion over `challenge` with UV; returns the credential.
  func verifyAssertion(_ c: PublicKeyCredentialJSON, challenge: Data, owner: UserID?) -> Credential? {
    guard let id = try? Base64.decodeURL(c.rawId), var cred = state.withLock({ $0.credentials[id] }),
      owner == nil || cred.userID == owner,
      let cdRaw = try? Base64.decodeURL(c.response.clientDataJSON),
      checkClientData(cdRaw, type: "webauthn.get", challenge: challenge),
      let auth = c.response.authenticatorData.flatMap({ try? Base64.decodeURL($0) }),
      let sigRaw = c.response.signature.flatMap({ try? Base64.decodeURL($0) }),
      let sig = try? P256.Signing.ECDSASignature(derRepresentation: sigRaw)
    else { return nil }
    let a = [UInt8](auth)
    guard a.count >= 37, Data(a[0..<32]) == Data(SHA256.hash(data: Data(Self.rpID.utf8))), a[32] & 0x05 == 0x05 else {
      return nil
    }
    guard cred.publicKey.isValidSignature(sig, for: auth + Data(SHA256.hash(data: cdRaw))) else { return nil }
    let count = UInt32(a[33]) << 24 | UInt32(a[34]) << 16 | UInt32(a[35]) << 8 | UInt32(a[36])
    guard count == 0 || count > cred.signCount else { return nil }  // clone refused
    cred.signCount = count
    state.withLock { $0.credentials[id] = cred }
    return cred
  }
}

let SigningMessage_actions = Set(StepUpParams.actions)

/// A refusal carried through `Result` inside the fake.
extension APIResponse: Error {}
