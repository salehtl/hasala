// FakeServer: the op log (`02` #28–#30, §11). Upload in §11.1's order, pull
// and hashes with "a page never ends inside a batch" (§11.3).
import CoreAuth
import CoreCrypto
import CoreSync
import CorePrimitives
import CoreWire
import Foundation

extension FakeServer {
  static let maxPull = 500

  func upload(_ r: APIRequest) -> (APIResponse, lose: Bool) {
    guard let token = r.bearer, let sess = state.withLock({ $0.sessions[token] }), !sess.revoked else {
      return (Self.error(401, "unauthorized"), false)
    }
    guard let user = state.withLock({ $0.users[sess.userID] }), !user.deleted else {
      return (Self.error(410, "account_deleted"), false)
    }
    if user.frozen { return (Self.error(403, "account_frozen"), false) }
    // 2: shape.
    guard let b = Self.decode(r, UploadRequest.self) else { return (Self.error(400, "bad_request"), false) }
    guard b.stream == "hot" else { return (Self.error(400, "bad_stream"), false) }
    guard !b.blobs.isEmpty, b.blobs.count <= 8 else { return (Self.error(400, "bad_request"), false) }
    guard let headSig = try? Base64.decode(b.head_sig), headSig.count == 64 else {
      return (Self.error(400, "bad_signature"), false)
    }
    guard let wid = WriterID(b.writer_id) else { return (Self.error(400, "bad_writer_id"), false) }
    // 3: the session's writer.
    guard let bound = sess.writerID else { return (Self.error(403, "writer_unbound"), false) }
    guard bound == wid else { return (Self.error(403, "writer_mismatch"), false) }
    guard let writer = user.writers[wid.string] else { return (Self.error(403, "writer_unbound"), false) }
    if writer.revoked != nil { return (Self.error(403, "writer_revoked"), false) }
    // 4: keys.
    guard let keys = user.keys else { return (Self.error(403, "keys_required"), false) }
    // 5: each blob.
    var rows: [(counter: Int64, prev: Data, hash: Data, blob: Data)] = []
    for (i, x) in b.blobs.enumerated() {
      guard let blob = try? Base64.decode(x.blob), let c = Int64(x.writer_counter), c >= 1 else {
        return (Self.error(400, "bad_request", "blobs[\(i)]"), false)
      }
      guard FrameV3.isBucket(blob.count), x.size_bucket == blob.count else {
        return (Self.error(400, "bad_bucket", "blobs[\(i)]: size"), false)
      }
      if let refusal = LooksSealed.check(blob) {
        return (Self.error(400, "plaintext_refused", "blobs[\(i)]: \(refusal.rawValue)"), false)
      }
      guard let h = FrameV3.parseHeader(blob) else { return (Self.error(400, "bad_request"), false) }
      guard Int(h.epoch) == keys.current_epoch else {
        return (Self.error(409, "stale_epoch", "current epoch \(keys.current_epoch)"), false)
      }
      let layout = FrameV3.Layout(aadLength: h.aadLength, frameLength: blob.count)
      let want = Data("\(user.id.string)|hot|\(wid.string)|\(c)".utf8)
      guard Data(blob[layout.aad]) == want else { return (Self.error(400, "aad_mismatch", "blobs[\(i)]"), false) }
      guard let prev = try? Hex.decode(x.prev_hash), prev.count == 32, let hash = try? Hex.decode(x.blob_hash),
        hash.count == 32
      else { return (Self.error(400, "bad_request"), false) }
      rows.append((c, prev, hash, blob))
    }
    // Internal consistency (a client bug, 400).
    for i in rows.indices {
      if Chain.hash(prev: Hash32(rows[i].prev)!, frame: rows[i].blob).bytes != rows[i].hash {
        return (Self.error(400, "bad_request", "chain"), false)
      }
      if i > 0, rows[i].counter != rows[i - 1].counter + 1 || rows[i].prev != rows[i - 1].hash {
        return (Self.error(400, "bad_request", "chain"), false)
      }
    }
    // 6: the append.
    return state.withLock { s -> (APIResponse, Bool) in
      s.uploads += 1
      var u = s.users[user.id]!
      let own = u.log.filter { $0.writerID == wid.string }
      let head = own.last
      let headCounter = head?.counter ?? 0
      let headHash = head?.blobHash ?? Data(count: 32)
      // The head signature, over the batch's last row as recomputed here.
      let last = rows[rows.count - 1]
      let msg = SigningMessage.head(userID: u.id, counter: last.counter, blobHash: Hash32(last.hash)!, writerID: wid)
      guard Ed25519.verify(publicKey: writer.dwk, signature: headSig, message: msg) else {
        return (Self.error(400, "bad_signature", "head_sig"), false)
      }
      // Rows at or below the stored head: a byte-identical replay or a straddle.
      let stored = rows.filter { $0.counter <= headCounter }
      for x in stored {
        guard let o = own.first(where: { $0.counter == x.counter }), o.blobHash == x.hash else {
          return (Self.error(409, "chain_break"), false)
        }
      }
      if stored.count == rows.count {
        let seqs = rows.map { x in own.first { $0.counter == x.counter }!.seq }
        return (Self.ok(UploadResponse(seqs: seqs.map(String.init))), false)
      }
      if !stored.isEmpty {
        return (Self.error(409, "conflict", "oplog: this batch is partly applied already: \(partiallyAppliedDetail)"), false)
      }
      guard rows[0].counter == headCounter + 1, rows[0].prev == headHash else {
        return (Self.error(409, "chain_break"), false)
      }
      var apply = rows
      var lose = false
      if let k = s.partialApplyNextUpload {
        s.partialApplyNextUpload = nil
        apply = Array(rows.prefix(k))
        lose = true
      }
      if s.loseNextUploadResponse {
        s.loseNextUploadResponse = false
        lose = true
      }
      if !lose, s.losePullAfterNextUpload {
        s.losePullAfterNextUpload = false
        s.loseNextPull = true
      }
      var seqs: [String] = []
      for (i, x) in apply.enumerated() {
        s.seq += 1
        seqs.append(String(s.seq))
        u.log.append(
          StoredRow(
            seq: s.seq, writerID: wid.string, counter: x.counter, sizeBucket: x.blob.count, blobHash: x.hash,
            prevHash: x.prev, blob: x.blob,
            // head_sig covers the batch's last row only: a partial apply stores
            // no signature on a row it does not sign.
            headSig: i == apply.count - 1 && apply.count == rows.count ? headSig : nil))
      }
      s.users[u.id] = u
      return (Self.ok(UploadResponse(seqs: seqs)), lose)
    }
  }

  func query(_ r: APIRequest) -> (after: Int64, limit: Int)? {
    guard let q = r.path.split(separator: "?", maxSplits: 1).last, r.path.contains("?") else { return (0, 100) }
    var after: Int64 = 0
    var limit = 100
    for kv in q.split(separator: "&") {
      let p = kv.split(separator: "=", maxSplits: 1).map(String.init)
      guard p.count == 2 else { continue }
      switch p[0] {
      case "after": guard let a = Int64(p[1]) else { return nil }; after = a
      case "limit": guard let l = Int(p[1]), l >= 1 else { return nil }; limit = min(l, Self.maxPull)
      case "stream": if p[1] != "hot" { return nil }
      default: break
      }
    }
    return (after, limit)
  }

  /// The page after `after`, extended to the end of the batch it is in.
  func page(_ log: [StoredRow], after: Int64, limit: Int) -> [StoredRow] {
    var out = Array(log.filter { $0.seq > after }.prefix(limit))
    if let last = out.last, last.headSig == nil {
      for row in log where row.seq > last.seq {
        out.append(row)
        if row.headSig != nil || out.count > limit + 7 { break }
      }
    }
    return out
  }

  func pull(_ r: APIRequest, user: User) -> APIResponse {
    guard var q = query(r) else { return Self.error(400, "bad_request") }
    let (drop, flip, limitOverride) = state.withLock { ($0.dropHeadSigs, $0.flipBlobByteAtSeq, $0.pullLimitOverride) }
    if let l = limitOverride { q.limit = min(q.limit, l) }
    let rows = page(user.log, after: q.after, limit: q.limit)
    let next = rows.last?.seq ?? q.after
    let maxSeq = user.log.last?.seq ?? 0
    if q.after > maxSeq { return Self.error(409, "cursor_ahead") }
    return Self.ok(
      PullPage(
        stream: "hot",
        rows: rows.map { row in
          var blob = row.blob
          if row.seq == flip { blob[blob.count - 20] ^= 0x01 }
          return PullRow(
            seq: String(row.seq), stream: "hot", writer_id: row.writerID, writer_counter: String(row.counter),
            type_flag: "edit", size_bucket: row.sizeBucket, blob_hash: Hex.encode(row.blobHash),
            prev_hash: Hex.encode(row.prevHash), created_at: "2026-10-11T08:00:00Z", blob: Base64.encode(blob),
            head_sig: drop ? nil : row.headSig.map { Base64.encode($0) })
        }, next: String(next), complete: next >= maxSeq))
  }

  func hashes(_ r: APIRequest, user: User) -> APIResponse {
    guard let q = query(r) else { return Self.error(400, "bad_request") }
    if q.after > (user.log.last?.seq ?? 0) { return Self.error(409, "cursor_ahead") }
    let rows = page(user.log, after: q.after, limit: q.limit)
    let next = rows.last?.seq ?? q.after
    return Self.ok(
      HashesPage(
        stream: "hot",
        hashes: rows.map {
          HashEntry(
            seq: String($0.seq), writer_id: $0.writerID, writer_counter: String($0.counter),
            blob_hash: Hex.encode($0.blobHash), prev_hash: Hex.encode($0.prevHash))
        }, next: String(next), complete: next >= (user.log.last?.seq ?? 0)))
  }
}
