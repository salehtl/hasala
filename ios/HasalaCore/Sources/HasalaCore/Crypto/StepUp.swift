// Step-up bytes (spec 01 §10.2, A-10 with `02` §8.3's domain-separated params):
//
//   enc(T)      = for each field f of T, in order: u32be(|f|) ‖ f      (empty tuple → zero bytes)
//   params_hash = SHA256("hasala/v1/step-up-params" ‖ 0x00 ‖ action ‖ 0x00 ‖ enc(T))
//   C           = SHA256("hasala/v1/step-up" ‖ 0x00 ‖ nonce32 ‖ action ‖ 0x00 ‖ params_hash)
//
// The client computes `params_hash` and `C` itself and refuses a `challenge`
// from `step-up/begin` that differs (AT-C9), for every proof kind: the DAK signs
// only a `C` the client computed for the action the user chose. Params bind the
// TARGET or the signing key, never content the same assertion's PRF output is
// needed to produce.
import CorePrimitives
import CoreWire
import Foundation

/// How a step-up is proved (§10.2).
public enum StepUpProofKind: String, Sendable, CaseIterable {
  /// A UV WebAuthn assertion over `C`.
  case passkey
  /// The DAK over DeviceStepUpMessage plus the current password's `S`.
  case device
  /// The DAK plus the emailed code; `password.reset` only.
  case deviceCode = "device_code"
}

/// The closed set of 20 actions, each with its tuple `T` (§10.2 table).
public enum StepUpParams: Sendable {
  case passkeyAdd
  case passkeyDelete(credentialID: Data)
  case keysBootstrap(authorityPublicKey: Data)
  case keysWrapPut(credentialID: Data)
  case keysWrapDelete(credentialID: Data)
  case keysRecoveryRotate(newRecoveryPublicKey: Data)
  /// [P]
  case keysEpochRotate(newEpoch: UInt32)
  case writerRevoke(WriterID)
  /// `T = (SHA256(id_token ASCII))`.
  case mailboxLink(idToken: String)
  case mailboxUnlink
  case sessionLogoutAll
  case accountDelete(UserID)
  /// `T = (SHA256(S_new))` for the four password actions that set one.
  case passwordSet(newVerifierHash: Data)
  case passwordChange(newVerifierHash: Data)
  case passwordRemove
  case passwordReset(newVerifierHash: Data)
  /// `T = (SHA256(utf8(new_email_norm)), SHA256(S_new) or the empty field)`.
  case emailChange(newEmailNorm: String, newVerifierHash: Data?)
  case phraseView
  case accountFreeze
  case accountUnfreeze

  public var action: String {
    switch self {
    case .passkeyAdd: "passkey.add"
    case .passkeyDelete: "passkey.delete"
    case .keysBootstrap: "keys.bootstrap"
    case .keysWrapPut: "keys.wrap.put"
    case .keysWrapDelete: "keys.wrap.delete"
    case .keysRecoveryRotate: "keys.recovery.rotate"
    case .keysEpochRotate: "keys.epoch.rotate"
    case .writerRevoke: "writer.revoke"
    case .mailboxLink: "mailbox.link"
    case .mailboxUnlink: "mailbox.unlink"
    case .sessionLogoutAll: "session.logout_all"
    case .accountDelete: "account.delete"
    case .passwordSet: "password.set"
    case .passwordChange: "password.change"
    case .passwordRemove: "password.remove"
    case .passwordReset: "password.reset"
    case .emailChange: "email.change"
    case .phraseView: "phrase.view"
    case .accountFreeze: "account.freeze"
    case .accountUnfreeze: "account.unfreeze"
    }
  }

  /// The tuple `T`, field by field.
  public var tuple: [Data] {
    switch self {
    case .passkeyAdd, .mailboxUnlink, .sessionLogoutAll, .passwordRemove, .phraseView, .accountFreeze,
      .accountUnfreeze:
      []
    case .passkeyDelete(let id), .keysWrapPut(let id), .keysWrapDelete(let id): [id]
    case .keysBootstrap(let k), .keysRecoveryRotate(let k): [k]
    case .keysEpochRotate(let e): [SigningMessage.u32be(e)]
    case .writerRevoke(let w): [w.bytes]
    case .mailboxLink(let token): [sha256(Data(token.utf8))]
    case .accountDelete(let u): [Data(u.string.utf8)]
    case .passwordSet(let h), .passwordChange(let h), .passwordReset(let h): [h]
    case .emailChange(let address, let h): [sha256(Data(address.utf8)), h ?? Data()]
    }
  }

  /// The fixed-length tuple fields hold their lengths: the AAK and recovery
  /// public keys and every `SHA256(S_new)` are 32 bytes. ``StepUp/challenge(nonce:params:)``
  /// checks this first, so a wrong length is a caller bug reported as such, not
  /// a step-up the server refuses later.
  public func validate() throws(SigningMessageError) {
    switch self {
    case .keysBootstrap(let k): _ = try SigningMessage.check(k, 32, "authority_pubkey")
    case .keysRecoveryRotate(let k): _ = try SigningMessage.check(k, 32, "new_recovery_pubkey")
    case .passwordSet(let h), .passwordChange(let h), .passwordReset(let h):
      _ = try SigningMessage.check(h, 32, "SHA256(S_new)")
    case .emailChange(_, let h?): _ = try SigningMessage.check(h, 32, "SHA256(S_new)")
    default: break
    }
  }

  /// The proof kinds the action accepts (the table's last column is binding).
  public var proofKinds: [StepUpProofKind] {
    switch self {
    case .keysBootstrap, .keysWrapPut, .passwordSet, .passwordRemove, .phraseView: [.passkey]
    case .passwordReset: [.deviceCode]
    default: [.passkey, .device]
    }
  }

  /// Whether the same passkey assertion carries the PRF input (§10.2 table).
  public var usesPRF: Bool {
    switch self {
    case .passkeyAdd, .keysWrapPut, .keysRecoveryRotate, .keysEpochRotate, .phraseView: true
    case .keysBootstrap: true  // optional: the asserting credential's PRF wrap may join the payload
    default: false
    }
  }

  /// `SHA256(S)`: how a verifier enters a tuple, `auth_hash` or D18's `H1`.
  public static func verifierHash(_ s: some ContiguousBytes) -> Data { s.withUnsafeBytes { sha256($0) } }

  /// Every action string, in the table's order.
  public static let actions = [
    "passkey.add", "passkey.delete", "keys.bootstrap", "keys.wrap.put", "keys.wrap.delete", "keys.recovery.rotate",
    "keys.epoch.rotate", "writer.revoke", "mailbox.link", "mailbox.unlink", "session.logout_all", "account.delete",
    "password.set", "password.change", "password.remove", "password.reset", "email.change", "phrase.view",
    "account.freeze", "account.unfreeze",
  ]
}

public enum StepUp {
  /// `enc(T)`: each field length-prefixed with a u32be.
  public static func encode(_ tuple: [Data]) -> Data {
    var out = Data()
    for f in tuple {
      out.append(SigningMessage.u32be(UInt32(f.count)))
      out.append(f)
    }
    return out
  }

  /// `params_hash` for an action string and its tuple.
  public static func paramsHash(action: String, tuple: [Data]) -> Data {
    sha256(Domain.stepUpParams.prefix + Data(action.utf8) + [0] + encode(tuple))
  }

  public static func paramsHash(_ p: StepUpParams) -> Data { paramsHash(action: p.action, tuple: p.tuple) }

  /// `C`, the 32 bytes a passkey asserts or the DAK signs (inside D31).
  public static func challenge(nonce: Data, action: String, paramsHash: Data) throws(SigningMessageError) -> Data {
    sha256(
      Domain.stepUp.prefix + (try SigningMessage.check(nonce, 32, "nonce")) + Data(action.utf8) + [0]
        + (try SigningMessage.check(paramsHash, 32, "params_hash")))
  }

  public static func challenge(nonce: Data, params: StepUpParams) throws(SigningMessageError) -> Data {
    try params.validate()
    return try challenge(nonce: nonce, action: params.action, paramsHash: paramsHash(params))
  }

  /// AT-C9: whether the server's `challenge` is exactly the one this client
  /// computes for `params` (constant time).
  public static func serverChallengeMatches(_ serverChallenge: Data, nonce: Data, params: StepUpParams) -> Bool {
    guard let mine = try? challenge(nonce: nonce, params: params) else { return false }
    return constantTimeEquals(mine, serverChallenge)
  }
}
