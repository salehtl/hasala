import CoreAuth
import CorePrimitives
import CoreStore
import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// The device approval key (spec 04 §6.1.3; 01 §4.9): a Secure Enclave P-256 key per
/// writer, usable only while the iPhone has a passcode, and only after Face ID or the
/// passcode. Its SE-wrapped handle (not the key) lives in `SecretItem.approvalKey`.
///
/// The simulator has no Secure Enclave, so this reports `.unavailable` there; Debug
/// scenarios never reach it (they run on the account mock).
nonisolated final class SecureEnclaveApprovalKey: ApprovalKeySigner, @unchecked Sendable {
  private let store: any SecretStore

  init(store: any SecretStore) {
    self.store = store
  }

  func create(userID: UserID, writerID: WriterID) async throws(ApprovalKeyError) -> Data {
    guard SecureEnclave.isAvailable else { throw .unavailable }
    var error: Unmanaged<CFError>?
    guard
      let access = SecAccessControlCreateWithFlags(
        nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, [.privateKeyUsage, .userPresence], &error)
    else { throw .unavailable }
    let key: SecureEnclave.P256.Signing.PrivateKey
    do {
      key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
    } catch {
      throw .unavailable
    }
    do {
      try store.write(.approvalKey(userID: userID, writerID: writerID), key.dataRepresentation)
    } catch .notNow(_) {
      throw .notNow
    } catch {
      throw .unavailable
    }
    return key.publicKey.x963Representation
  }

  func publicKeyX963(userID: UserID, writerID: WriterID) throws(ApprovalKeyError) -> Data {
    try handle(userID: userID, writerID: writerID, context: nil).publicKey.x963Representation
  }

  func sign(_ message: Data, userID: UserID, writerID: WriterID, reason: String) async throws(ApprovalKeyError) -> Data {
    let context = LAContext()
    context.localizedReason = reason
    let key = try handle(userID: userID, writerID: writerID, context: context)
    do {
      return try key.signature(for: message).rawRepresentation
    } catch {
      if let la = error as? LAError, la.code == .userCancel || la.code == .appCancel || la.code == .systemCancel {
        throw .cancelled
      }
      throw .unavailable
    }
  }

  private func handle(userID: UserID, writerID: WriterID, context: LAContext?) throws(ApprovalKeyError)
    -> SecureEnclave.P256.Signing.PrivateKey
  {
    let data: Data?
    do {
      data = try store.read(.approvalKey(userID: userID, writerID: writerID))
    } catch {
      throw .notNow
    }
    guard let data else { throw .missing }
    do {
      return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data, authenticationContext: context)
    } catch {
      throw .missing
    }
  }
}
