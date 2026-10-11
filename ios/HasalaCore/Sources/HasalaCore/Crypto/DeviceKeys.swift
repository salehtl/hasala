// The device's two keys (spec 01 §4.8-§4.9) and the reader's head check.
//
// DWK: Ed25519, per writer, Keychain `AfterFirstUnlockThisDeviceOnly`; signs
// batch heads, revocation, session binding, deletion, passkey-add and wrap-put.
// DAK: P-256, per writer, in the Secure Enclave with user presence; signs
// device step-ups, reset approvals and device freezes. The Secure Enclave signer
// is app code (`Platform/ApprovalKey`, behind `CoreAuth.ApprovalKeySigner`);
// tests use `CoreSoftAuth`'s software signer, which has the same byte formats.
// This file only checks keys and signatures.
import CorePrimitives
import CoreWire
import CryptoKit
import Foundation

public enum DWK {
  /// A fresh device writer key from the system CSPRNG: `(seed, public key)`.
  public static func generate() -> (seed: SecureBytes, publicKey: Data) { Ed25519.generate() }

  public static func sign(seed: some ContiguousBytes, message: some DataProtocol) throws(PrimitivesError) -> Data {
    try Ed25519.sign(seed: seed, message: message)
  }
}

public enum DAK {
  public static let publicKeyByteCount = 65
  public static let signatureByteCount = 64

  /// The P-256 group order `n`, big-endian.
  static let order: [UInt8] = Array(
    try! Hex.decode("ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551"))

  /// Whether `x963` is an uncompressed P-256 point on the curve (`04 ‖ X ‖ Y`,
  /// 65 bytes): a compressed point, an off-curve point and `(0,0)` are refused,
  /// as the server's `ecdsa.ParseUncompressedPublicKey` refuses them.
  public static func isValidPublicKey(_ x963: Data) -> Bool {
    guard x963.count == publicKeyByteCount, x963.first == 0x04 else { return false }
    return (try? P256.Signing.PublicKey(x963Representation: x963)) != nil
  }

  /// Verifies a raw `r ‖ s` signature over `message` (ECDSA over SHA-256),
  /// refusing `r` or `s` equal to 0 or ≥ the group order first.
  public static func verify(publicKey: Data, signature: Data, message: some DataProtocol) -> Bool {
    guard isValidPublicKey(publicKey), signature.count == signatureByteCount else { return false }
    let s = [UInt8](signature)
    guard inRange(Array(s[0..<32])), inRange(Array(s[32..<64])) else { return false }
    return P256Verify.verify(publicKeyX963: publicKey, signatureRaw: signature, message: message)
  }

  /// `0 < v < n`.
  static func inRange(_ v: [UInt8]) -> Bool {
    guard v.contains(where: { $0 != 0 }) else { return false }
    for (a, b) in zip(v, order) where a != b { return a < b }
    return false  // v == n
  }
}

/// Reader check R2b (spec 01 §6.6, §7.1; R-02): every writer's last row in a
/// page carries a head signature that verifies under that writer's roster DWK
/// over `HeadMessage(user_id, counter, blob_hash, W)`, and a revoked writer has
/// no row past the head its revoker pinned.
public enum HeadCheck {
  public struct Row: Sendable, Hashable {
    public let writerID: WriterID
    public let counter: Int64
    public let blobHash: Hash32
    public let headSig: Data?
    public init(writerID: WriterID, counter: Int64, blobHash: Hash32, headSig: Data?) {
      self.writerID = writerID
      self.counter = counter
      self.blobHash = blobHash
      self.headSig = headSig
    }
  }

  /// A writer in the verified roster (§10.13).
  public struct RosterWriter: Sendable, Hashable {
    public let dwkPublicKey: Data
    /// The pinned `(final_counter, final_head)` when the writer is revoked.
    public let revokedAt: Chain.Head?
    public init(dwkPublicKey: Data, revokedAt: Chain.Head?) {
      self.dwkPublicKey = dwkPublicKey
      self.revokedAt = revokedAt
    }
  }

  /// Checks a page. Writers are checked in the order they first appear.
  public static func verify(userID: UserID, rows: [Row], roster: [WriterID: RosterWriter]) throws(ReaderHardStop) {
    var order: [WriterID] = []
    var last: [WriterID: Row] = [:]
    for r in rows {
      if last[r.writerID] == nil { order.append(r.writerID) }
      if let l = last[r.writerID], l.counter > r.counter { continue }
      last[r.writerID] = r
    }
    for w in order {
      guard let entry = roster[w] else { throw .tampered(.unknownWriter) }
      let top = last[w]!
      guard let sig = top.headSig else { throw .tampered(.headUnsigned) }
      let message = SigningMessage.head(userID: userID, counter: top.counter, blobHash: top.blobHash, writerID: w)
      guard Ed25519.verify(publicKey: entry.dwkPublicKey, signature: sig, message: message) else {
        throw .tampered(.headInvalid)
      }
      if let pin = entry.revokedAt {
        for r in rows where r.writerID == w {
          if r.counter > pin.counter { throw .tampered(.afterRevocation) }
          if r.counter == pin.counter, r.blobHash != pin.hash { throw .tampered(.afterRevocation) }
        }
      }
    }
  }
}
