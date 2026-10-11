// BootstrapPayload v1 (spec 01 §10.3.1): the canonical bytes the AAK signs
// inside BootstrapMessage (D17). The server rebuilds them from `02` §10.1's JSON.
//
//   0     1  payload_version 0x01        293  32  email_hash = SHA256(utf8(email_norm))
//   1    16  uuid_raw(user_id)            325   1  auth_kind
//   17   32  amk_commitment               326  32  auth_hash
//   49   32  authority_pubkey             358   1  0x01 (writer alg ed25519)
//   81   32  recovery_pubkey              359  32  writer pubkey (DWK)
//   113   4  u32be(1) initial epoch       391  65  writer dak_pubkey (04 ‖ X ‖ Y)
//   117   2  u16be(127)                   456   1  u8(40)
//   119 127  recovery_wrap                457  40  writer_id
//   246   2  u16be(45)                    497   2  u16be(c), c ∈ {0} ∪ [16, 1023]
//   248  45  phrase_box                   499   c  credential_id
//                                         499+c 2  u16be(w), w = 0 if c = 0 else 127
//                                         501+c w  prf wrap
//
// Total 501 + c + w (644 for a passkey payload with a 16-byte credential, 501
// for a password one).
import CorePrimitives
import CoreWire
import Foundation

public struct BootstrapPayload: Sendable, Hashable {
  public static let version: UInt8 = 0x01

  public let userID: UserID
  public let amkCommitment: Data
  public let authorityPublicKey: Data
  public let recoveryPublicKey: Data
  public let recoveryWrap: Data
  public let phraseBox: Data
  public let emailNorm: String
  public let authKind: AuthKind
  /// `0^32`; `SHA256(raw attestationObject)` of the creating credential; or `SHA256(S)`.
  public let authHash: Data
  public let writerPublicKey: Data
  public let writerDAKPublicKey: Data
  public let writerID: WriterID
  /// The asserting or creating credential's PRF wrap, if any.
  public let prfWrap: (credentialID: Data, wrap: Data)?

  public init(
    userID: UserID, amkCommitment: Data, authorityPublicKey: Data, recoveryPublicKey: Data, recoveryWrap: Data,
    phraseBox: Data, emailNorm: String, authKind: AuthKind, authHash: Data, writerPublicKey: Data,
    writerDAKPublicKey: Data, writerID: WriterID, prfWrap: (credentialID: Data, wrap: Data)?
  ) {
    self.userID = userID
    self.amkCommitment = amkCommitment
    self.authorityPublicKey = authorityPublicKey
    self.recoveryPublicKey = recoveryPublicKey
    self.recoveryWrap = recoveryWrap
    self.phraseBox = phraseBox
    self.emailNorm = emailNorm
    self.authKind = authKind
    self.authHash = authHash
    self.writerPublicKey = writerPublicKey
    self.writerDAKPublicKey = writerDAKPublicKey
    self.writerID = writerID
    self.prfWrap = prfWrap
  }

  /// The canonical bytes.
  public func encoded() throws(SigningMessageError) -> Data {
    var out = Data([BootstrapPayload.version])
    out += userID.raw
    out += try SigningMessage.check(amkCommitment, 32, "amk_commitment")
    out += try SigningMessage.check(authorityPublicKey, 32, "authority_pubkey")
    out += try SigningMessage.check(recoveryPublicKey, 32, "recovery_pubkey")
    out += SigningMessage.u32be(1)
    out += [0x00, 127]
    out += try SigningMessage.check(recoveryWrap, Wrap.byteCount, "recovery_wrap")
    out += [0x00, 45]
    out += try SigningMessage.check(phraseBox, PhraseBox.byteCount, "phrase_box")
    out += sha256(Data(emailNorm.utf8))
    out += [authKind.rawValue]
    out += try SigningMessage.check(authHash, 32, "auth_hash")
    out += [0x01]
    out += try SigningMessage.check(writerPublicKey, 32, "writer pubkey")
    out += try SigningMessage.check(writerDAKPublicKey, 65, "writer dak_pubkey")
    out += [UInt8(WriterID.byteCount)]
    out += writerID.bytes
    if let (credentialID, wrap) = prfWrap {
      guard Wrap.credentialIDBytes.contains(credentialID.count) else {
        throw .invalidLength(field: "credential_id", expected: 16, got: credentialID.count)
      }
      out += [UInt8(credentialID.count >> 8), UInt8(credentialID.count & 0xff)]
      out += credentialID
      out += [0x00, 127]
      out += try SigningMessage.check(wrap, Wrap.byteCount, "prf wrap")
    } else {
      out += [0x00, 0x00, 0x00, 0x00]
    }
    return out
  }

  public static func == (a: BootstrapPayload, b: BootstrapPayload) -> Bool {
    (try? a.encoded()) == (try? b.encoded())
  }

  public func hash(into h: inout Hasher) { h.combine(try? encoded()) }
}
