// What the auth ceremonies need (spec 04 §6), and the one error they throw.
//
// The ceremonies here are the core half of §6.2: every byte, every server call
// and every Keychain write, in 01's order. The app's Live/ layer drives them
// from the screens and supplies the platform pieces (the passkey sheet, the
// Secure Enclave DAK, the Keychain), each behind its core protocol.
import CoreAuth
import CoreCrypto
import CorePrimitives
import CoreStore
import CoreTime
import CoreWire
import Foundation

public struct AccountEnvironment: Sendable {
  public let client: AuthClient
  public let secrets: Secrets
  public let approvalKeys: any ApprovalKeySigner
  public let passkeys: (any PasskeyProvider)?
  public let clock: any CoreTime.Clock
  public let random: any RandomSource
  /// The API origin stored in the binding (`https://api.hasala.app`).
  public let apiBase: String
  /// `<AS>/accounts`; each account's store lives in `<user_id>/` below it.
  /// `nil` keeps stores in memory (tests).
  public let accountsDirectory: URL?

  public init(
    client: AuthClient, secrets: Secrets, approvalKeys: any ApprovalKeySigner, passkeys: (any PasskeyProvider)?,
    clock: any CoreTime.Clock, random: any RandomSource, apiBase: String, accountsDirectory: URL?
  ) {
    self.client = client
    self.secrets = secrets
    self.approvalKeys = approvalKeys
    self.passkeys = passkeys
    self.clock = clock
    self.random = random
    self.apiBase = apiBase
    self.accountsDirectory = accountsDirectory
  }

  public func storeDirectory(for user: UserID) -> URL? {
    accountsDirectory?.appendingPathComponent(user.string, isDirectory: true)
  }

  func openStore(for user: UserID) throws(CeremonyError) -> LedgerStore {
    do {
      if let dir = storeDirectory(for: user) { return try LedgerStore.open(directory: dir) }
      return try LedgerStore.inMemory()
    } catch {
      throw .store(error)
    }
  }
}

public enum CeremonyError: Error, Sendable {
  case api(APIError)
  case passkey(PasskeyError)
  case approvalKey(ApprovalKeyError)
  case secret(SecretStoreError)
  case store(StoreError)
  /// A server value failed the client's own check BEFORE any prompt: `C_reg`
  /// (01 §10.3 step 6) or a step-up `C` (AT-C9).
  case challengeMismatch
  /// E-04: after bootstrap, `GET /keys` or `GET /account` differ from this
  /// device's values; or the commitments of an unwrapped body failed.
  case integrityAlarm(String)
  /// S-15: the words are valid but not this account's.
  case notThisAccountsPhrase
  /// The words are not 12 valid words with a good checksum.
  case badPhrase
  case badEmail
  case badName
  case badInviteCode
  /// Unlock with Face ID was asked for but this credential has no PRF wrap,
  /// or the authenticator returned no PRF output: fall back to the phrase.
  case noPRF
  /// A step-up proof kind this action does not allow, or a `device` proof
  /// without a bound writer and DAK.
  case noDeviceKey
  case needsPasskey
  /// A 2xx whose body this client cannot use.
  case badResponse(String)
  case crypto(String)

  /// The server's refusal, when that is what happened.
  public var failure: APIFailure? {
    if case .api(let e) = self { return e.failure }
    return nil
  }
}

/// The plain-language class of a ceremony failure (spec 04 §6.1.5): the UI
/// picks its copy block from this and never from a raw code.
public enum CeremonyFailureClass: Sendable, Hashable {
  case cancelled, unsupported, noCredential, notInvited, badName, rejected, wrongCredentials, recoveryRefused,
    resetRefused, emailInUse, codeRejected, badEmail, lastAuthenticator, frozen, notApproved, stepUpFailed,
    noDeviceKey, rateLimited, offline, unavailable, integrity, other
}

extension CeremonyError {
  public var failureClass: CeremonyFailureClass {
    switch self {
    case .passkey(.cancelled), .approvalKey(.cancelled): return .cancelled
    case .passkey(.unsupported), .approvalKey(.unavailable): return .unsupported
    case .passkey(.noCredential): return .noCredential
    case .badEmail: return .badEmail
    case .badName: return .badName
    case .noDeviceKey, .approvalKey(.missing): return .noDeviceKey
    case .integrityAlarm, .challengeMismatch: return .integrity
    case .api(.transport): return .offline
    case .api(.refused(let f)):
      switch (f.status, f.code) {
      case (403, "not_invited"): return .notInvited
      case (400, "bad_name"): return .badName
      case (400, "bad_email"): return .badEmail
      case (403, "passkey_rejected"): return .rejected
      case (403, "password_rejected"): return .wrongCredentials
      case (403, "recovery_refused"): return .recoveryRefused
      case (403, "reset_refused"): return .resetRefused
      case (409, "email_in_use"): return .emailInUse
      case (403, "code_rejected"): return .codeRejected
      case (409, "last_authenticator"): return .lastAuthenticator
      case (403, "account_frozen"): return .frozen
      case (409, "not_approved"): return .notApproved
      case (403, "step_up_failed"): return .stepUpFailed
      case (429, _): return .rateLimited
      case (500..., _): return .unavailable
      default: return .other
      }
    default: return .other
    }
  }
}

/// Input rules the app applies before calling (§6.1.4, §6.8).
public enum AuthInput {
  /// §6.1.4: upper-cased, spaces and hyphens dropped; exactly 24 of `A-Z2-7`.
  public static func inviteCode(_ typed: String) -> String? {
    var out: [UInt8] = []
    for b in typed.utf8 where b != 0x20 && b != 0x2d {
      out.append((0x61...0x7a).contains(b) ? b - 0x20 : b)
    }
    guard out.count == 24, out.allSatisfy({ (0x41...0x5a).contains($0) || (0x32...0x37).contains($0) }) else {
      return nil
    }
    return String(decoding: out, as: UTF8.self)
  }
}

/// RFC 3339 (Go's `time.Time` JSON, up to nanoseconds) → epoch seconds.
enum RFC3339 {
  static func seconds(_ s: String?) -> Int64? {
    guard let s else { return nil }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return Int64(d.timeIntervalSince1970) }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s).map { Int64($0.timeIntervalSince1970) }
  }
}

/// A Keychain or store step, mapped.
func secretStep<T>(_ body: () throws(SecretStoreError) -> T) throws(CeremonyError) -> T {
  do { return try body() } catch { throw .secret(error) }
}

func apiStep<T>(_ body: () async throws(APIError) -> T) async throws(CeremonyError) -> T {
  do { return try await body() } catch { throw .api(error) }
}

func cryptoStep<T>(_ what: String, _ body: () throws -> T) throws(CeremonyError) -> T {
  do { return try body() } catch { throw .crypto(what) }
}

func b64(_ s: String, _ what: String) throws(CeremonyError) -> Data {
  guard let d = try? Base64.decode(s) else { throw .badResponse(what) }
  return d
}
