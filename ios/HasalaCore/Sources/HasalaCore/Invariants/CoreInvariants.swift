// CoreInvariants (Invariants/), spec 04 §2.2, §5.6-§5.7. Owner: WS-10.
//
// The state-level invariants a folded state must satisfy, checked after every
// pull (the incremental set) and by the audit re-fold (the full set). A
// `hardStop` violation halts sync with the `inconsistent` wall (04 §5.7); a
// `notice` goes to the Integrity screen and never stops anything.
//
// Implemented here (state-level): I7 one live row per ingest id, I8/I20 split
// shape and sum, I12 money shape (with `needs_review` on unparsed rows), I13
// supersede has origin, I14 anomaly kinds known and forks surfaced, I15
// unreadable set aside, I18 category-source shape, I19 no links on unparsed
// rows, I21 successor chain acyclic, I23 v4 rule shape, the fold's own index
// invariants (pending FX, fingerprints, live-by-ingest), and the audit
// comparison (I9/I10/I22: a re-fold from genesis must reproduce the witness).
//
// Not here, by design: I1-I6 and I11 are row and chain checks over what the
// server served; the reader (CoreCrypto `PageReader`, spec 01 §6.6 R0-R10) and
// the sync engine own them. I3b and I16 trivially pass (no cold stream, C5).
import CoreReplay
import CoreWire

public struct Violation: Sendable, Equatable {
  public enum Severity: String, Sendable { case hardStop = "hard_stop", notice }
  public let id: String
  public let severity: Severity
  /// Content-free: ids and kinds only, never amounts or merchants.
  public let detail: String
}

public enum Invariants {
  /// Every anomaly kind a v4 fold can raise (v3's 21, plus 03c §1.3 and 03a §3.0's).
  public static let anomalyKinds: [String] = [
    "duplicate_delivery", "invalid_op", "invalid_payload", "home_currency_reset", "rate_set_before_home_currency",
    "rate_set_for_home_currency", "rate_unset_for_home_currency", "entity_kind_mismatch", "invalid_parent", "duplicate_create",
    "nonexistent_parent", "unknown_entity", "future_parent", "duplicate_ingest", "supersede_without_origin", "split_sum",
    "edit_of_superseded", "duplicate_disposition_mismatch", "unsupported_edit_field", "possible_duplicate", "unhandled_op",
    "money_overflow", "plan_undo_mismatch",
  ]

  /// Findings per invariant are capped, with an explicit overflow line.
  public static let maxFindingsPerInvariant = 64

  /// Every state-level invariant over `s`.
  public static func check(_ s: State) -> [Violation] {
    var out: [Violation] = []
    var counts: [String: Int] = [:]
    func add(_ id: String, _ severity: Violation.Severity, _ detail: String) {
      let n = counts[id, default: 0]
      counts[id] = n + 1
      if n < maxFindingsPerInvariant {
        out.append(Violation(id: id, severity: severity, detail: detail))
      } else if n == maxFindingsPerInvariant {
        out.append(Violation(id: id, severity: severity, detail: "more findings not listed"))
      }
    }

    // I7: at most one live row per ingest id, and the index agrees.
    var live: [String: [String]] = [:]
    for (id, t) in s.txns where t.isLive { live[t.ingestID, default: []].append(id) }
    for (ingest, ids) in live.sorted(by: { $0.key < $1.key }) {
      if ids.count > 1 { add("I7_one_live_per_ingest", .hardStop, "ingest \(ingest.prefix(12)) has \(ids.count) live rows") }
      if s.liveByIngestID[ingest] != ids.first { add("I7_one_live_per_ingest", .hardStop, "index disagrees for ingest \(ingest.prefix(12))") }
    }
    for (ingest, id) in s.liveByIngestID where s.txns[id]?.isLive != true || s.txns[id]?.ingestID != ingest {
      add("I7_one_live_per_ingest", .hardStop, "index names \(id), which is not live under that ingest id")
    }

    for (id, t) in s.txns {
      // I8 / I20: parts sum exactly; never one part, never more than 16.
      if !t.splits.isEmpty {
        let sum = t.splits.reduce(Int128(0)) { $0 + Int128($1.amountMinor) }
        if sum != Int128(t.amountMinor) { add("I8_split_sum", .hardStop, "\(id): parts do not sum to the amount") }
        if t.splits.count > 16 { add("I20_split_shape_v4", .hardStop, "\(id): \(t.splits.count) parts") }
        if t.splits.contains(where: { $0.amountMinor <= 0 }) { add("I8_split_sum", .hardStop, "\(id): a part is not positive") }
      }
      // I12: money shape.
      if t.unparsed {
        if t.amountMinor != 0 || !t.currency.isEmpty || !t.direction.isEmpty || t.amountHomeMinor != nil || t.tier != "none" || !t.needsReview {
          add("I12_money_shape", .hardStop, "\(id): unparsed row carries money or left review")
        }
      } else {
        let ccy = Array(t.currency.utf8)
        if t.amountMinor <= 0 || ccy.count != 3 || !ccy.allSatisfy({ $0 >= 0x41 && $0 <= 0x5a }) || !(t.direction == "debit" || t.direction == "credit") {
          add("I12_money_shape", .hardStop, "\(id): parsed row without a positive amount, a currency and a direction")
        }
        if let h = t.amountHomeMinor, h < 0 { add("I12_money_shape", .hardStop, "\(id): negative home amount") }
      }
      // I18: category-source shape (v4 rows carry a source).
      if t.isLive, let src = t.categorySource {
        if t.category == nil && !(src.kind == .none || src.kind == .user) {
          add("I18_category_source_shape", .hardStop, "\(id): \(src.kind.rawValue) source with no category")
        }
        if t.category != nil && src.kind == .none { add("I18_category_source_shape", .hardStop, "\(id): a category with source none") }
      }
      // I19: no links on an unparsed row.
      if t.unparsed {
        for f in ["account_id", "counter_account_id", "project_id", "refund_of", "transfer_peer"] where t.annotation(f) != nil {
          add("I19_unparsed_links_empty", .hardStop, "\(id): \(f) on an unparsed row")
        }
      }
      // I21: the successor chain terminates at a live row.
      if t.successorID != nil {
        var cur = id
        var steps = 0
        var ok = false
        while steps <= s.txns.count {
          guard let row = s.txns[cur] else { break }
          guard let next = row.successorID else {
            ok = row.supersededBy == nil
            break
          }
          cur = next
          steps += 1
        }
        if !ok { add("I21_successor_chain_acyclic", .hardStop, "\(id): the successor chain does not end at a live row") }
      }
      // The pending index: exactly the live, parsed rows with no home amount.
      let shouldPend = t.isLive && !t.unparsed && t.amountHomeMinor == nil
      let pends = s.pendingByCurrency[t.currency]?.contains(id) == true
      if shouldPend != pends { add("I10_fx_pending_index", .hardStop, "\(id): pending index disagrees with the row") }
    }

    // Fingerprint index: every live row is indexed exactly once, no retired row is.
    var indexed: [String: Int] = [:]
    for (_, ids) in s.byFingerprint { for id in ids { indexed[id, default: 0] += 1 } }
    for (id, t) in s.txns {
      let n = indexed[id] ?? 0
      if t.isLive && n != 1 { add("I9_fingerprint_index", .hardStop, "\(id): indexed \(n) times") }
      if !t.isLive && n != 0 { add("I9_fingerprint_index", .hardStop, "\(id): retired but indexed") }
    }

    // I23: v4 rule shape.
    for (id, r) in s.rules where r.shape >= 4 {
      if !(1...8).contains(r.patterns.count) || !["exact", "starts_with", "contains"].contains(r.match) {
        add("I23_rule_v4_shape", .hardStop, "\(id): bad v4 rule shape")
      }
    }

    // Notices.
    for a in s.anomalies {
      if !anomalyKinds.contains(a.kind) { add("I14_forks_surfaced", .hardStop, "unknown anomaly kind \(a.kind) at seq \(a.atSeq)") }
      if a.kind == "supersede_without_origin" { add("I13_supersede_has_origin", .notice, "seq \(a.atSeq)") }
    }
    if !s.forks.isEmpty { add("I14_forks_surfaced", .notice, "\(s.forks.count) forks resolved") }
    for u in s.unreadable { add("I15_unreadable_set_aside", .notice, "seq \(u.seq) from \(u.writerID)") }
    return out
  }

  /// The halt the violations call for: `inconsistent` when any is a hard stop.
  public static func halts(_ violations: [Violation]) -> Bool { violations.contains { $0.severity == .hardStop } }

  /// The audit (04 §5.3): a re-fold from genesis must reproduce the kept
  /// state's witness byte for byte (I9 version contiguity, I10 FX prefix,
  /// I22 keyed last position all follow from it).
  public static func audit(kept: State, refolded: State) -> Violation? {
    guard kept.serialized() != refolded.serialized() else { return nil }
    return Violation(id: "I22_audit_refold", severity: .hardStop, detail: "the re-fold differs from the kept state")
  }
}
