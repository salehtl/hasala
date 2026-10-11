// AT-C7 (spec 01 §17): KeyHistoryVerifier over a history built here, signed
// with fresh keys (signatures are verified, never compared).
import CorePrimitives
import CoreWire
import CryptoKit
import Foundation
import Testing

@testable import CoreCrypto

@Suite("CoreCrypto: key history (§10.13, AT-C7)")
struct KeyHistoryTests {
  struct Device {
    let writer: WriterID
    let dwk: (seed: SecureBytes, publicKey: Data)
    let dak: Data
  }

  let aak = Ed25519.generate()
  let a = Device(
    writer: WriterID("ios-0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d")!, dwk: Ed25519.generate(),
    dak: P256.Signing.PrivateKey().publicKey.x963Representation)
  let b = Device(
    writer: WriterID("ios-1a1b2c3d-4e5f-4a6b-9c7d-9e0f1a2b3c4d")!, dwk: Ed25519.generate(),
    dak: P256.Signing.PrivateKey().publicKey.x963Representation)
  let headB = Hash32(Data(repeating: 0xb7, count: 32))!

  func nonce(_ id: Int64) -> Data { Data(repeating: UInt8(id & 0xff), count: 32) }

  func registered(_ id: Int64, _ d: Device, signedBy seed: SecureBytes? = nil, dak: Data? = nil) throws
    -> KeyHistoryVerifier.Entry
  {
    let message = try SigningMessage.registration(
      nonce: nonce(id), writerID: d.writer, dwkPublicKey: d.dwk.publicKey, dakPublicKey: d.dak)
    return KeyHistoryVerifier.Entry(
      id: id, writerID: d.writer.string, alg: "ed25519", publicKey: d.dwk.publicKey, dakPublicKey: dak ?? d.dak,
      event: "registered", authorizedBy: "authority", authorizerWriterID: nil, finalCounter: nil, finalHead: nil,
      nonce: nonce(id), signature: try Ed25519.sign(seed: seed ?? aak.seed, message: message))
  }

  func revoked(_ id: Int64, _ target: Device, by signer: Device, counter: Int64, head: Hash32, served: Hash32? = nil)
    throws -> KeyHistoryVerifier.Entry
  {
    let message = try SigningMessage.revocation(nonce: nonce(id), writerID: target.writer, finalCounter: counter, finalHead: head)
    return KeyHistoryVerifier.Entry(
      id: id, writerID: target.writer.string, alg: "ed25519", publicKey: target.dwk.publicKey, dakPublicKey: nil,
      event: "revoked", authorizedBy: "device", authorizerWriterID: signer.writer.string, finalCounter: counter,
      finalHead: (served ?? head).bytes, nonce: nonce(id), signature: try Ed25519.sign(seed: signer.dwk.seed, message: message))
  }

  func verify(_ entries: [KeyHistoryVerifier.Entry]) throws(KeyHistoryVerifier.Alarm) -> KeyHistoryVerifier.Roster {
    try KeyHistoryVerifier.verify(entries: entries, authorityPublicKey: aak.publicKey)
  }

  @Test("a valid history passes, and the reader's roster carries the pinned final head")
  func validHistory() throws {
    let history = [try registered(1, a), try registered(2, b), try revoked(3, b, by: a, counter: 7, head: headB)]
    let roster = try verify(history)
    #expect(roster.lastEntryID == 3)
    #expect(roster.writers[a.writer] == .init(dwkPublicKey: a.dwk.publicKey, dakPublicKey: a.dak, final: nil))
    #expect(roster.writers[b.writer]?.final == Chain.Head(counter: 7, hash: headB))
    #expect(roster.forReader[b.writer] == HeadCheck.RosterWriter(dwkPublicKey: b.dwk.publicKey, revokedAt: .init(counter: 7, hash: headB)))
    // A writer may revoke itself; continuing from an earlier roster gives the same result.
    let partial = try verify(Array(history.prefix(2)))
    #expect(try KeyHistoryVerifier.verify(entries: [history[2]], authorityPublicKey: aak.publicKey, previous: partial) == roster)
    #expect(try verify([try registered(1, a), try revoked(2, a, by: a, counter: 0, head: .zero)]).writers[a.writer]?.isLive == false)
  }

  @Test("an inserted unsigned or wrongly signed registered row raises keyHistoryInvalid")
  func forgedRegistration() throws {
    let other = Ed25519.generate()
    #expect(throws: KeyHistoryVerifier.Alarm.keyHistoryInvalid(entryID: 2)) {
      try verify([try registered(1, a), try registered(2, b, signedBy: other.seed)])
    }
    let r = try registered(2, b)
    let unsigned = KeyHistoryVerifier.Entry(
      id: 2, writerID: r.writerID, alg: r.alg, publicKey: r.publicKey, dakPublicKey: r.dakPublicKey, event: r.event,
      authorizedBy: r.authorizedBy, authorizerWriterID: nil, finalCounter: nil, finalHead: nil, nonce: r.nonce,
      signature: Data(count: 64))
    #expect(throws: KeyHistoryVerifier.Alarm.keyHistoryInvalid(entryID: 2)) { try verify([try registered(1, a), unsigned]) }
    // A device-authorized registration is not one.
    let byDevice = KeyHistoryVerifier.Entry(
      id: 2, writerID: r.writerID, alg: r.alg, publicKey: r.publicKey, dakPublicKey: r.dakPublicKey, event: r.event,
      authorizedBy: "device", authorizerWriterID: nil, finalCounter: nil, finalHead: nil, nonce: r.nonce, signature: r.signature)
    #expect(throws: KeyHistoryVerifier.Alarm.keyHistoryInvalid(entryID: 2)) { try verify([try registered(1, a), byDevice]) }
  }

  @Test("a registered row whose dak_pubkey differs from the signed one raises keyHistoryInvalid")
  func swappedDAK() throws {
    let swapped = P256.Signing.PrivateKey().publicKey.x963Representation
    #expect(throws: KeyHistoryVerifier.Alarm.keyHistoryInvalid(entryID: 1)) { try verify([try registered(1, a, dak: swapped)]) }
    var compressed = a.dak
    compressed[0] = 0x02
    #expect(throws: KeyHistoryVerifier.Alarm.keyHistoryInvalid(entryID: 1)) { try verify([try registered(1, a, dak: compressed)]) }
  }

  @Test("a revoked row whose final head differs from the signed one raises keyHistoryInvalid")
  func movedFinalHead() throws {
    let other = Hash32(Data(repeating: 0x11, count: 32))!
    #expect(throws: KeyHistoryVerifier.Alarm.keyHistoryInvalid(entryID: 3)) {
      try verify([try registered(1, a), try registered(2, b), try revoked(3, b, by: a, counter: 7, head: headB, served: other)])
    }
    // Revoked by a writer that is not in the roster, or no longer live.
    #expect(throws: KeyHistoryVerifier.Alarm.keyHistoryInvalid(entryID: 2)) {
      try verify([try registered(1, a), try revoked(2, a, by: b, counter: 1, head: headB)])
    }
    #expect(throws: KeyHistoryVerifier.Alarm.keyHistoryInvalid(entryID: 4)) {
      try verify([
        try registered(1, a), try registered(2, b), try revoked(3, a, by: a, counter: 1, head: headB),
        try revoked(4, b, by: a, counter: 1, head: headB),
      ])
    }
  }

  @Test("a revoked writer reappearing raises an alarm, and so does revoking it twice")
  func revokedWriterReturns() throws {
    let base = [try registered(1, a), try registered(2, b), try revoked(3, b, by: a, counter: 7, head: headB)]
    #expect(throws: KeyHistoryVerifier.Alarm.keyHistoryInvalid(entryID: 4)) { try verify(base + [try registered(4, b)]) }
    #expect(throws: KeyHistoryVerifier.Alarm.keyHistoryInvalid(entryID: 4)) {
      try verify(base + [try revoked(4, b, by: a, counter: 9, head: headB)])
    }
  }

  @Test("entries out of id order, or repeating the previous roster's ids, are refused")
  func idOrder() throws {
    let one = try registered(1, a)
    let two = try registered(2, b)
    #expect(throws: KeyHistoryVerifier.Alarm.keyHistoryInvalid(entryID: 1)) { try verify([two, one]) }
    let partial = try verify([one, two])
    #expect(throws: KeyHistoryVerifier.Alarm.keyHistoryInvalid(entryID: 2)) {
      try KeyHistoryVerifier.verify(entries: [two], authorityPublicKey: aak.publicKey, previous: partial)
    }
  }

  @Test("a GET /writers entry absent from the roster, or with another DAK, raises rosterMismatch")
  func compareWithWriters() throws {
    let roster = try verify([try registered(1, a), try registered(2, b), try revoked(3, b, by: a, counter: 7, head: headB)])
    func w(_ d: Device, dak: Data? = nil, revoked: Bool) -> KeyHistoryVerifier.ServerWriter {
      .init(writerID: d.writer.string, publicKey: d.dwk.publicKey, dakPublicKey: dak ?? d.dak, revoked: revoked)
    }
    try KeyHistoryVerifier.compare(writers: [w(a, revoked: false), w(b, revoked: true)], roster: roster)
    try KeyHistoryVerifier.compare(writers: [w(a, revoked: false)], roster: roster)  // a subset is fine
    let c = Device(
      writer: WriterID("ios-2a1b2c3d-4e5f-4a6b-ac7d-9e0f1a2b3c4d")!, dwk: Ed25519.generate(),
      dak: P256.Signing.PrivateKey().publicKey.x963Representation)
    let mismatch = KeyHistoryVerifier.Alarm.rosterMismatch
    #expect(throws: mismatch(c.writer.string)) { try KeyHistoryVerifier.compare(writers: [w(c, revoked: false)], roster: roster) }
    #expect(throws: mismatch(a.writer.string)) {
      try KeyHistoryVerifier.compare(writers: [w(a, dak: b.dak, revoked: false)], roster: roster)
    }
    #expect(throws: mismatch(b.writer.string)) { try KeyHistoryVerifier.compare(writers: [w(b, revoked: false)], roster: roster) }
    #expect(throws: mismatch(a.writer.string)) {
      try KeyHistoryVerifier.compare(
        writers: [.init(writerID: a.writer.string, publicKey: b.dwk.publicKey, dakPublicKey: a.dak, revoked: false)],
        roster: roster)
    }
  }
}
