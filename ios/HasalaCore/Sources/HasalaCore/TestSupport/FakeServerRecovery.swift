import CoreAuth
import CoreCrypto
import CorePrimitives
import Foundation

struct FakeRecoveryCeremony {
  let userID: UserID
  let code: String
  var nonce = Data()
  var challenge = Data()
  var verified = false
  var claimed = false
}

private struct RecoverBeginWire: Decodable {
  let recovery_pubkey: String
}

private struct RecoverBegun: Encodable {
  let ceremony_id: String
  let email_hint: String
}

private struct RecoverVerifyWire: Decodable {
  let ceremony_id: String
  let code: String
  let kind: String
}

private struct RecoverVerified: Encodable {
  let nonce: String
  let user_id: String
  let amk_commitment: String
  let authority_pubkey: String
  let recovery_wrap: String
  let current_epoch: Int
  let options: WireCreationOptions
}

private struct RecoverFinishWire: Decodable {
  struct Writer: Decodable {
    let writer_id: String
    let pubkey: String
    let dak_pubkey: String
    let registration_sig: String
  }

  let ceremony_id: String
  let kind: String
  let credential: PublicKeyCredentialJSON
  let prf_wrap: BootstrapPRFWrapJSON?
  let rk_sig: String
  let writer: Writer
}

extension FakeServer {
  func recoverBegin(_ r: APIRequest) -> APIResponse {
    guard let b = Self.decode(r, RecoverBeginWire.self) else { return Self.error(400, "bad_request") }
    let id = token()
    let code = "424242"
    let found = state.withLock { s -> Bool in
      guard let user = s.users.values.first(where: { $0.keys?.recovery_pubkey == b.recovery_pubkey }) else { return false }
      s.recoveryCeremonies[id] = FakeRecoveryCeremony(userID: user.id, code: code)
      s.lastCode = code
      return true
    }
    guard found else { return Self.error(404, "not_found") }
    return Self.ok(RecoverBegun(ceremony_id: id, email_hint: "m\u{2022}\u{2022}\u{2022}@e\u{2022}\u{2022}\u{2022}.com"))
  }

  func recoverVerify(_ r: APIRequest) -> APIResponse {
    guard let b = Self.decode(r, RecoverVerifyWire.self), b.kind == "passkey" else { return Self.error(400, "bad_request") }
    let n = nonce()
    let challenge = nonce()
    let found = state.withLock { s -> (UserID, KeysResponse)? in
      guard let c = s.recoveryCeremonies[b.ceremony_id], !c.claimed, c.code == b.code,
        let keys = s.users[c.userID]?.keys
      else { return nil }
      s.recoveryCeremonies[b.ceremony_id]?.nonce = n
      s.recoveryCeremonies[b.ceremony_id]?.challenge = challenge
      s.recoveryCeremonies[b.ceremony_id]?.verified = true
      return (c.userID, keys)
    }
    guard let (user, keys) = found else { return Self.error(403, "code_rejected") }
    let options = WireCreationOptions(
      CreationOptions(challenge: challenge, rpID: Self.rpID, userID: user.raw, userName: "Hasala"))
    return Self.ok(
      RecoverVerified(
        nonce: Base64.encode(n), user_id: user.string, amk_commitment: keys.amk_commitment,
        authority_pubkey: keys.authority_pubkey, recovery_wrap: keys.recovery_wrap, current_epoch: keys.current_epoch,
        options: options))
  }

  func recoverFinish(_ r: APIRequest) -> APIResponse {
    let refused = Self.error(403, "recovery_refused")
    guard let b = Self.decode(r, RecoverFinishWire.self), b.kind == "passkey" else { return Self.error(400, "bad_request") }
    let claimed = state.withLock { s -> FakeRecoveryCeremony? in
      guard let c = s.recoveryCeremonies[b.ceremony_id], c.verified, !c.claimed else { return nil }
      s.recoveryCeremonies[b.ceremony_id]?.claimed = true
      return c
    }
    guard let c = claimed, var user = state.withLock({ $0.users[c.userID] }), let keys = user.keys,
      let rk = try? Base64.decode(keys.recovery_pubkey), let aak = try? Base64.decode(keys.authority_pubkey),
      let cred = verifyRegistration(b.credential, challenge: c.challenge),
      let cdRaw = try? Base64.decodeURL(b.credential.response.clientDataJSON),
      let attRaw = b.credential.response.attestationObject.flatMap({ try? Base64.decodeURL($0) }),
      let rkSig = try? Base64.decode(b.rk_sig)
    else { return refused }
    var wrap: Data?
    if let p = b.prf_wrap {
      guard let id = try? Base64.decodeURL(p.credential_id), id == cred.id, let w = try? Base64.decode(p.wrap) else {
        return refused
      }
      wrap = w
    }
    guard
      let rkMsg = try? SigningMessage.recoverySigninPasskey(
        nonce: c.nonce, clientDataJSON: cdRaw, attestationObject: attRaw, prfWrap: wrap),
      Ed25519.verify(publicKey: rk, signature: rkSig, message: rkMsg),
      let w = WriterID(b.writer.writer_id), let dwk = try? Base64.decode(b.writer.pubkey),
      let dak = try? Base64.decode(b.writer.dak_pubkey), let regSig = try? Base64.decode(b.writer.registration_sig),
      user.writers[w.string] == nil,
      let regMsg = try? SigningMessage.registration(nonce: c.nonce, writerID: w, dwkPublicKey: dwk, dakPublicKey: dak),
      Ed25519.verify(publicKey: aak, signature: regSig, message: regMsg)
    else { return refused }
    addWriter(&user, id: w, dwk: dwk, dak: dak, nonce: c.nonce, sig: regSig)
    user.wraps = [:]
    if let p = b.prf_wrap { user.wraps[Base64.encodeURL(cred.id)] = .init(credential_id: Base64.encodeURL(cred.id), wrap: p.wrap, wrap_version: 1) }
    let replaced = user
    state.withLock { s in
      s.users[c.userID] = replaced
      s.credentials = s.credentials.filter { $0.value.userID != c.userID }
      s.credentials[cred.id] = Credential(
        id: cred.id, userID: c.userID, publicKey: cred.key, attestationHash: cred.attHash, signCount: 0)
      for (t, sess) in s.sessions where sess.userID == c.userID { s.sessions[t]?.revoked = true }
    }
    return grant(mintSession(c.userID, writer: w), user: replaced, writer: w, status: 201)
  }
}
