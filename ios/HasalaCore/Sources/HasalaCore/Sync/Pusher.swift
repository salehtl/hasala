// Push (spec 04 §5.5; spec 01 §7.1, §8.4 R-OUT-1…6).
//
//   0  latched → nothing
//   1  an in-flight batch exists → resend THOSE bytes and THAT head_sig (never re-seal, never re-sign)
//   4  pending ops → blobs (≤ 64 KiB of ops each, ≤ 8 blobs, ≤ 12 MiB), each sealed at the next
//      counter after the previous blob (LooksSealed inside the Sealer; a second hit = sealer_fault),
//      head_sig = Ed25519(DWK, HeadMessage(last row)), all persisted in ONE transaction
//   5  POST /api/v1/sync
//   6  200 → one transaction: inflight + their pending ops gone, authored head moved
//   7  loop while ops remain
//
// Steps 2 (pre-push pull) and the self-pull are the engine's. Step 3 (the
// writer checkpoint op) needs CoreDomain's `OpAuthor.writerCheckpoint`:
// TODO(WS-10/WS-16) — until it exists no checkpoint is authored, and I11 is
// not checked (CoreInvariants is not built either).
import CoreAuth
import CoreCrypto
import CoreJSON
import CorePrimitives
import CoreStore
import CoreTime
import CoreWire
import Foundation

public struct PushSummary: Sendable, Hashable {
  public var batches = 0
  public var blobs = 0
  public var opsAcknowledged = 0

  mutating func add(_ other: PushSummary) {
    batches += other.batches
    blobs += other.blobs
    opsAcknowledged += other.opsAcknowledged
  }
}

enum Pusher {
  static let maxUploadBlobs = 8
  static let maxUploadBytes = 12 * 1024 * 1024
  static let maxBlobPlaintext = 64 * 1024
  static let maxResends = 3

  /// Step 1 alone: resends the in-flight batch, if any, byte-identical. The
  /// engine's reconcile stage runs this before its pre-push pull; it never
  /// seals anything new.
  static func reconcile(_ ctx: SyncContext) async throws(SyncStop) -> PushSummary {
    var summary = PushSummary()
    let state = try ctx.storeCall { () throws(StoreError) in try ctx.store.syncState() }
    if let latch = state.latch { throw .latched(latch) }
    let inflight = try ctx.storeCall { () throws(StoreError) in try ctx.store.inflight() }
    if !inflight.isEmpty {
      summary.opsAcknowledged += try await send(inflight, ctx: ctx)
      summary.batches += 1
      summary.blobs += inflight.count
    }
    return summary
  }

  /// Steps 1 and 4-7. Only `SyncEngine` calls this (one run at a time): two
  /// concurrent flushes could seal the same pending op twice.
  static func flush(
    _ ctx: SyncContext, deadline: ContinuousClock.Instant?, beforeBatch: @Sendable () async -> Void = {}
  ) async throws(SyncStop) -> PushSummary {
    var summary = try await reconcile(ctx)
    // 4-7
    while true {
      if let deadline, ContinuousClock.now >= deadline { return summary }
      try Task.checkCancellation(or: .cancelled)
      let pending = try ctx.storeCall { () throws(StoreError) in try ctx.store.pendingOps() }
      guard !pending.isEmpty else { return summary }
      await beforeBatch()
      let inflight = try buildBatch(pending, ctx: ctx)
      try ctx.storeCall { () throws(StoreError) in try ctx.store.persistBatch(inflight) }
      summary.opsAcknowledged += try await send(inflight, ctx: ctx)
      summary.batches += 1
      summary.blobs += inflight.count
    }
  }

  // MARK: Build (step 4)

  /// Decodes a stored op (its canonical JSON object) back into an `Op`,
  /// re-validating it on the way.
  static func decodeStored(_ p: PendingOp) throws(SyncStop) -> Op {
    var blob = Data(#"{"v":4,"kind":"ops","ops":["#.utf8)
    blob.append(p.opJSON)
    blob.append(contentsOf: Array("]}".utf8))
    guard let ops = try? OpCodec.decodeBlobOps(blob), ops.count == 1 else {
      throw .latched(.hardStop)
    }
    return ops[0]
  }

  static func buildBatch(_ pending: [PendingOp], ctx: SyncContext) throws(SyncStop) -> [InflightBlob] {
    let state = try ctx.storeCall { () throws(StoreError) in try ctx.store.syncState() }
    let keys = try ctx.epochKeys(upTo: state.epochHWM)
    guard let key = keys.first(where: { $0.epoch == state.epochHWM }) else {
      throw .needsUnlock(epoch: state.epochHWM)
    }
    let sealer = Sealer(epoch: state.epochHWM, key: key)
    let seed = try ctx.writerSeed()
    defer { seed.wipe() }

    // Pack ops into blob plaintexts.
    var groups: [[PendingOp]] = []
    var current: [PendingOp] = []
    var currentOps: [Op] = []
    var plaintexts: [Data] = []
    var total = 0
    func close() throws(SyncStop) {
      guard !current.isEmpty else { return }
      let bytes: [UInt8]
      do { bytes = try OpCodec.encodeBlobOps(currentOps) } catch { throw .latched(.hardStop) }
      groups.append(current)
      plaintexts.append(Data(bytes))
      current = []
      currentOps = []
    }
    // A blob's plaintext is `{"v":N,"kind":"ops","ops":[` + the ops' canonical
    // JSON joined by commas + `]}`: its size is known from the stored JSON
    // without re-encoding the growing blob for every op.
    let wrapper = 30
    var size = wrapper
    for p in pending {
      let op = try decodeStored(p)
      let alone = op.type.travelsAlone || currentOps.contains { $0.type.travelsAlone }
      if !current.isEmpty, alone || size + p.opJSON.count + 1 > maxBlobPlaintext {
        try close()
        size = wrapper
        if groups.count == maxUploadBlobs { break }
      }
      size += p.opJSON.count + (current.isEmpty ? 0 : 1)
      current.append(p)
      currentOps.append(op)
    }
    if groups.count < maxUploadBlobs { try close() }

    // Seal, chain, sign.
    let batchID = ULID.make(clock: ctx.clock, random: ctx.random)
    let now = ctx.clock.nowMs()
    var prev = state.authoredHead.hash
    var counter = state.authoredHead.counter
    var sealed: [(SealedFrame, [String])] = []
    for (i, plaintext) in plaintexts.enumerated() {
      counter += 1
      let envelope: Envelope
      do { envelope = try Envelope(userID: ctx.userID, writerID: ctx.writerID, counter: counter) } catch {
        throw .latched(.hardStop)
      }
      let frame: SealedFrame
      do {
        frame = try sealer.seal(plaintextOps: plaintext, envelope: envelope, prevHash: prev, random: ctx.random)
      } catch {
        switch error {
        case .sealerFault:
          // Persisted, so later runs do not seal (and fault) again (§5.5).
          throw latch(ctx, .sealerFault, alarm: true)
        default: throw .latched(.hardStop)
        }
      }
      total += frame.bytes.count
      if total > maxUploadBytes, !sealed.isEmpty {
        counter -= 1
        break
      }
      sealed.append((frame, groups[i].map(\.opID)))
      prev = frame.blobHash
    }
    guard let last = sealed.last?.0 else { throw .latched(.hardStop) }
    let message = SigningMessage.head(
      userID: ctx.userID, counter: last.counter, blobHash: last.blobHash, writerID: ctx.writerID)
    let headSig: Data
    do { headSig = try DWK.sign(seed: seed, message: message) } catch { throw .latched(.hardStop) }
    return sealed.enumerated().map { i, s in
      InflightBlob(
        counter: s.0.counter, batchID: batchID, prevHash: s.0.prevHash, blobHash: s.0.blobHash,
        sizeBucket: s.0.bytes.count, blob: s.0.bytes, opIDs: s.1, headSig: i == sealed.count - 1 ? headSig : nil,
        createdAt: now)
    }
  }

  // MARK: Send (steps 5-6 and the response table)

  /// Uploads `batch` (the stored bytes and head_sig) and applies §5.5's table.
  /// Returns how many ops were acknowledged.
  static func send(_ batch: [InflightBlob], ctx: SyncContext) async throws(SyncStop) -> Int {
    var remaining = batch
    var acked = 0
    guard let headSig = batch.last?.headSig else { throw .latched(.hardStop) }
    for _ in 0..<maxResends {
      let bearer = try ctx.bearer()
      let wire = remaining.map {
        InflightBlobWire(
          counter: $0.counter, prevHash: $0.prevHash, blobHash: $0.blobHash, sizeBucket: $0.sizeBucket, blob: $0.blob)
      }
      let response: APIResponse
      do {
        response = try await ctx.client.upload(
          UploadRequest(writerID: ctx.writerID, blobs: wire, headSig: headSig), bearer: bearer)
      } catch {
        throw SyncStop.read(error)
      }
      if response.status == 200 {
        guard let ok = try? JSONDecoder().decode(UploadResponse.self, from: response.body),
          ok.seqs.count == remaining.count
        else { throw .protocolError("upload answer") }
        return try acked + acknowledge(remaining, ctx: ctx)
      }
      let f = APIFailure.from(response)
      switch (f.status, f.code) {
      case (409, "conflict") where f.detail.contains(partiallyAppliedDetail):
        let head = try await readOwnHead(ctx, bearer: bearer)
        let stored = remaining.filter { $0.counter <= head.counter }
        for s in stored {
          guard let h = head.hashes[s.counter], h == s.blobHash else { throw .halted(.tamperedResend) }
        }
        acked += try acknowledge(stored, ctx: ctx)
        remaining = remaining.filter { $0.counter > head.counter }
        if remaining.isEmpty { throw latch(ctx, .chainBreak) }
        continue
      case (409, "chain_break"):
        try? ctx.store.setLatch(.chainBreak)
        throw .halted(.tampered(.ownChainConflict))
      case (409, "stale_epoch"):
        // TODO(post-beta, 01 R-OUT-4): obtain the new epoch key, check the own
        // head shows these counters unapplied, re-seal from pending_ops and re-sign.
        // Epoch rotation is not mounted in the beta (`02` §10.6).
        let e = UInt32(f.detail.split(separator: " ").last.flatMap { UInt32($0) } ?? 0)
        throw .needsUnlock(epoch: e)
      case (400, "bad_signature"):
        throw latch(ctx, .hardStop, alarm: true)
      case (400, "plaintext_refused"):
        throw latch(ctx, .sealerFault, alarm: true)
      case (400, _), (413, "too_large"):
        throw latch(ctx, .hardStop)
      case (413, "account_full"):
        throw latch(ctx, .accountFull)
      default:
        throw SyncStop.common(.refused(f)) ?? .protocolError("upload refused \(f.status)")
      }
    }
    throw .protocolError("upload: too many partial resends")
  }

  /// Acknowledges `blobs` (oldest first) and returns how many ops they carried.
  static func acknowledge(_ blobs: [InflightBlob], ctx: SyncContext) throws(SyncStop) -> Int {
    guard let last = blobs.last else { return 0 }
    try ctx.storeCall { () throws(StoreError) in
      try ctx.store.acknowledge(
        counters: blobs.map(\.counter), head: Chain.Head(counter: last.counter, hash: last.blobHash),
        at: ctx.clock.nowMs())
    }
    return blobs.reduce(0) { $0 + $1.opIDs.count }
  }

  /// Persists `latch` (best effort) and returns the stop that reports it.
  static func latch(_ ctx: SyncContext, _ latch: OutboxLatch, alarm: Bool = false) -> SyncStop {
    try? ctx.store.setLatch(latch)
    return .latched(latch, alarm: alarm)
  }

  /// The own writer's stored head, by scanning `GET /sync/hashes` (spec 04
  /// §5.5 "as `readChainHead` does"; OQ-3 keeps the scan). Also returns every
  /// own counter's stored hash, for the resend check.
  static func readOwnHead(_ ctx: SyncContext, bearer: String) async throws(SyncStop)
    -> (counter: Int64, hashes: [Int64: Hash32])
  {
    var after: Int64 = 0
    var top: Int64 = 0
    var hashes: [Int64: Hash32] = [:]
    while true {
      let page: HashesPage
      do { page = try await ctx.client.hashes(after: after, bearer: bearer) } catch { throw SyncStop.read(error) }
      for h in page.hashes where h.writer_id == ctx.writerID.string {
        guard let c = Int64(h.writer_counter), let bh = Hash32(hex: h.blob_hash) else {
          throw .protocolError("hashes row")
        }
        hashes[c] = bh
        top = max(top, c)
      }
      guard let next = Int64(page.next) else { throw .protocolError("hashes next") }
      if page.complete || page.hashes.isEmpty || next <= after { break }
      after = next
    }
    return (top, hashes)
  }
}

/// A ULID (26 Crockford base32 characters: 48-bit ms time, 80 random bits).
public enum ULID {
  static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ".utf8)

  public static func make(clock: any CoreTime.Clock, random: any RandomSource) -> String {
    var bytes = [UInt8](repeating: 0, count: 16)
    let ms = UInt64(max(0, clock.nowMs()))
    for i in 0..<6 { bytes[i] = UInt8(ms >> (40 - 8 * UInt64(i)) & 0xff) }
    let r = (try? random.bytes(10)) ?? Data(count: 10)
    for i in 0..<10 { bytes[6 + i] = r[r.startIndex + i] }
    // 128 bits → 26 characters, most significant first (2 leading pad bits).
    var out: [UInt8] = []
    var acc: UInt32 = 0
    var bits = 2  // pad: 130 bits = 26 × 5
    for b in bytes {
      acc = acc << 8 | UInt32(b)
      bits += 8
      while bits >= 5 {
        bits -= 5
        out.append(alphabet[Int(acc >> UInt32(bits) & 31)])
      }
    }
    return String(decoding: out, as: UTF8.self)
  }
}
