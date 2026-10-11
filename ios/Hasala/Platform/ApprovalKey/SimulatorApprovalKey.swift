#if DEBUG && targetEnvironment(simulator)
  import CoreAuth
  import CorePrimitives
  import CryptoKit
  import Foundation

  /// The device approval key for Debug simulator runs only (the simulator has no Secure
  /// Enclave). A software P-256 key with the Secure Enclave key's formats: a 65-byte X9.63
  /// public key and 64-byte raw signatures, so the server cannot tell them apart.
  ///
  /// The key lives in the app's UserDefaults domain, readable after first unlock: the
  /// Keychain's approval-key class needs a device passcode, which a simulator lacks. It
  /// signs without a prompt. Never compiled into a device or Release build.
  nonisolated final class SimulatorApprovalKey: ApprovalKeySigner, @unchecked Sendable {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
      self.defaults = defaults
    }

    private static func key(_ userID: UserID, _ writerID: WriterID) -> String {
      "debug.simulatorApprovalKey.\(userID.string):\(writerID.string)"
    }

    func create(userID: UserID, writerID: WriterID) async throws(ApprovalKeyError) -> Data {
      let key = P256.Signing.PrivateKey()
      defaults.set(key.rawRepresentation, forKey: Self.key(userID, writerID))
      return key.publicKey.x963Representation
    }

    func publicKeyX963(userID: UserID, writerID: WriterID) throws(ApprovalKeyError) -> Data {
      try handle(userID, writerID).publicKey.x963Representation
    }

    func sign(_ message: Data, userID: UserID, writerID: WriterID, reason: String) async throws(ApprovalKeyError)
      -> Data
    {
      do {
        return try handle(userID, writerID).signature(for: message).rawRepresentation
      } catch {
        throw .unavailable
      }
    }

    private func handle(_ userID: UserID, _ writerID: WriterID) throws(ApprovalKeyError) -> P256.Signing.PrivateKey {
      guard let raw = defaults.data(forKey: Self.key(userID, writerID)),
        let key = try? P256.Signing.PrivateKey(rawRepresentation: raw)
      else { throw .missing }
      return key
    }
  }
#endif
