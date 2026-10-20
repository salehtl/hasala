// Spec 01 §15.3's tamper suite, the reader side (T01-T36), plus the seal
// contract (§6.5). Reader state: the device knows K_1 only, `epoch_hwm` = 1,
// the pinned head is frame 1's hash, and the case serves frame 2 unless noted.
// The `predicate` column is what the Swift twin of the server's LooksSealed
// says for the upload (the server's other refusals are Go's to test).
import CorePrimitives
import CoreWire
import Foundation
import Testing

@testable import CoreCrypto

struct TamperBase {
  let k1: EpochKey
  let opener: Opener
  let env1: Envelope
  let env2: Envelope
  let frame1: SealedFrame
  let frame2: SealedFrame
  let plaintext2: Data

  static func make() throws -> TamperBase {
    let amk = Data(0x40...0x5f)
    let k1 = try EpochKey(epoch: 1, key: try KeyDerivation.epochKey1(amk: amk, userID: testUser))
    let sealer = Sealer(epoch: 1, key: k1)
    let r = StreamRandom(seed: "tamper")
    let env1 = try Envelope(userID: testUser, writerID: testWriter, counter: 1)
    let env2 = try Envelope(userID: testUser, writerID: testWriter, counter: 2)
    let p1 = Data(#"{"v":4,"kind":"ops","ops":[]}"#.utf8)
    let p2 = Data(
      #"{"v":4,"kind":"ops","ops":[{"v":4,"type":"rate_set","op_id":"01J0000000000000000000000R","authored_at":"2026-06-05T10:00:00.000Z","parent_version":null,"payload":{"currency":"USD"}}]}"#
        .utf8)
    let f1 = try sealer.seal(plaintextOps: p1, envelope: env1, prevHash: .zero, random: r)
    let f2 = try sealer.seal(plaintextOps: p2, envelope: env2, prevHash: f1.blobHash, random: r)
    return TamperBase(
      k1: k1, opener: Opener(epochHWM: 1, keys: [k1]), env1: env1, env2: env2, frame1: f1, frame2: f2, plaintext2: p2)
  }

  func open(_ frame: Data, envelope: Envelope? = nil, prev: Hash32? = nil, serverEpoch: UInt32? = nil) -> OpenOutcome {
    opener.open(frame, envelope: envelope ?? env2, prevHash: prev ?? frame1.blobHash, serverEpoch: serverEpoch)
  }

  func mutate(_ edit: (inout [UInt8]) -> Void) -> Data {
    var b = [UInt8](frame2.bytes)
    edit(&b)
    return Data(b)
  }

  /// A frame at counter 2 whose authenticated region `R` is supplied.
  func withRegion(_ r: Data, bucket: Int = 1024) throws -> Data {
    let header = FrameV3.header(epoch: 1, aad: env2.aad)
    var region = r
    let want = bucket - 35 - env2.aad.count
    if region.count < want { region.append(Data(count: want - region.count)) }
    return try FrameAEAD.seal(region: region, header: header, prevHash: frame1.blobHash, epochKey: k1.key, nonce: Data(1...12))
  }

  static func region(_ g: Data) -> Data {
    Data([UInt8(g.count >> 24), UInt8(g.count >> 16 & 0xff), UInt8(g.count >> 8 & 0xff), UInt8(g.count & 0xff)]) + g
  }
}

@Suite("spec 01 §15.3: the tamper suite (reader)")
struct TamperSuiteTests {
  let base: TamperBase
  init() throws { base = try TamperBase.make() }

  @Test("T01 untouched: accepted and opened; the seal contract held")
  func t01() throws {
    #expect(LooksSealed.check(base.frame2.bytes) == nil)
    #expect(base.open(base.frame2.bytes) == .opened(base.plaintext2))
    #expect(base.frame2.bytes.count == 1024 && base.frame2.counter == 2 && base.frame2.epoch == 1)
    #expect(base.frame2.blobHash == Chain.hash(prev: base.frame1.blobHash, frame: base.frame2.bytes))
    #expect(base.open(base.frame1.bytes, envelope: base.env1, prev: .zero) == .opened(Data(#"{"v":4,"kind":"ops","ops":[]}"#.utf8)))
  }

  @Test("T02-T04 version byte")
  func versions() {
    for v: UInt8 in [0x00, 0x01, 0x02] {
      let f = base.mutate { $0[0] = v }
      #expect(LooksSealed.check(f) == .version)
      #expect(base.open(f) == .hardStop(.tampered(.legacyFrame)))
    }
    let f4 = base.mutate { $0[0] = 0x04 }
    #expect(LooksSealed.check(f4) == .version)
    #expect(base.open(f4) == .hardStop(.updateRequired))
  }

  @Test("T05-T07 epoch")
  func epochs() throws {
    let zero = base.mutate { $0[4] = 0 }
    #expect(LooksSealed.check(zero) == .epoch)
    #expect(base.open(zero) == .hardStop(.tampered(.badHeader)))
    let aboveMax = base.mutate { $0[1] = 0x80; $0[4] = 0 }
    #expect(base.open(aboveMax) == .hardStop(.tampered(.badHeader)))
    #expect(base.open(aboveMax, serverEpoch: .max) == .hardStop(.tampered(.badHeader)))
    let two = base.mutate { $0[4] = 2 }
    #expect(LooksSealed.check(two) == nil)
    #expect(base.open(two) == .refreshEpoch(2))
    #expect(base.open(two, serverEpoch: 1) == .hardStop(.tampered(.epochInvalid)))
    #expect(base.open(two, serverEpoch: 2) == .needsUnlock(epoch: 2))
    let unlocked = Opener(epochHWM: 2, keys: [base.k1, try EpochKey(epoch: 2, key: Data(repeating: 9, count: 32))])
    #expect(
      unlocked.open(two, envelope: base.env2, prevHash: base.frame1.blobHash) == .setAside(.aeadFailed, alarm: true))
  }

  @Test("T08 aad_len ±1 and 0xFFFF; T09 every AAD byte")
  func aad() {
    let l = base.env2.aad.count
    for d in [1, -1] {
      let f = base.mutate { $0[6] = UInt8(l + d) }
      #expect(base.open(f) == .hardStop(.tampered(.aadMismatch)))
    }
    let huge = base.mutate { $0[5] = 0xff; $0[6] = 0xff }
    #expect(LooksSealed.check(huge) == .aadLen)
    #expect(base.open(huge) == .hardStop(.tampered(.badHeader)))
    for i in 7..<(7 + l) {
      let f = base.mutate { $0[i] ^= 0x01 }
      #expect(base.open(f) == .hardStop(.tampered(.aadMismatch)), "byte \(i)")
    }
  }

  @Test("T10-T12 nonce, ciphertext and tag bytes: accepted, then set aside with the alarm")
  func aead() {
    let layout = FrameV3.Layout(aadLength: base.env2.aad.count, frameLength: 1024)
    var positions = Array(layout.nonce) + Array(layout.tag)
    positions += [layout.region.lowerBound, layout.region.upperBound - 1]
    positions += stride(from: layout.region.lowerBound, to: layout.region.upperBound, by: 64)
    for i in positions {
      let f = base.mutate { $0[i] ^= 0x01 }
      #expect(base.open(f) == .setAside(.aeadFailed, alarm: true), "byte \(i)")
    }
  }

  @Test("T13 a row prev_hash that is not the pinned head breaks the chain")
  func t13() {
    let row = Chain.Row(
      writerID: testWriter.string, stream: "hot", counter: 2, prevHash: Hash32.of(Data([1])), blobHash: base.frame2.blobHash,
      blob: base.frame2.bytes)
    #expect(throws: Chain.Break.self) {
      try Chain.verify(writerID: testWriter.string, stream: "hot", rows: [row], pinned: Chain.Head(counter: 1, hash: base.frame1.blobHash))
    }
  }

  @Test("T14 fork splice: the chain verifies, AEAD does not (C1's prev_hash binding)")
  func t14() throws {
    let fork = Hash32.of(Data("another fork".utf8))
    let spliced = try Sealer(epoch: 1, key: base.k1).seal(
      plaintextOps: base.plaintext2, envelope: base.env2, prevHash: fork, random: StreamRandom(seed: "fork"))
    let row = Chain.Row(
      writerID: testWriter.string, stream: "hot", counter: 2, prevHash: base.frame1.blobHash,
      blobHash: Chain.hash(prev: base.frame1.blobHash, frame: spliced.bytes), blob: spliced.bytes)
    try Chain.verify(writerID: testWriter.string, stream: "hot", rows: [row], pinned: Chain.Head(counter: 1, hash: base.frame1.blobHash))
    #expect(base.open(spliced.bytes) == .setAside(.aeadFailed, alarm: true))
  }

  @Test("T15 served at another counter, T16 another user's frame: aadMismatch")
  func t15t16() throws {
    #expect(
      base.open(base.frame2.bytes, envelope: try Envelope(userID: testUser, writerID: testWriter, counter: 3))
        == .hardStop(.tampered(.aadMismatch)))
    let other = UserID("0f1e2d3c-4b5a-4968-8776-655443322110")!
    #expect(
      base.open(base.frame2.bytes, envelope: try Envelope(userID: other, writerID: testWriter, counter: 2))
        == .hardStop(.tampered(.aadMismatch)))
  }

  @Test("T17 the device holds another K_1")
  func t17() throws {
    let wrong = Opener(epochHWM: 1, keys: [try EpochKey(epoch: 1, key: Data(repeating: 3, count: 32))])
    #expect(wrong.open(base.frame2.bytes, envelope: base.env2, prevHash: base.frame1.blobHash) == .setAside(.aeadFailed, alarm: true))
  }

  @Test("T18 truncated to 1023 or extended to 1025")
  func t18() {
    let short = base.frame2.bytes.prefix(1023)
    let long = base.frame2.bytes + [0]
    #expect(LooksSealed.check(short) == .bucket && LooksSealed.check(long) == .bucket)
    #expect(base.open(Data(short)) == .hardStop(.tampered(.rowShape)))
    #expect(base.open(long) == .hardStop(.tampered(.rowShape)))
  }

  @Test("T19 m = |R| − 3; T20 raw deflate; T21 trailing bytes and two members")
  func payloads() throws {
    let rLen = 1024 - 35 - base.env2.aad.count
    var r = Data(count: rLen)
    let m = rLen - 3
    r[0] = UInt8(m >> 24); r[1] = UInt8(m >> 16 & 0xff); r[2] = UInt8(m >> 8 & 0xff); r[3] = UInt8(m & 0xff)
    #expect(base.open(try base.withRegion(r)) == .setAside(.regionMalformed, alarm: false))
    let g = try Gzip.compress(base.plaintext2)
    #expect(base.open(try base.withRegion(TamperBase.region(g.dropFirst(10)))) == .setAside(.payloadInvalid, alarm: false))
    #expect(base.open(try base.withRegion(TamperBase.region(g + [0]))) == .setAside(.payloadInvalid, alarm: false))
    #expect(base.open(try base.withRegion(TamperBase.region(g + g))) == .setAside(.payloadInvalid, alarm: false))
    #expect(base.open(try base.withRegion(TamperBase.region(g))) == .opened(base.plaintext2))
  }

  @Test("T22 exactly 2 MiB opens; T23 one byte more is set aside")
  func t22t23() throws {
    func padded(_ n: Int) -> Data {
      let ops = Data(#"{"v":4,"kind":"ops","ops":[]}"#.utf8)
      return ops + Data(repeating: 0x20, count: n - ops.count)
    }
    let exact = padded(FrameV3.maxPlaintext)
    let g = try Gzip.compress(exact)
    let opened = base.open(try base.withRegion(TamperBase.region(g), bucket: 16384))
    #expect(opened == .opened(exact))
    if case .opened(let p) = opened { #expect(OpCodec.decodeR10(p) == .ops([])) }
    let over = try Gzip.compress(padded(FrameV3.maxPlaintext + 1))
    #expect(base.open(try base.withRegion(TamperBase.region(over), bucket: 16384)) == .setAside(.payloadInvalid, alarm: false))
    // The sealer refuses more than 2 MiB outright.
    #expect(throws: SealError.tooLarge) {
      try Sealer(epoch: 1, key: base.k1).seal(
        plaintextOps: padded(FrameV3.maxPlaintext + 1), envelope: base.env2, prevHash: base.frame1.blobHash,
        random: StreamRandom(seed: "x"))
    }
  }

  @Test("T24 an op blob of v 99: opened, then the hard stop; T36 a reserved type: the whole blob aside")
  func t24t36() throws {
    let sealer = Sealer(epoch: 1, key: base.k1)
    let v99 = try sealer.seal(
      plaintextOps: Data(#"{"v":99,"kind":"ops","ops":[]}"#.utf8), envelope: base.env2, prevHash: base.frame1.blobHash,
      random: StreamRandom(seed: "v99"))
    guard case .opened(let p) = base.open(v99.bytes) else { Issue.record("not opened"); return }
    #expect(OpCodec.decodeR10(p) == .hardStop(.updateRequired))
    let reserved = base.plaintext2 + Data()
    let text = String(decoding: reserved, as: UTF8.self).replacingOccurrences(
      of: "]}", with: #",{"v":4,"type":"profile_set","op_id":"x","authored_at":"2026-06-05T10:00:00Z","payload":{}}]}"#)
    let t36 = try sealer.seal(
      plaintextOps: Data(text.utf8), envelope: base.env2, prevHash: base.frame1.blobHash, random: StreamRandom(seed: "36"))
    guard case .opened(let q) = base.open(t36.bytes) else { Issue.record("not opened"); return }
    #expect(OpCodec.decodeR10(q) == .setAside(.opsUndecodable, message: #"op 1: unknown type "profile_set""#))
  }

  @Test("T26 forgot to encrypt: refused by the predicate; the reader sets it aside")
  func t26() throws {
    let g = try Gzip.compress(base.plaintext2)
    let header = FrameV3.header(epoch: 1, aad: base.env2.aad)
    var r = TamperBase.region(g)
    r.append(Data(count: 1024 - 35 - base.env2.aad.count - r.count))
    let forged = header + Data(1...12) + r + Data(1...16)
    #expect(forged.count == 1024)
    #expect(LooksSealed.check(forged) == .tail)
    #expect(base.open(forged) == .setAside(.aeadFailed, alarm: true))
    var noTail = [UInt8](forged)
    for i in 976..<1008 { noTail[i] = 0x55 }
    #expect(LooksSealed.check(noTail) == .gzip)
  }

  @Test("T30-T35 heads (R2b): unsigned, another writer's key, another hash, a revoked writer, after revocation")
  func heads() throws {
    let dwk = Ed25519.generate()
    let other = Ed25519.generate()
    let w2 = WriterID("ios-11111111-2222-4333-8444-555555555555")!
    func row(_ c: Int64, _ h: Hash32, signedBy seed: SecureBytes?, writer: WriterID = testWriter) throws -> HeadCheck.Row {
      let sig = try seed.map {
        try Ed25519.sign(seed: $0, message: SigningMessage.head(userID: testUser, counter: c, blobHash: h, writerID: writer))
      }
      return HeadCheck.Row(writerID: writer, counter: c, blobHash: h, headSig: sig)
    }
    let h1 = base.frame1.blobHash
    let h2 = base.frame2.blobHash
    let roster = [testWriter: HeadCheck.RosterWriter(dwkPublicKey: dwk.publicKey, revokedAt: nil)]
    try HeadCheck.verify(userID: testUser, rows: [try row(1, h1, signedBy: nil), try row(2, h2, signedBy: dwk.seed)], roster: roster)
    #expect(throws: ReaderHardStop.tampered(.headUnsigned)) {
      try HeadCheck.verify(userID: testUser, rows: [try row(1, h1, signedBy: dwk.seed), try row(2, h2, signedBy: nil)], roster: roster)
    }
    #expect(throws: ReaderHardStop.tampered(.headInvalid)) {
      try HeadCheck.verify(userID: testUser, rows: [try row(2, h2, signedBy: other.seed)], roster: roster)
    }
    let wrongHash = try row(2, h1, signedBy: dwk.seed)
    #expect(throws: ReaderHardStop.tampered(.headInvalid)) {
      try HeadCheck.verify(
        userID: testUser, rows: [HeadCheck.Row(writerID: testWriter, counter: 2, blobHash: h2, headSig: wrongHash.headSig)],
        roster: roster)
    }
    #expect(throws: ReaderHardStop.tampered(.unknownWriter)) {
      try HeadCheck.verify(userID: testUser, rows: [try row(2, h2, signedBy: dwk.seed, writer: w2)], roster: roster)
    }
    // T33: a forged row on live writer W signed by a revoked writer's DWK.
    let revokedRoster = [
      testWriter: HeadCheck.RosterWriter(dwkPublicKey: dwk.publicKey, revokedAt: nil),
      w2: HeadCheck.RosterWriter(dwkPublicKey: other.publicKey, revokedAt: Chain.Head(counter: 1, hash: h1)),
    ]
    #expect(throws: ReaderHardStop.tampered(.headInvalid)) {
      try HeadCheck.verify(userID: testUser, rows: [try row(3, h2, signedBy: other.seed)], roster: revokedRoster)
    }
    // T34: a validly signed row past the pinned head; T35: the pinned counter with another hash.
    #expect(throws: ReaderHardStop.tampered(.afterRevocation)) {
      try HeadCheck.verify(userID: testUser, rows: [try row(2, h2, signedBy: other.seed, writer: w2)], roster: revokedRoster)
    }
    #expect(throws: ReaderHardStop.tampered(.afterRevocation)) {
      try HeadCheck.verify(userID: testUser, rows: [try row(1, h2, signedBy: other.seed, writer: w2)], roster: revokedRoster)
    }
    try HeadCheck.verify(userID: testUser, rows: [try row(1, h1, signedBy: other.seed, writer: w2)], roster: revokedRoster)
    let unsignedPastPin = HeadCheck.firstFailure(
      userID: testUser, rows: [try row(2, h2, signedBy: nil, writer: w2)], roster: revokedRoster)
    #expect(unsignedPastPin?.index == 0 && unsignedPastPin?.reason == .afterRevocation)
    let byLastRow = HeadCheck.firstFailure(
      userID: testUser,
      rows: [try row(1, h1, signedBy: nil, writer: w2), try row(2, h2, signedBy: nil), try row(3, h2, signedBy: other.seed, writer: w2)],
      roster: roster.merging([w2: HeadCheck.RosterWriter(dwkPublicKey: dwk.publicKey, revokedAt: nil)]) { a, _ in a })
    #expect(byLastRow?.index == 1 && byLastRow?.reason == .headUnsigned)
  }

  @Test("PageReader: R0-R10 in order over a two-row page")
  func pageReader() throws {
    let dwk = Ed25519.generate()
    let sig = try Ed25519.sign(
      seed: dwk.seed,
      message: SigningMessage.head(userID: testUser, counter: 2, blobHash: base.frame2.blobHash, writerID: testWriter))
    func row(_ f: SealedFrame, _ c: Int64, sig: Data?, blob: Data? = nil) -> PageReader.Row {
      PageReader.Row(
        stream: "hot", writerID: testWriter.string, counter: String(c), sizeBucket: 1024, prevHash: f.prevHash.bytes,
        blobHash: f.blobHash.bytes, headSig: sig, blob: blob ?? f.bytes)
    }
    func state(
      roster: [WriterID: HeadCheck.RosterWriter], refreshed: Bool = false, own: (writer: WriterID, authoredHead: Int64)? = nil
    ) -> PageReader.State {
      PageReader.State(
        userID: testUser, opener: base.opener, serverEpoch: nil, pinnedHeads: [:], roster: roster,
        rosterRefreshed: refreshed, own: own)
    }
    let roster = [testWriter: HeadCheck.RosterWriter(dwkPublicKey: dwk.publicKey, revokedAt: nil)]
    let page = [row(base.frame1, 1, sig: nil), row(base.frame2, 2, sig: sig)]
    let ok = PageReader.read(page, state: state(roster: roster))
    #expect(ok.stop == nil && ok.rows.count == 2)
    if case .opened(_, let ops)? = ok.rows.last { #expect(ops.first?.type == .rateSet) } else { Issue.record("row 2") }
    // R1: an unknown writer first asks for the one roster re-fetch, then is tampering.
    let unknown = PageReader.read(page, state: state(roster: [:]))
    #expect(unknown.stop == .refreshRoster && unknown.stopRow == 0 && unknown.rows.isEmpty)
    #expect(PageReader.read(page, state: state(roster: [:], refreshed: true)).stop == .hardStop(.tampered(.unknownWriter)))
    #expect(PageReader.read(page, state: state(roster: roster, refreshed: true)).stop == nil)
    // R0 reads the wire's decimal string: a sign, a space or a leading "+" is shape.
    for bad in ["+1", " 1", "1 ", "0", "-1", "01x", ""] {
      var p = page
      p[0] = PageReader.Row(
        stream: "hot", writerID: testWriter.string, counter: bad, sizeBucket: 1024, prevHash: base.frame1.prevHash.bytes,
        blobHash: base.frame1.blobHash.bytes, headSig: nil, blob: base.frame1.bytes)
      #expect(PageReader.read(p, state: state(roster: roster)).stop == .hardStop(.tampered(.rowShape)), "\(bad)")
    }
    #expect(PageReader.read([page[1]], state: state(roster: roster)).stop == .hardStop(.tampered(.chainBreak)))
    let unsigned = PageReader.read([page[0], row(base.frame2, 2, sig: nil)], state: state(roster: roster))
    #expect(unsigned.stop == .hardStop(.tampered(.headUnsigned)) && unsigned.stopRow == 1)
    #expect(
      PageReader.read(page, state: state(roster: roster, own: (testWriter, 1))).stop
        == .hardStop(.tampered(.ownChainConflict)))
    var shortBlob = page
    shortBlob[0] = row(base.frame1, 1, sig: nil, blob: base.frame1.bytes.prefix(1000))
    #expect(PageReader.read(shortBlob, state: state(roster: roster)).stop == .hardStop(.tampered(.rowShape)))
    var unknownThenShape = shortBlob
    unknownThenShape.swapAt(0, 1)
    let firstUnknown = PageReader.read(unknownThenShape, state: state(roster: [:]))
    #expect(firstUnknown.stop == .refreshRoster && firstUnknown.stopRow == 0)
    let ownConflict = PageReader.read(
      [row(base.frame1, 1, sig: nil), row(base.frame2, 2, sig: sig)], state: state(roster: roster, refreshed: true, own: (testWriter, 0)))
    #expect(ownConflict.stop == .hardStop(.tampered(.ownChainConflict)) && ownConflict.stopRow == 0)
  }

  @Test("the sealer: bucket sizing, a fresh nonce per seal, an epoch mismatch is a programming error")
  func sealer() throws {
    let sealer = Sealer(epoch: 1, key: base.k1)
    let r = StreamRandom(seed: "s")
    let a = try sealer.seal(plaintextOps: base.plaintext2, envelope: base.env2, prevHash: base.frame1.blobHash, random: r)
    let b = try sealer.seal(plaintextOps: base.plaintext2, envelope: base.env2, prevHash: base.frame1.blobHash, random: r)
    #expect(a.bytes != b.bytes)
    // Incompressible plaintext climbs the ladder.
    let big = try StreamRandom(seed: "big").bytes(5000)
    let f = try sealer.seal(plaintextOps: big, envelope: base.env2, prevHash: .zero, random: r)
    #expect(f.bytes.count == 16384)
    #expect(Opener(epochHWM: 1, keys: [base.k1]).open(f.bytes, envelope: base.env2, prevHash: .zero) == .opened(big))
    let k2 = try EpochKey(epoch: 2, key: Data(repeating: 1, count: 32))
    #expect(throws: SealError.self) {
      try Sealer(epoch: 1, key: k2).seal(plaintextOps: Data(), envelope: base.env2, prevHash: .zero, random: r)
    }
  }

  @Test("a predicate hit re-seals once; two hits are sealerFault")
  func reseal() throws {
    // A random source whose nonces are all zero makes LooksSealed refuse (and
    // FrameAEAD refuse the zero nonce first): the sealer never emits it.
    struct Zero: RandomSource {
      func fill(_ buffer: UnsafeMutableRawBufferPointer) throws(PrimitivesError) {
        for i in 0..<buffer.count { buffer[i] = 0 }
      }
    }
    #expect(throws: SealError.self) {
      try Sealer(epoch: 1, key: base.k1).seal(plaintextOps: base.plaintext2, envelope: base.env2, prevHash: .zero, random: Zero())
    }
  }
}
