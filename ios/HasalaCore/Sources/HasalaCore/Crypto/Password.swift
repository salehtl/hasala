// Passwords give ACCESS ONLY (spec 01 §4.10, PO B): nothing is derived from or
// wrapped under `pw`, `S` or the server's hash. This file stretches the
// password on the device and applies the creation policy; that is all a
// password does on the client.
//
//   pw     = utf8(NFC(password))
//   salt_c = "hasala/v1/password" ‖ 0x00 ‖ s_srv32 ‖ utf8(email_norm)
//   S      = PBKDF2-HMAC-SHA256(pw, salt_c, 600 000), 32 bytes (CommonCrypto)
//
// The iteration count is a constant: no server field can lower it (a TLS
// terminator could otherwise harvest a cheap `S`). A new work factor is a new
// domain string, never a parameter.
import CorePrimitives
import Foundation

public enum PasswordStretch {
  public static let iterations: UInt32 = 600_000

  public enum Failure: Error, Equatable, Sendable {
    /// `s_srv` is not 32 bytes.
    case badSalt
    /// The address is not in `email_norm` form: a client never stretches with a
    /// salt that lacks its own normalized address (AT-C17).
    case addressNotNormalized
    case primitive(PrimitivesError)
  }

  /// `salt_c` for `s_srv` and an already-normalized address.
  public static func salt(serverSalt: Data, emailNorm: String) throws(Failure) -> Data {
    guard serverSalt.count == 32 else { throw .badSalt }
    guard (try? EmailNorm.normalize(emailNorm)) == emailNorm else { throw .addressNotNormalized }
    return Domain.password.prefix + serverSalt + Data(emailNorm.utf8)
  }

  /// `S` (32 bytes, in `SecureBytes`). Slow by design (~0.1 s on a Mac): run it
  /// off the main actor.
  public static func stretch(password: String, serverSalt: Data, emailNorm: String) throws(Failure) -> SecureBytes {
    let saltC = try salt(serverSalt: serverSalt, emailNorm: emailNorm)
    let pw = SecureBytes(copying: Array(password.precomposedStringWithCanonicalMapping.utf8))
    defer { pw.wipe() }
    do {
      return try PBKDF2.sha256(password: pw, salt: saltC, iterations: iterations)
    } catch {
      throw .primitive(error)
    }
  }
}

/// The creation policy (§4.10; `04` §6.1.2): after NFC, 12-128 Unicode scalars,
/// no composition rules, then the bundled blocklist. It runs only where a
/// password is CREATED, never where one is proved, so a list update can never
/// lock anyone out; the server cannot check it (it sees only `S`).
public enum PasswordPolicy {
  public static let minScalars = 12
  public static let maxScalars = 128

  public enum Violation: Error, Equatable, Sendable {
    /// "Use at least 12 characters."
    case tooShort
    case tooLong
    /// "That password is too common…"
    case tooCommon
  }

  /// The bundled list (`common-passwords-v1.txt`, owned by `04`): entries of ANY
  /// length (a root such as `password` is shorter than the minimum, and is what a
  /// stripped candidate matches), each ASCII-lowercased and in NFC.
  public struct Blocklist: Sendable {
    let entries: Set<[UInt8]>

    public init(entries: some Sequence<String>) {
      var s = Set<[UInt8]>()
      for e in entries where !e.isEmpty { s.insert(Array(e.precomposedStringWithCanonicalMapping.utf8)) }
      self.entries = s
    }

    /// One entry per line (LF or CRLF); blank lines are skipped.
    public init(text: String) {
      self.init(
        entries: text.utf8.split(separator: 0x0a, omittingEmptySubsequences: true).map { line in
          String(decoding: line.last == 0x0d ? line.dropLast() : line, as: UTF8.self)
        })
    }

    public var count: Int { entries.count }

    func contains(_ bytes: [UInt8]) -> Bool { entries.contains(bytes) }
  }

  /// `nil` when `candidate` may be set as a new password. Length first, then
  /// the list: `c` = the ASCII-lowercased NFC candidate, `r` = `c` without every
  /// trailing ASCII digit and `!`, `.`, `?`, `#`, `*`; refused when `c` or `r` is
  /// an entry. The candidate is compared in memory and never logged.
  public static func check(_ candidate: String, blocklist: Blocklist) -> Violation? {
    let nfc = candidate.precomposedStringWithCanonicalMapping
    let n = nfc.unicodeScalars.count
    if n < minScalars { return .tooShort }
    if n > maxScalars { return .tooLong }
    var c = Array(nfc.utf8)
    defer { for i in c.indices { c[i] = 0 } }
    for i in c.indices where (0x41...0x5a).contains(c[i]) { c[i] += 0x20 }
    var end = c.count
    while end > 0, isStrippable(c[end - 1]) { end -= 1 }
    if blocklist.contains(c) || blocklist.contains(Array(c[0..<end])) { return .tooCommon }
    return nil
  }

  static func isStrippable(_ b: UInt8) -> Bool {
    (0x30...0x39).contains(b) || b == 0x21 || b == 0x2e || b == 0x3f || b == 0x23 || b == 0x2a
  }
}

/// The 80-bit reset approval code (D37; §10.16 C9): the new iPhone shows it, the
/// approving iPhone types or scans it, and it binds the approval to the new
/// iPhone's ephemeral key.
///
///   code80 = SHA256("hasala/v1/reset-code" ‖ 0x00 ‖ ek_pub32)[0:10];  shown as base32 (16 characters)
public enum ResetCode {
  public static func code80(ephemeralPublicKey: Data) throws(SigningMessageError) -> Data {
    Data(sha256(Domain.resetCode.prefix + (try SigningMessage.check(ephemeralPublicKey, 32, "ek_pub"))).prefix(10))
  }

  /// The 16-character `A-Z2-7` form.
  public static func text(ephemeralPublicKey: Data) throws(SigningMessageError) -> String {
    Base32.encode(try code80(ephemeralPublicKey: ephemeralPublicKey))
  }

  /// Whether typed text (any case, spaces and hyphens ignored) is the code for
  /// `ephemeralPublicKey`, compared in constant time.
  public static func matches(_ typed: String, ephemeralPublicKey: Data) -> Bool {
    var u: [UInt8] = []
    for b in typed.utf8 where b != 0x20 && b != 0x2d {
      u.append((0x61...0x7a).contains(b) ? b - 0x20 : b)
    }
    guard let want = try? text(ephemeralPublicKey: ephemeralPublicKey) else { return false }
    return constantTimeEquals(u, Array(want.utf8))
  }
}
