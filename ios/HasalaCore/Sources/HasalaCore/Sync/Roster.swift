// The verified roster (spec 01 §10.13; spec 04 §5.2 R1): `GET /key-history`
// replayed under the AAK public key, then `GET /writers` checked against it.
//
// Where the AAK public key comes from: 01 §10.13 wants `AAK.pub` "derived from
// the unwrapped seed". The seed is in memory only during a ceremony (01 §11.1),
// so the device derives `AAK.pub` from the body at enrolment and pins it here,
// in `sync_state.roster_json`, next to the roster it verified. Every later
// refresh (each pull's R1 re-fetch, each security wake) verifies under that
// pinned key; the server's `authority_pubkey` is never used.
import CoreAuth
import CoreCrypto
import CorePrimitives
import CoreStore
import CoreWire
import Foundation

/// `sync_state.roster_json`.
public struct PinnedRoster: Codable, Sendable, Hashable {
  public struct Writer: Codable, Sendable, Hashable {
    public let dwk: String
    public let dak: String
    public let final_counter: Int64?
    public let final_head: String?
  }

  /// `AAK.pub`, b64 32: derived from the unwrapped seed at enrolment.
  public let authority_pubkey: String
  public let last_entry_id: Int64?
  public let writers: [String: Writer]

  public init(authorityPublicKey: Data, roster: KeyHistoryVerifier.Roster) {
    authority_pubkey = Base64.encode(authorityPublicKey)
    last_entry_id = roster.lastEntryID
    var w: [String: Writer] = [:]
    for (id, r) in roster.writers {
      w[id.string] = Writer(
        dwk: Base64.encode(r.dwkPublicKey), dak: Base64.encode(r.dakPublicKey), final_counter: r.final?.counter,
        final_head: r.final.map { Base64.encode($0.hash.bytes) })
    }
    writers = w
  }

  public var authorityPublicKey: Data? { try? Base64.decode(authority_pubkey) }

  /// The reader's view (R1, R2b).
  public func forReader() -> [WriterID: HeadCheck.RosterWriter] {
    var out: [WriterID: HeadCheck.RosterWriter] = [:]
    for (id, w) in writers {
      guard let wid = WriterID(id), let dwk = try? Base64.decode(w.dwk) else { continue }
      var final: Chain.Head?
      if let c = w.final_counter, let h = w.final_head.flatMap({ try? Base64.decode($0) }).flatMap(Hash32.init) {
        final = Chain.Head(counter: c, hash: h)
      }
      out[wid] = HeadCheck.RosterWriter(dwkPublicKey: dwk, revokedAt: final)
    }
    return out
  }

  /// Live writers other than `own` (C9's "another live writer" rule, Devices).
  public func liveWriters() -> [WriterID] {
    writers.compactMap { $0.value.final_counter == nil ? WriterID($0.key) : nil }
  }

  public func encoded() -> Data {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys]
    return (try? e.encode(self)) ?? Data()
  }

  /// Whether `self` (a fresh fetch) only extends `pinned` (01 §10.13: the
  /// server cannot roll the roster back). It must be under the same AAK, at or
  /// past the pinned `last_entry_id`, keep every pinned writer with the same
  /// DWK and DAK, and keep every pinned `final` exactly (a revocation never
  /// changes or disappears). New writers and new revocations are fine.
  public func extends(_ pinned: PinnedRoster) -> Bool {
    guard authority_pubkey == pinned.authority_pubkey else { return false }
    if let old = pinned.last_entry_id {
      guard let new = last_entry_id, new >= old else { return false }
    }
    for (id, old) in pinned.writers {
      guard let new = writers[id], new.dwk == old.dwk, new.dak == old.dak else { return false }
      if old.final_counter != nil || old.final_head != nil {
        guard new.final_counter == old.final_counter, new.final_head == old.final_head else { return false }
      }
    }
    return true
  }

  public static func decode(_ d: Data?) -> PinnedRoster? {
    guard let d else { return nil }
    return try? JSONDecoder().decode(PinnedRoster.self, from: d)
  }
}

public enum RosterService {
  /// Decodes #27's entries; a field that is not its encoding is a verification
  /// failure of that entry (`keyHistoryInvalid`).
  static func entries(_ r: KeyHistoryResponse) throws(KeyHistoryVerifier.Alarm) -> [KeyHistoryVerifier.Entry] {
    try r.entries.map { e throws(KeyHistoryVerifier.Alarm) in
      func bytes(_ s: String) throws(KeyHistoryVerifier.Alarm) -> Data {
        guard let d = try? Base64.decode(s) else { throw .keyHistoryInvalid(entryID: e.id.value) }
        return d
      }
      return KeyHistoryVerifier.Entry(
        id: e.id.value, writerID: e.writer_id, alg: e.alg, publicKey: try bytes(e.pubkey),
        dakPublicKey: try e.dak_pubkey.map(bytes), event: e.event, authorizedBy: e.authorized_by,
        authorizerWriterID: e.authorizer_writer_id, finalCounter: e.final_counter?.value,
        finalHead: try e.final_head.map(bytes), nonce: try bytes(e.nonce), signature: try bytes(e.signature))
    }
  }

  static func serverWriters(_ r: WritersResponse) throws(KeyHistoryVerifier.Alarm) -> [KeyHistoryVerifier.ServerWriter] {
    try r.writers.map { w throws(KeyHistoryVerifier.Alarm) in
      guard let pub = try? Base64.decode(w.pubkey) else { throw .rosterMismatch(writerID: w.writer_id) }
      let dak = w.dak_pubkey.flatMap { try? Base64.decode($0) }
      return KeyHistoryVerifier.ServerWriter(
        writerID: w.writer_id, publicKey: pub, dakPublicKey: dak, revoked: w.revoked_at != nil)
    }
  }

  /// Fetches the roster again and checks it only extends `pinned`
  /// (`extends`); a rollback is `rosterInvalid`. Nothing is persisted.
  public static func refetch(client: AuthClient, bearer: String, pinned: PinnedRoster) async throws(SyncStop)
    -> PinnedRoster
  {
    guard let aak = pinned.authorityPublicKey else { throw .halted(.rosterInvalid) }
    let fresh = try await fetch(client: client, bearer: bearer, authorityPublicKey: aak)
    guard fresh.extends(pinned) else { throw .halted(.rosterInvalid) }
    return fresh
  }

  /// Fetches `GET /key-history` and `GET /writers`, verifies both under
  /// `authorityPublicKey`, and returns the roster to pin. Nothing is persisted.
  public static func fetch(client: AuthClient, bearer: String, authorityPublicKey: Data) async throws(SyncStop)
    -> PinnedRoster
  {
    let history: KeyHistoryResponse
    let writers: WritersResponse
    do {
      history = try await client.keyHistory(bearer: bearer)
      writers = try await client.writers(bearer: bearer)
    } catch {
      throw SyncStop.read(error)
    }
    do {
      let roster = try KeyHistoryVerifier.verify(
        entries: try entries(history), authorityPublicKey: authorityPublicKey)
      try KeyHistoryVerifier.compare(writers: try serverWriters(writers), roster: roster)
      return PinnedRoster(authorityPublicKey: authorityPublicKey, roster: roster)
    } catch {
      throw .halted(.rosterInvalid)
    }
  }
}
