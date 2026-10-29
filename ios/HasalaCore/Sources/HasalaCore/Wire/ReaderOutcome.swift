// The reader's outcomes (spec 01 §6.6, R0-R10), shared by CoreWire's row checks,
// CoreCrypto's `Opener` and the sync engine. The first failing step decides.
import Foundation

/// Why a page was judged tampered (`hardStop(.tampered(…))`, halt `tampered`).
public enum TamperReason: String, Sendable, Hashable, CaseIterable {
  case rowShape  // R0
  case unknownWriter  // R1
  case chainBreak  // R2
  case headUnsigned, headInvalid, afterRevocation  // R2b
  case legacyFrame  // R3
  case badHeader, epochInvalid  // R4
  case aadMismatch  // R5
  case ownChainConflict  // rows of the device's own writer it did not author
}

public enum ReaderHardStop: Error, Sendable, Hashable {
  case tampered(TamperReason)
  /// A frame or op version above this build's (R3, R10): "Update Hasala".
  case updateRequired
}

/// Why one blob was set aside; the cursor advances past it (A-32).
public enum SetAsideReason: String, Sendable, Hashable, CaseIterable {
  case aeadFailed  // R7, with the integrity alarm
  case regionMalformed  // R8
  case payloadInvalid  // R9
  case opsUndecodable  // R10
}

public enum OpsDecodeOutcome: Sendable, Hashable {
  case ops([Op])
  case hardStop(ReaderHardStop)
  case setAside(SetAsideReason, message: String)
}

extension OpCodec {
  /// R10: an opened blob's plaintext → its ops, the blob being the unit. A `v`
  /// one above the schema stops sync; any other decode failure sets the WHOLE blob
  /// aside, valid siblings included (review 2 F-24).
  public static func decodeR10(_ plaintext: some Collection<UInt8>) -> OpsDecodeOutcome {
    do {
      return .ops(try decodeBlobOps(plaintext))
    } catch {
      switch error {
      case .unknownNewerVersion: return .hardStop(.updateRequired)
      case .setAside(let m): return .setAside(.opsUndecodable, message: m)
      }
    }
  }
}
