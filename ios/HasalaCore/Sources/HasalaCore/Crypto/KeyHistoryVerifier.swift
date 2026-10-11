// Key-history verification on the device (spec 01 §10.13): the only source of
// the roster the reader trusts (R1, R2b of §6.6), never `GET /writers`.
//
//   for row in entries (ascending id):
//     every row: alg "ed25519", |pubkey| 32, |nonce| 32, |signature| 64
//     registered: authorized_by "authority", |dak_pubkey| 65 with 0x04 first,
//                 the AAK signs RegistrationMessage(nonce, writer_id, pubkey, dak_pubkey),
//                 writer_id not yet in the roster (a revoked writer never returns)
//     revoked:    authorized_by "device", the authorizer is a live roster writer
//                 (it may be the target itself), final_counter >= 0, |final_head| 32,
//                 the authorizer's DWK signs RevocationMessage(nonce, writer_id,
//                 final_counter, final_head), and the target is live
//   any failed require -> integrity alarm keyHistoryInvalid (the caller keeps
//   its last verified roster)
//   GET /writers ⊆ roster with matching pubkey, dak_pubkey and revoked state,
//   else integrity alarm rosterMismatch
//
// The AAK public key is the one derived from the unwrapped seed (§4.5:
// `KeyBody.authorityPublicKey()`), never one the server serves. Parsing the
// JSON of #26 and #27 (`02`) is the caller's (CoreSync); this file takes the
// decoded fields.
import CorePrimitives
import CoreWire
import Foundation
import HasalaText

public enum KeyHistoryVerifier {
  /// One `GET /key-history` entry, its byte fields decoded from base64. A field
  /// the server sent as `null` is `nil`.
  public struct Entry: Sendable, Hashable {
    public let id: Int64
    public let writerID: String
    public let alg: String
    public let publicKey: Data
    public let dakPublicKey: Data?
    public let event: String
    public let authorizedBy: String
    public let authorizerWriterID: String?
    public let finalCounter: Int64?
    public let finalHead: Data?
    public let nonce: Data
    public let signature: Data

    public init(
      id: Int64, writerID: String, alg: String, publicKey: Data, dakPublicKey: Data?, event: String,
      authorizedBy: String, authorizerWriterID: String?, finalCounter: Int64?, finalHead: Data?, nonce: Data,
      signature: Data
    ) {
      self.id = id
      self.writerID = writerID
      self.alg = alg
      self.publicKey = publicKey
      self.dakPublicKey = dakPublicKey
      self.event = event
      self.authorizedBy = authorizedBy
      self.authorizerWriterID = authorizerWriterID
      self.finalCounter = finalCounter
      self.finalHead = finalHead
      self.nonce = nonce
      self.signature = signature
    }
  }

  /// A writer of the verified roster.
  public struct Writer: Sendable, Hashable {
    /// The DWK (Ed25519, 32 bytes).
    public let dwkPublicKey: Data
    /// The DAK (P-256 X9.63, 65 bytes), certified by the AAK's signature.
    public let dakPublicKey: Data
    /// `(final_counter, final_head)` once revoked; `nil` while live.
    public let final: Chain.Head?
    public var isLive: Bool { final == nil }
  }

  /// The verified roster and the newest entry id it covers.
  public struct Roster: Sendable, Hashable {
    public let writers: [WriterID: Writer]
    /// The id of the last entry verified (`key_history_id`, `04` §4.2); `nil`
    /// before any entry.
    public let lastEntryID: Int64?

    public static let empty = Roster(writers: [:], lastEntryID: nil)

    /// What the reader's R1 and R2b use: each writer's DWK and pinned final head.
    public var forReader: [WriterID: HeadCheck.RosterWriter] {
      writers.mapValues { HeadCheck.RosterWriter(dwkPublicKey: $0.dwkPublicKey, revokedAt: $0.final) }
    }
  }

  /// The two integrity alarms. Neither says which field failed beyond the entry
  /// or writer it names: the caller raises the alarm and keeps its last roster.
  public enum Alarm: Error, Sendable, Hashable {
    /// An entry broke a require of §10.13 (its id).
    case keyHistoryInvalid(entryID: Int64)
    /// `GET /writers` lists a writer the roster lacks, or disagrees with it.
    case rosterMismatch(writerID: String)
  }

  /// Replays `entries` (oldest first, ids strictly ascending) onto `previous`
  /// (`.empty` for the full history; a roster from an earlier read to continue
  /// with entries after its `lastEntryID`) under `authorityPublicKey`.
  public static func verify(entries: [Entry], authorityPublicKey: Data, previous: Roster = .empty) throws(Alarm)
    -> Roster
  {
    var roster = previous.writers
    var last = previous.lastEntryID
    for e in entries {
      guard last.map({ e.id > $0 }) ?? true, check(e, &roster, authorityPublicKey: authorityPublicKey) else {
        throw .keyHistoryInvalid(entryID: e.id)
      }
      last = e.id
    }
    return Roster(writers: roster, lastEntryID: last)
  }

  /// One entry's requires; applies it to `roster` only when all hold.
  static func check(_ e: Entry, _ roster: inout [WriterID: Writer], authorityPublicKey: Data) -> Bool {
    guard utf8Equal(e.alg, "ed25519"), e.publicKey.count == Ed25519.publicKeyByteCount, e.nonce.count == 32,
      e.signature.count == Ed25519.signatureByteCount, let w = WriterID(e.writerID)
    else { return false }
    switch e.event {
    case "registered":
      guard utf8Equal(e.authorizedBy, "authority"), let dak = e.dakPublicKey, dak.count == DAK.publicKeyByteCount,
        dak.first == 0x04, roster[w] == nil,
        let message = try? SigningMessage.registration(
          nonce: e.nonce, writerID: w, dwkPublicKey: e.publicKey, dakPublicKey: dak),
        Ed25519.verify(publicKey: authorityPublicKey, signature: e.signature, message: message)
      else { return false }
      roster[w] = Writer(dwkPublicKey: e.publicKey, dakPublicKey: dak, final: nil)
      return true
    case "revoked":
      guard utf8Equal(e.authorizedBy, "device"), let a = e.authorizerWriterID.flatMap(WriterID.init),
        let signer = roster[a], signer.isLive, let target = roster[w], target.isLive,
        let counter = e.finalCounter, counter >= 0, let head = e.finalHead.flatMap(Hash32.init),
        let message = try? SigningMessage.revocation(nonce: e.nonce, writerID: w, finalCounter: counter, finalHead: head),
        Ed25519.verify(publicKey: signer.dwkPublicKey, signature: e.signature, message: message)
      else { return false }
      roster[w] = Writer(
        dwkPublicKey: target.dwkPublicKey, dakPublicKey: target.dakPublicKey, final: Chain.Head(counter: counter, hash: head))
      return true
    default:
      return false
    }
  }

  /// One `GET /writers` entry (#26), decoded.
  public struct ServerWriter: Sendable, Hashable {
    public let writerID: String
    public let publicKey: Data
    public let dakPublicKey: Data?
    /// `revoked_at` is not null.
    public let revoked: Bool

    public init(writerID: String, publicKey: Data, dakPublicKey: Data?, revoked: Bool) {
      self.writerID = writerID
      self.publicKey = publicKey
      self.dakPublicKey = dakPublicKey
      self.revoked = revoked
    }
  }

  /// `GET /writers ⊆ roster`, each with the roster's DWK, DAK and revoked state.
  public static func compare(writers: [ServerWriter], roster: Roster) throws(Alarm) {
    for s in writers {
      guard let w = WriterID(s.writerID), let r = roster.writers[w], r.dwkPublicKey == s.publicKey,
        s.dakPublicKey == r.dakPublicKey, s.revoked == !r.isLive
      else { throw .rosterMismatch(writerID: s.writerID) }
    }
  }
}
