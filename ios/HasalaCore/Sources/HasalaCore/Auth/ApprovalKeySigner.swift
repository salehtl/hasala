// The device approval key seam (spec 04 §2.7; spec 01 §4.9).
//
// Implemented by the app's Secure Enclave key (`Platform/ApprovalKey`:
// `SecureEnclave.P256.Signing.PrivateKey` under
// `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly` with `.privateKeyUsage` and
// `.userPresence`, its SE-wrapped handle in `SecretItem.approvalKey`) and, in
// tests and `HASALA_MOCKS` Debug builds only, by `CoreSoftAuth`'s software
// signer, which has identical byte formats. Release builds never inject the
// software one.
//
// Closed uses: DeviceStepUpMessage (D31), ResetApproveMessage (D38) and
// DeviceFreezeMessage (D42), built by `CoreCrypto.SigningMessage` and checked by
// `CoreCrypto.DAK.verify`.
import CorePrimitives
import Foundation

public protocol ApprovalKeySigner: Sendable {
  /// Creates the DAK for a new writer (no prompt) and returns its 65-byte X9.63
  /// public key. The SE-wrapped handle is written to `SecretItem.approvalKey`
  /// before this returns.
  func create(userID: UserID, writerID: WriterID) async throws(ApprovalKeyError) -> Data
  /// 65 bytes, `0x04 ‖ X ‖ Y`.
  func publicKeyX963(userID: UserID, writerID: WriterID) throws(ApprovalKeyError) -> Data
  /// Prompts Face ID or the passcode with `reason`; returns raw `r ‖ s` (64
  /// bytes) over `message` (ECDSA P-256 over SHA-256, spec 01 §1).
  func sign(_ message: Data, userID: UserID, writerID: WriterID, reason: String) async throws(ApprovalKeyError) -> Data
}

public enum ApprovalKeyError: Error, Sendable, Equatable {
  /// No Secure Enclave or no passcode (S-24).
  case unavailable
  /// The handle is absent, or iOS deleted the key when the passcode was removed.
  case missing
  /// The user cancelled.
  case cancelled
  /// The Keychain is unreadable before first unlock.
  case notNow
}
