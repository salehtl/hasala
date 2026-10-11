// The signing messages, byte for byte (spec 01 §10.1, every row), and the
// account-creation challenge (D01).
//
// Every message has fixed-length fields plus at most one variable field, which
// is last or pinned between fixed fields; `writer_id` (40 bytes) and `uuid_str`
// contain no `0x00`. Each builder checks its fixed lengths and returns exactly
// the row's length. Ed25519 messages are signed with `CorePrimitives.Ed25519`
// (randomized in CryptoKit: verify, never compare); the P-256 ones (DAK) by an
// `ApprovalKeySigner`.
import CorePrimitives
import CoreWire
import Foundation

public enum SigningMessageError: Error, Equatable, Sendable {
  case invalidLength(field: String, expected: Int, got: Int)
}

/// `auth_kind` (closed): what authorized the account's creation or recovery.
public enum AuthKind: UInt8, Sendable, CaseIterable {
  case none = 0x00
  case passkey = 0x01
  case password = 0x02
}

public enum SigningMessage {
  static let zero32 = Data(count: 32)

  static func check(_ d: some DataProtocol, _ n: Int, _ field: String) throws(SigningMessageError) -> Data {
    guard d.count == n else { throw .invalidLength(field: field, expected: n, got: d.count) }
    return Data(d)
  }

  static func u64be(_ v: Int64) -> Data {
    let u = UInt64(bitPattern: v)
    return Data((0..<8).map { UInt8(u >> (56 - 8 * UInt64($0)) & 0xff) })
  }

  static func u32be(_ v: UInt32) -> Data {
    Data([UInt8(v >> 24), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)])
  }

  /// D13 RegistrationMessage (201 B), signed by the AAK:
  /// `D13 ‖ 00 ‖ nonce32 ‖ 00 ‖ writer_id ‖ 00 ‖ dwk_pub32 ‖ dak_pub65`.
  public static func registration(nonce: Data, writerID: WriterID, dwkPublicKey: Data, dakPublicKey: Data)
    throws(SigningMessageError) -> Data
  {
    Domain.writerRegistration.prefix + (try check(nonce, 32, "nonce")) + [0] + writerID.bytes + [0]
      + (try check(dwkPublicKey, 32, "dwk_pub")) + (try check(dakPublicKey, 65, "dak_pub"))
  }

  /// D14 RevocationMessage (142 B), signed by a live writer's DWK; pins the
  /// revoked writer's final head (R-02):
  /// `D14 ‖ 00 ‖ nonce32 ‖ 00 ‖ writer_id ‖ 00 ‖ u64be(final_counter) ‖ final_head32`.
  public static func revocation(nonce: Data, writerID: WriterID, finalCounter: Int64, finalHead: Hash32)
    throws(SigningMessageError) -> Data
  {
    guard finalCounter >= 0 else { throw .invalidLength(field: "final_counter", expected: 0, got: -1) }
    return Domain.writerRevocation.prefix + (try check(nonce, 32, "nonce")) + [0] + writerID.bytes + [0]
      + u64be(finalCounter) + finalHead.bytes
  }

  /// D15 SessionBindMessage (96 B), DWK: `D15 ‖ 00 ‖ login_challenge32 ‖ 00 ‖ writer_id`.
  public static func sessionBind(loginChallenge: Data, writerID: WriterID) throws(SigningMessageError) -> Data {
    Domain.sessionBind.prefix + (try check(loginChallenge, 32, "login_challenge")) + [0] + writerID.bytes
  }

  /// D16 DeletionMessage (94 B), DWK: `D16 ‖ 00 ‖ nonce32 ‖ 00 ‖ uuid_str(user_id)`.
  public static func deletion(nonce: Data, userID: UserID) throws(SigningMessageError) -> Data {
    Domain.accountDelete.prefix + (try check(nonce, 32, "nonce")) + [0] + Data(userID.string.utf8)
  }

  /// D17 BootstrapMessage (84 B), AAK: `D17 ‖ 00 ‖ nonce32 ‖ SHA256(BootstrapPayload)`.
  public static func bootstrap(nonce: Data, payload: some DataProtocol) throws(SigningMessageError) -> Data {
    Domain.bootstrap.prefix + (try check(nonce, 32, "nonce")) + sha256(payload)
  }

  /// D18 RecoverySigninMessage (155 B), RK:
  /// `D18 ‖ 00 ‖ nonce32 ‖ u8(auth_kind) ‖ H1 ‖ H2 ‖ H3`.
  public static func recoverySigninPasskey(
    nonce: Data, clientDataJSON: some DataProtocol, attestationObject: some DataProtocol, prfWrap: Data?
  ) throws(SigningMessageError) -> Data {
    Domain.recoverySignin.prefix + (try check(nonce, 32, "nonce")) + [AuthKind.passkey.rawValue]
      + sha256(clientDataJSON) + sha256(attestationObject) + (prfWrap.map { sha256($0) } ?? zero32)
  }

  /// D18 for a new password: `H1 = SHA256(S_new)`, `H2 = H3 = 0^32`.
  public static func recoverySigninPassword(nonce: Data, newVerifier: some ContiguousBytes) throws(SigningMessageError)
    -> Data
  {
    let s = try check(newVerifier.withUnsafeBytes { Data($0) }, 32, "S_new")
    return Domain.recoverySignin.prefix + (try check(nonce, 32, "nonce")) + [AuthKind.password.rawValue] + sha256(s)
      + zero32 + zero32
  }

  /// D19 RecoveryRotateMessage (154 B), AAK:
  /// `D19 ‖ 00 ‖ nonce32 ‖ new_recovery_pub32 ‖ SHA256(new_recovery_wrap) ‖ SHA256(new_phrase_box)`.
  public static func recoveryRotate(
    nonce: Data, newRecoveryPublicKey: Data, newRecoveryWrap: some DataProtocol, newPhraseBox: some DataProtocol
  ) throws(SigningMessageError) -> Data {
    Domain.recoveryRotate.prefix + (try check(nonce, 32, "nonce")) + (try check(newRecoveryPublicKey, 32, "new_recovery_pub"))
      + sha256(newRecoveryWrap) + sha256(newPhraseBox)
  }

  /// D20 EpochRotateMessage (91 B) [P], AAK: `D20 ‖ 00 ‖ nonce32 ‖ u32be(new_epoch) ‖ SHA256(keyring)`.
  public static func epochRotate(nonce: Data, newEpoch: UInt32, keyring: some DataProtocol) throws(SigningMessageError)
    -> Data
  {
    Domain.epochRotate.prefix + (try check(nonce, 32, "nonce")) + u32be(newEpoch) + sha256(keyring)
  }

  /// D32 HeadMessage (119 B), the writer's DWK; one per upload batch, over its
  /// last row: `D32 ‖ 00 ‖ uuid_raw ‖ u64be(counter) ‖ blob_hash32 ‖ 00 ‖ writer_id`.
  public static func head(userID: UserID, counter: Int64, blobHash: Hash32, writerID: WriterID) -> Data {
    Domain.writerHead.prefix + userID.raw + u64be(counter) + blobHash.bytes + [0] + writerID.bytes
  }

  /// D33 PasskeyAddMessage (150 B), the bound writer's DWK:
  /// `D33 ‖ 00 ‖ nonce32 ‖ SHA256(clientDataJSON) ‖ SHA256(attestationObject) ‖ (SHA256(prf_wrap) or 0^32)`.
  public static func passkeyAdd(
    nonce: Data, clientDataJSON: some DataProtocol, attestationObject: some DataProtocol, prfWrap: Data?
  ) throws(SigningMessageError) -> Data {
    Domain.passkeyAdd.prefix + (try check(nonce, 32, "nonce")) + sha256(clientDataJSON) + sha256(attestationObject)
      + (prfWrap.map { sha256($0) } ?? zero32)
  }

  /// D34 WrapPutMessage (115 B), the bound writer's DWK:
  /// `D34 ‖ 00 ‖ nonce32 ‖ SHA256(credential_id) ‖ SHA256(wrap)`.
  public static func wrapPut(nonce: Data, credentialID: some DataProtocol, wrap: some DataProtocol)
    throws(SigningMessageError) -> Data
  {
    Domain.wrapPut.prefix + (try check(nonce, 32, "nonce")) + sha256(credentialID) + sha256(wrap)
  }

  /// D31 DeviceStepUpMessage (98 B), the bound writer's DAK: `D31 ‖ 00 ‖ C32 ‖ 00 ‖ writer_id`.
  public static func deviceStepUp(challenge: Data, writerID: WriterID) throws(SigningMessageError) -> Data {
    Domain.stepUpDevice.prefix + (try check(challenge, 32, "C")) + [0] + writerID.bytes
  }

  /// D38 ResetApproveMessage (145 B), the approving writer's DAK:
  /// `D38 ‖ 00 ‖ nonce32 ‖ uuid_raw ‖ SHA256(ek_pub32) ‖ 00 ‖ writer_id`.
  public static func resetApprove(nonce: Data, userID: UserID, ephemeralPublicKey: Data, writerID: WriterID)
    throws(SigningMessageError) -> Data
  {
    Domain.resetApprove.prefix + (try check(nonce, 32, "nonce")) + userID.raw
      + sha256(try check(ephemeralPublicKey, 32, "ek_pub")) + [0] + writerID.bytes
  }

  /// D39 ResetFinishMessage (87 B), the new iPhone's EK: `D39 ‖ 00 ‖ nonce32 ‖ SHA256(S_new)`.
  public static func resetFinish(nonce: Data, newVerifier: some ContiguousBytes) throws(SigningMessageError) -> Data {
    let s = try check(newVerifier.withUnsafeBytes { Data($0) }, 32, "S_new")
    return Domain.resetFinish.prefix + (try check(nonce, 32, "nonce")) + sha256(s)
  }

  /// D40 EmailChangeMessage (87 B), RK: `D40 ‖ 00 ‖ nonce32 ‖ SHA256(utf8(new_email_norm))`.
  /// `newEmailNorm` must already be `EmailNorm`-normalized.
  public static func emailChange(nonce: Data, newEmailNorm: String) throws(SigningMessageError) -> Data {
    Domain.emailChange.prefix + (try check(nonce, 32, "nonce")) + sha256(Data(newEmailNorm.utf8))
  }

  /// D42 DeviceFreezeMessage (113 B), a live writer's DAK with no session:
  /// `D42 ‖ 00 ‖ nonce32 ‖ uuid_raw ‖ 00 ‖ writer_id`.
  public static func deviceFreeze(nonce: Data, userID: UserID, writerID: WriterID) throws(SigningMessageError) -> Data {
    Domain.deviceFreeze.prefix + (try check(nonce, 32, "nonce")) + userID.raw + [0] + writerID.bytes
  }

  /// D01 `C_reg = SHA256(D01 ‖ 00 ‖ register_nonce32 ‖ authority_pub32)`: the
  /// account-creation WebAuthn challenge, binding the AAK into the UV ceremony.
  /// The client recomputes it and refuses `options` whose challenge differs.
  public static func registerChallenge(nonce: Data, authorityPublicKey: Data) throws(SigningMessageError) -> Data {
    sha256(Domain.register.prefix + (try check(nonce, 32, "nonce")) + (try check(authorityPublicKey, 32, "authority_pub")))
  }
}
