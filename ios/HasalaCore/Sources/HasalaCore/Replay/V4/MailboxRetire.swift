import CoreJSON
import CoreWire
import HasalaText

public enum MailboxGrant {
  public static let mailboxMarker = "/mbx-"

  public static func account(of grantID: String) -> String {
    guard let r = grantID.range(of: mailboxMarker) else { return grantID }
    return String(grantID[..<r.lowerBound])
  }

  public static func isGrantID(_ s: String) -> Bool {
    let u = Array(s.utf8)
    return (1...256).contains(u.count) && u.allSatisfy { $0 >= 0x21 && $0 <= 0x7e }
  }

  public static func isProvider(_ s: String) -> Bool { Grammar.isBank(s) }

  public static func covers(
    sourceMailbox: String?, sourceProvider: String?, grantID: String, provider: String, legacy: Bool
  ) -> Bool {
    guard let sourceMailbox, let sourceProvider, utf8Equal(sourceProvider, provider) else { return false }
    if utf8Equal(sourceMailbox, grantID) { return true }
    guard legacy else { return false }
    return utf8Equal(sourceMailbox, account(of: grantID))
  }
}

extension State {
  mutating func applyMailboxRetired(_ e: LogEntry) throws(PayloadError) {
    let p = try P.object(e.op)
    guard let grant = p["grant_id"]?.stringValue, MailboxGrant.isGrantID(grant) else {
      throw PayloadError("grant_id must be 1-256 printable ASCII bytes, got \(showValue(p["grant_id"]))")
    }
    guard let provider = p["provider"]?.stringValue, MailboxGrant.isProvider(provider) else {
      throw PayloadError("provider must match [a-z0-9_]{2,32}, got \(showValue(p["provider"]))")
    }
    let legacy = try P.boolField(p["legacy"], "legacy")
    var retired: [String] = []
    var retiredLive: [String] = []
    for (id, t) in txns where t.retiredBy == nil && t.supersededBy == nil {
      guard
        MailboxGrant.covers(
          sourceMailbox: t.sourceMailbox, sourceProvider: t.sourceProvider, grantID: grant, provider: provider,
          legacy: legacy)
      else { continue }
      txns[id]!.retiredBy = e.op.opID
      retired.append(id)
      if let w = t.mergedInto {
        txns[w]?.aliases.removeAll { utf8Equal($0.txnID, id) }
        mergedIngest[t.ingestID] = nil
        continue
      }
      retiredLive.append(id)
      if let live = liveByIngestID[t.ingestID], utf8Equal(live, id) { liveByIngestID[t.ingestID] = nil }
      unindexFingerprint(fingerprint(t), id)
      clearPending(t)
    }
    releaseAfterRetire(retiredLive, seq: e.seq)
    mailboxRetirements.append(
      MailboxRetirement(
        opID: e.op.opID, grantID: grant, provider: provider, legacy: legacy, atSeq: e.seq, txnIDs: retired))
  }
}
