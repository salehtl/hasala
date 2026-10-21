import CoreJSON
import CoreTime
import CoreWire
import HasalaText
import OrderedCollections

public enum DuplicateRules {
  public static let probableCopyWindowMs: Int64 = 10 * 60_000
  public static let transferCopyWindowMs: Int64 = 30 * 60_000
  static let transferNoticeTemplates = ["dib.transfer.v1", "dib.money-transfer.v1"]
  static let transferAlertTemplates = ["dib.account.v1"]

  enum TransferRole: Sendable, Equatable { case notice, alert }

  static func templateID(_ gate: String?) -> String? {
    guard let gate else { return nil }
    let u = Array(gate.utf8)
    return String(decoding: u[..<(u.firstIndex(of: 0x40) ?? u.count)], as: UTF8.self)
  }

  static func transferRole(_ t: Txn) -> TransferRole? {
    guard !t.unparsed, t.entryMethod == "mailbox", t.bank != nil, utf8Equal(t.direction, "debit"),
      (t.postedPrecision ?? "time") == "time", let id = templateID(t.gates?.template)
    else { return nil }
    if transferNoticeTemplates.contains(where: { utf8Equal($0, id) }) { return .notice }
    if transferAlertTemplates.contains(where: { utf8Equal($0, id) }) { return .alert }
    return nil
  }

  static func transferKey(_ t: Txn) -> String? {
    guard transferRole(t) != nil, let bank = t.bank else { return nil }
    return ["", "transfer", bank, String(t.amountMinor), t.currency].joined(separator: "\u{0}")
  }

  public static func isEvidenceHash(_ s: String) -> Bool {
    let u = Array(s.utf8)
    return u.count == 32 && u.allSatisfy { ASCII.isDigit($0) || (0x61...0x66).contains($0) }
  }

  public static func merchantKey(_ raw: String) -> String {
    var out: [UInt8] = []
    var space = false
    for b in raw.utf8 {
      if b == 0x20 || b == 0x09 || b == 0x0a || b == 0x0d {
        space = !out.isEmpty
        continue
      }
      if space { out.append(0x20) }
      space = false
      out.append((0x41...0x5a).contains(b) ? b + 0x20 : b)
    }
    return String(decoding: out, as: UTF8.self)
  }

  static func candidateKey(_ t: Txn) -> String? {
    guard !t.unparsed, t.entryMethod == "mailbox", let bank = t.bank else { return nil }
    guard (t.postedPrecision ?? "time") == "time" else { return nil }
    return [bank, String(t.amountMinor), t.currency, t.direction, t.last4, merchantKey(t.merchantRaw)].joined(separator: "\u{0}")
  }

  public static func probable(_ a: Txn, _ b: Txn) -> Bool {
    guard let ka = candidateKey(a), let kb = candidateKey(b), utf8Equal(ka, kb) else { return false }
    guard let ma = try? parseInstantMs(a.postedAt), let mb = try? parseInstantMs(b.postedAt) else { return false }
    return abs(ma - mb) <= probableCopyWindowMs
  }
}

extension State {
  mutating func detectCopy(_ id: String, _ e: LogEntry) {
    guard let b = txns[id], b.isLive else { return }
    for key in b.dedupe?.keys ?? [] {
      guard let w = byDedupeKey[key], !utf8Equal(w, id), let a = txns[w], a.isLive else { continue }
      let bWins = b.verifiedSender && !a.verifiedSender
      let winner = bWins ? id : w
      mergeRow(bWins ? w : id, into: winner, kind: "certain", op: e.op.opID)
      if bWins { carryUserEdits(from: w, to: id) }
      registerDedupeKeys(of: bWins ? w : id, to: winner)
      registerDedupeKeys(of: winner, to: winner)
      if let key = DuplicateRules.candidateKey(txns[winner]!).map(ExactKey.init(_:)),
        copyCandidates[key]?.contains(where: { utf8Equal($0, winner) }) != true
      {
        copyCandidates[key, default: []].append(winner)
      }
      detectTransferCopy(winner)
      return
    }
    registerDedupeKeys(of: id, to: id)
    if let key = DuplicateRules.candidateKey(b).map(ExactKey.init(_:)) {
      if let earlier = copyCandidates[key] {
        for oid in earlier where !utf8Equal(oid, id) {
          guard let a = txns[oid], a.isLive, !a.isHeldCopy, DuplicateRules.probable(a, b) else { continue }
          txns[id]!.copyOf = oid
          break
        }
      }
      copyCandidates[key, default: []].append(id)
    }
    detectTransferCopy(id)
  }

  mutating func detectTransferCopy(_ id: String) {
    guard let b = txns[id], let key = DuplicateRules.transferKey(b).map(ExactKey.init(_:)), let role = DuplicateRules.transferRole(b) else { return }
    let bucket = copyCandidates[key] ?? []
    if b.isLive, b.copyOf == nil, !transferPartnered(id, role: role, in: bucket), let mb = try? parseInstantMs(b.postedAt) {
      var best: (id: String, gap: Int64)?
      for oid in bucket where !utf8Equal(oid, id) {
        guard let a = txns[oid], a.isLive, !a.isHeldCopy, let r = DuplicateRules.transferRole(a), r != role,
          let ma = try? parseInstantMs(a.postedAt)
        else { continue }
        let gap = abs(ma - mb)
        guard gap <= DuplicateRules.transferCopyWindowMs, !transferPartnered(oid, role: r, in: bucket) else { continue }
        if best.map({ gap < $0.gap }) ?? true { best = (oid, gap) }
      }
      if let best { txns[id]!.copyOf = best.id }
    }
    if !bucket.contains(where: { utf8Equal($0, id) }) { copyCandidates[key, default: []].append(id) }
  }

  func transferPartnered(_ id: String, role: DuplicateRules.TransferRole, in bucket: [String]) -> Bool {
    bucket.contains { c in
      guard !utf8Equal(c, id), let t = txns[c], let of = t.copyOf, utf8Equal(of, id), t.copyDecision == nil,
        t.isLive || t.mergedInto.map({ utf8Equal($0, id) }) == true, let r = DuplicateRules.transferRole(t)
      else { return false }
      return r != role
    }
  }

  mutating func registerDedupeKeys(of id: String, to canonical: String) {
    for key in txns[id]?.dedupe?.keys ?? [] {
      if let current = byDedupeKey[key], !utf8Equal(current, id), txns[current]?.isLive == true,
        !utf8Equal(current, canonical)
      {
        continue
      }
      byDedupeKey[key] = canonical
    }
  }

  mutating func mergeRow(_ loser: String, into winner: String, kind: String, op: String) {
    guard let l = txns[loser], txns[winner] != nil else { return }
    txns[loser]!.mergedInto = winner
    txns[loser]!.mergeKind = kind
    txns[loser]!.mergeOp = op
    if let live = liveByIngestID[l.ingestID], utf8Equal(live, loser) { liveByIngestID[l.ingestID] = nil }
    mergedIngest[l.ingestID] = loser
    unindexFingerprint(fingerprint(l), loser)
    clearPending(l)
    txns[winner]!.aliases.append(
      TxnAlias(
        txnID: loser, ingestID: l.ingestID, sourceMailbox: l.sourceMailbox, sourceProvider: l.sourceProvider,
        mailboxMessageID: l.mailboxMessageID, kind: kind))
    txns[winner]!.aliases.append(contentsOf: l.aliases)
    txns[loser]!.aliases = []
    for a in l.aliases { txns[a.txnID]?.mergedInto = winner }
    if let dup = txns[winner]!.possibleDuplicateOf, utf8Equal(dup, loser) {
      txns[winner]!.possibleDuplicateOf = nil
      txns[winner]!.duplicateDisposition = nil
    }
    if let c = txns[winner]!.copyOf, utf8Equal(c, loser) {
      txns[winner]!.copyOf = nil
      txns[winner]!.copyDecision = nil
    }
    let held = txns.filter { $0.value.isLive && $0.value.copyOf.map { utf8Equal($0, loser) } == true }.map(\.key)
    for h in held { txns[h]!.copyOf = winner }
  }

  mutating func carryUserEdits(from source: String, to target: String) {
    guard let from = txns[source], let to = txns[target], !to.unparsed else { return }
    func chosen(_ c: CategorySource?) -> Bool { c?.kind == .user || c?.kind == .held }
    if chosen(from.categorySource), !chosen(to.categorySource) {
      txns[target]!.category = from.category
      txns[target]!.categorySource = from.categorySource
      txns[target]!.needsReview = from.needsReview
      if to.splits.isEmpty, !from.splits.isEmpty, from.amountMinor == to.amountMinor { txns[target]!.splits = from.splits }
    }
    for f in from.annotations.keys where to.annotations[f] == nil {
      txns[target]!.annotations[f] = from.annotations[f]
    }
  }

  func mergeWinner(_ id: String) -> String? {
    guard let t = txns[id], t.retiredBy == nil, t.supersededBy == nil, let w = t.mergedInto,
      let winner = txns[w], winner.isLive, !winner.unparsed
    else { return nil }
    return w
  }

  mutating func forwardCategory(_ id: String, seq: Int64) {
    guard let w = mergeWinner(id), let t = txns[id] else { return }
    carryUserEdits(from: id, to: w)
    let winner = txns[w]!
    if !sameText(winner.category, t.category) || winner.needsReview != t.needsReview {
      anomaly(seq, "unsupported_edit_field", "\(id) is merged into \(w), which keeps its own category")
    }
  }

  mutating func forwardSplit(_ id: String, seq: Int64) {
    guard let w = mergeWinner(id), let t = txns[id] else { return }
    carryUserEdits(from: id, to: w)
    if txns[w]!.splits != t.splits {
      anomaly(seq, "unsupported_edit_field", "\(id) is merged into \(w), which keeps its own split")
    }
  }

  mutating func forwardAnnotations(_ id: String, fields: [String], seq: Int64) {
    guard let w = mergeWinner(id), let t = txns[id] else { return }
    for f in fields {
      if txns[w]!.annotations[f] == nil {
        txns[w]!.annotations[f] = t.annotations[f]
      } else if txns[w]!.annotations[f]?.value != t.annotations[f]?.value {
        anomaly(seq, "unsupported_edit_field", "\(id) is merged into \(w), which keeps its own \(f)")
      }
    }
  }

  func sameText(_ a: String?, _ b: String?) -> Bool {
    switch (a, b) {
    case (nil, nil): return true
    case (let x?, let y?): return utf8Equal(x, y)
    default: return false
    }
  }

  mutating func flagEditOfMergedCopy(_ id: String, seq: Int64) {
    guard let w = mergeWinner(id) else { return }
    anomaly(seq, "unsupported_edit_field", "\(id) is merged into \(w): its edit stays on the merged copy")
  }

  mutating func unmergeRow(_ id: String, seq: Int64) -> Bool {
    guard let t = txns[id], let w = t.mergedInto, t.retiredBy == nil, t.supersededBy == nil else { return false }
    if let live = liveByIngestID[t.ingestID], !utf8Equal(live, id) {
      anomaly(seq, "duplicate_ingest", "\(id) cannot come back: its ingest id is live as \(live)")
      return false
    }
    txns[w]?.aliases.removeAll { utf8Equal($0.txnID, id) }
    mergedIngest[t.ingestID] = nil
    txns[id]!.mergedInto = nil
    txns[id]!.mergeKind = nil
    txns[id]!.mergeOp = nil
    liveByIngestID[t.ingestID] = id
    indexFingerprintIfAbsent(id, seq: seq)
    if txns[id]!.amountHomeMinor == nil { freezeIfPossible(id, seq: seq) }
    return true
  }

  mutating func resolveCopy(_ id: String, other: String, decision: String?, _ e: LogEntry) {
    let t = txns[id]!
    if let by = t.retiredBy ?? t.supersededBy {
      anomaly(e.seq, "duplicate_disposition_mismatch", "\(id): copy resolution on a row that left the ledger by \(by)")
      return
    }
    guard let target = t.copyOf, utf8Equal(target, other), t.mergeKind != "certain" else {
      anomaly(e.seq, "duplicate_disposition_mismatch", "\(id): copy resolution names \(other), the row names \(t.copyOf ?? "null")")
      return
    }
    switch decision {
    case "merge":
      if t.mergedInto != nil { return }
      guard txns[other]?.isLive == true, t.isLive else {
        anomaly(e.seq, "duplicate_disposition_mismatch", "\(id): \(other) is no longer a live transaction")
        return
      }
      txns[id]!.copyDecision = nil
      mergeRow(id, into: other, kind: "user", op: e.op.opID)
    case "keep_both":
      if t.mergedInto != nil, !unmergeRow(id, seq: e.seq) { return }
      txns[id]!.copyDecision = "keep_both"
    default:
      if t.mergedInto != nil, !unmergeRow(id, seq: e.seq) { return }
      txns[id]!.copyDecision = nil
    }
  }

  mutating func releaseAfterRetire(_ retired: [String], seq: Int64) {
    let gone = Set(retired)
    for id in retired {
      guard let w = txns[id] else { continue }
      let keep = w.aliases.filter { txns[$0.txnID]?.retiredBy == nil && !gone.contains($0.txnID) }
      txns[id]!.aliases = []
      var promoted: String?
      if let first = keep.first {
        let p = first.txnID
        txns[p]!.mergedInto = id
        if unmergeRow(p, seq: seq) {
          promoted = p
          carryUserEdits(from: id, to: p)
          for a in keep.dropFirst() {
            txns[a.txnID]?.mergedInto = p
            txns[p]!.aliases.append(a)
          }
        }
      }
      for (key, canonical) in byDedupeKey where utf8Equal(canonical, id) {
        byDedupeKey[key] = promoted
      }
      let held = txns.filter { $0.value.isLive && $0.value.copyOf.map { utf8Equal($0, id) } == true }.map(\.key)
      for h in held where txns[h]!.copyDecision == nil { txns[h]!.copyOf = nil }
    }
  }
}
