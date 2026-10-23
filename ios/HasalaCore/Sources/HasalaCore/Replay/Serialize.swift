// lint-allow: [String: each record is built in a Dictionary and every object's keys are sorted by UTF-8 bytes (sortingKeysByUTF8) before writing, so no iteration order reaches the output.
//
// `serializeState` (replay/state.ts, ported): the canonical JSON of a state, the
// witness that makes "two replicas converge" checkable.
//
// Maps become arrays of `[key, value]` pairs sorted by the UTF-8 bytes of the
// key, object keys are sorted the same way, sets become sorted arrays, every
// 64-bit integer that the oracle holds as a bigint is a decimal string, arrays
// keep their order (their order is meaning), and `appliedAtCursor` is not
// witnessed. On a v1-v3 log the bytes equal the TypeScript oracle's.
//
// v4 additions follow 03c §1.9: a field added to a v3 record is emitted only
// when not at its default; a new top-level map only when non-empty; a record
// written by a v4 op in its v4 shape. `maxAuthored` is never emitted.
import CoreJSON
import CorePrimitives
import Foundation
import HasalaText
import OrderedCollections

extension State {
  /// The canonical JSON bytes of this state.
  public func serialized(blankingDiagnostics: Bool = false) -> [UInt8] {
    JSONWriter(numbers: .literal, keyOrder: .insertion).bytes(witness(blankingDiagnostics: blankingDiagnostics))
  }

  /// SHA-256 (lower-case hex) of ``serialized(blankingDiagnostics:)``.
  public func serializedSHA256(blankingDiagnostics: Bool = false) -> String {
    Hex.encode(sha256(serialized(blankingDiagnostics: blankingDiagnostics)))
  }

  /// The witness as a `JSONValue`, keys already sorted.
  public func witness(blankingDiagnostics: Bool = false) -> JSONValue {
    var o: [(String, JSONValue)] = [
      ("anomalies", .array(anomalies.map { a in obj(["at_seq": dec(a.atSeq), "detail": .string(blankingDiagnostics ? "" : a.detail), "kind": .string(a.kind)]) })),
      ("banks", pairs(banks) { .bool($0) }),
      ("budgetMonthlyTotal", budgetMonthlyTotal.map(dec) ?? .null),
      ("budgetSplit", budgetSplit.map { obj(["need": num($0.need), "saving": num($0.saving), "want": num($0.want)]) } ?? .null),
      ("byFingerprint", pairs(byFingerprint) { .array($0.map(JSONValue.string)) }),
      ("categories", pairs(categories, Self.categoryJSON)),
      ("checkpoints", .array(checkpoints.map { c in
        obj(["counter": dec(c.counter), "hash": .string(c.hash), "stream": .string(c.stream), "writer_id": .string(c.writerID)])
      })),
      ("cursors", obj(["cold": dec(cursors.cold), "hot": dec(cursors.hot)])),
      ("forks", .array(forks.map { f in
        obj([
          "at_seq": dec(f.atSeq), "entity": obj(["id": .string(f.entityID), "kind": .string(f.entityKind)]),
          "loser_op": .string(f.loserOp), "winner_op": .string(f.winnerOp),
        ])
      })),
      ("heads", pairs(heads) { h in
        obj([
          "authored_at_ms": num(h.authoredAtMs), "id": .string(h.id), "kind": .string(h.kind), "op_id": .string(h.opID),
          "version": num(h.version), "writer_id": .string(h.writerID),
        ])
      }),
      ("homeCurrency", homeCurrency.map(JSONValue.string) ?? .null),
      ("liveByIngestID", pairs(liveByIngestID) { .string($0) }),
      ("pendingByCurrency", pairs(pendingByCurrency) { set in .array(set.sorted { compareUTF8($0, $1) < 0 }.map(JSONValue.string)) }),
      ("rateUpdatedAt", pairs(rateUpdatedAt) { .string($0) }),
      ("rates", pairs(rates) { $0.map(dec) ?? .null }),
      ("rules", pairs(rules, Self.ruleJSON)),
      ("txns", pairs(txns, Self.txnJSON)),
      ("unreadable", .array(unreadable.map { u in
        obj([
          "reason": .string(blankingDiagnostics ? "" : u.reason), "seq": dec(u.seq), "stream": .string(u.stream),
          "writer_counter": dec(u.writerCounter), "writer_id": .string(u.writerID),
        ])
      })),
    ]
    // v4 top-level additions, only when non-empty (03c §1.9 rule 2).
    if !merchantNames.isEmpty {
      o.append(("merchantNames", pairs(merchantNames) { k in obj(["display_name": k.value.map(JSONValue.string) ?? .null, "op_id": .string(k.opID)]) }))
    }
    if !merchantRejections.isEmpty {
      o.append(("merchantRejections", pairs(merchantRejections) { r in
        obj(["category": .string(r.category), "merchant_key": .string(r.merchantKey), "op_id": .string(r.opID), "rejected": .bool(r.rejected)])
      }))
    }
    if !senderTrust.isEmpty {
      o.append(("senderTrust", pairs(senderTrust) { k in obj(["op_id": .string(k.opID), "trusted": .bool(k.value)]) }))
    }
    if !projects.isEmpty { o.append(("projects", pairs(projects, Self.projectJSON))) }
    if !goals.isEmpty { o.append(("goals", pairs(goals, Self.goalJSON))) }
    if !plan.isEmpty { o.append(("plan", Self.planJSON(plan))) }
    if !bills.isEmpty { o.append(("bills", pairs(bills, Self.billJSON))) }
    if !billResolutions.isEmpty {
      o.append(("bill_resolutions", pairs(billResolutions) { r in
        obj([
          "at_seq": dec(r.atSeq), "bill": .string(r.bill), "due": .string(r.due), "resolution": .string(r.resolution),
          "txn": str(r.txn), "until": str(r.until),
        ])
      }))
    }
    if !accounts.isEmpty {
      o.append(("accounts", pairs(accounts) { a in
        obj([
          "active": .bool(a.active), "closed_on": str(a.closedOn), "color": str(a.color), "currency": .string(a.currency),
          "first_seq": dec(a.firstSeq), "id": .string(a.id), "in_plan": .bool(a.inPlan), "institution": str(a.institution),
          "kind": .string(a.kind), "name": .string(a.name), "statement_due_day": a.statementDueDay.map(num) ?? .null,
        ])
      }))
    }
    if !cards.isEmpty {
      o.append(("cards", pairs(cards) { c in
        obj(["account": str(c.account), "at_seq": dec(c.atSeq), "bank": str(c.bank), "last4": .string(c.last4), "state": .string(c.state)])
      }))
    }
    if !checkins.isEmpty {
      o.append(("checkins", pairs(checkins) { c in
        obj([
          "account": .string(c.account), "adjustment_minor": c.adjustmentMinor.map(dec) ?? .null, "as_of": .string(c.asOf),
          "at_seq": dec(c.atSeq), "balance_minor": dec(c.balanceMinor), "id": .string(c.id), "resolution": str(c.resolution),
          "source": .string(c.source), "void": .bool(c.void),
        ])
      }))
    }
    if !byDedupeKey.isEmpty { o.append(("byDedupeKey", pairs(byDedupeKey) { .string($0) })) }
    if !mailboxRetirements.isEmpty {
      o.append(("mailboxRetirements", .array(mailboxRetirements.map { r in
        obj([
          "at_seq": dec(r.atSeq), "grant_id": .string(r.grantID), "legacy": .bool(r.legacy), "op_id": .string(r.opID),
          "provider": .string(r.provider), "txn_ids": .array(r.txnIDs.map(JSONValue.string)),
        ])
      })))
    }
    return JSONValue.object(JSONObject(o)).sortingKeysByUTF8()
  }

  // MARK: Records

  static func txnJSON(_ t: Txn) -> JSONValue {
    var o: [String: JSONValue] = [
      "amount_home_minor": t.amountHomeMinor.map(dec) ?? .null, "amount_minor": dec(t.amountMinor),
      "category": str(t.category), "currency": .string(t.currency), "direction": .string(t.direction),
      "duplicate_disposition": str(t.duplicateDisposition), "id": .string(t.id), "ingest_id": .string(t.ingestID),
      "last4": .string(t.last4), "mailbox_message_id": str(t.mailboxMessageID), "merchant_raw": .string(t.merchantRaw),
      "needs_review": .bool(t.needsReview), "parse_error": str(t.parseError), "possible_duplicate_of": str(t.possibleDuplicateOf),
      "posted_at": .string(t.postedAt), "provenance": .string(t.provenance),
      "splits": .array(t.splits.map(splitJSON)), "superseded_by": str(t.supersededBy), "tier": .string(t.tier),
      "unparsed": .bool(t.unparsed), "verified_origin_domain": str(t.verifiedOriginDomain), "version": num(t.version),
    ]
    if let s = t.categorySource { o["category_source"] = sourceJSON(s) }
    if let v = t.entryMethod { o["entry_method"] = .string(v) }
    if let v = t.location { o["location"] = .string(v) }
    if let v = t.postedPrecision { o["posted_precision"] = .string(v) }
    if let v = t.bank { o["bank"] = .string(v) }
    if let g = t.gates {
      var go: [String: JSONValue] = [:]
      if let v = g.ar { go["ar"] = .string(v) }
      if let v = g.sender { go["sender"] = .string(v) }
      if let v = g.template { go["template"] = .string(v) }
      if let v = g.card { go["card"] = .string(v) }
      if let v = g.forwarded { go["forwarded"] = .bool(v) }
      if let v = g.kind { go["kind"] = .string(v) }
      o["gates"] = obj(go)
    }
    if let v = t.successorID { o["successor_id"] = .string(v) }
    if let v = t.sourceMailbox { o["source_mailbox"] = .string(v) }
    if let v = t.sourceProvider { o["source_provider"] = .string(v) }
    if let v = t.retiredBy { o["retired_by"] = .string(v) }
    if let d = t.dedupe {
      var dj: [String: JSONValue] = [:]
      if let v = d.messageID { dj["message_id"] = .string(v) }
      if let v = d.bankRef { dj["bank_ref"] = .string(v) }
      o["dedupe"] = obj(dj)
    }
    if let v = t.mergedInto { o["merged_into"] = .string(v) }
    if let v = t.mergeKind { o["merge_kind"] = .string(v) }
    if let v = t.mergeOp { o["merge_op"] = .string(v) }
    if !t.aliases.isEmpty {
      o["aliases"] = .array(t.aliases.map { a in
        obj([
          "ingest_id": .string(a.ingestID), "kind": .string(a.kind), "mailbox_message_id": str(a.mailboxMessageID),
          "source_mailbox": str(a.sourceMailbox), "source_provider": str(a.sourceProvider), "txn_id": .string(a.txnID),
        ])
      })
    }
    if let v = t.copyOf { o["copy_of"] = .string(v) }
    if let v = t.copyDecision { o["copy_decision"] = .string(v) }
    if !t.annotations.isEmpty {
      o["annotations"] = pairs(t.annotations) { k in obj(["op_id": .string(k.opID), "value": str(k.value)]) }
    }
    return obj(o)
  }

  static func splitJSON(_ s: Split) -> JSONValue {
    var o: [String: JSONValue] = ["amount_minor": dec(s.amountMinor), "category": .string(s.category)]
    if let n = s.note { o["note"] = .string(n) }
    return obj(o)
  }

  static func sourceJSON(_ s: CategorySource) -> JSONValue {
    var o: [String: JSONValue] = ["kind": .string(s.kind.rawValue)]
    if let v = s.ruleID { o["rule_id"] = .string(v) }
    if let v = s.bundle { o["bundle"] = .string(v) }
    if let v = s.entry { o["entry"] = .string(v) }
    if let v = s.model { o["model"] = .string(v) }
    return obj(o)
  }

  static func ruleJSON(_ r: Rule) -> JSONValue {
    if r.shape <= 3 {
      return obj([
        "category": .string(r.category), "match": .string(r.match), "pattern": .string(r.patterns.first ?? ""),
        "priority": num(r.priority), "version": num(r.version),
      ])
    }
    return obj([
      "category": .string(r.category), "created_at": str(r.createdAt), "enabled": .bool(r.enabled),
      "match": .string(r.match), "origin": .string(r.origin), "patterns": .array(r.patterns.map(JSONValue.string)),
      "priority": num(r.priority), "removed": .bool(r.removed), "version": num(r.version),
    ])
  }

  static func categoryJSON(_ c: CategoryDef) -> JSONValue {
    var o: [String: JSONValue] = [
      "active": .bool(c.active), "bucket": str(c.bucket), "id": .string(c.id), "kind": .string(c.kind), "name": .string(c.name),
    ]
    if c.shape <= 3 { o["color"] = str(c.color) } else { o["icon"] = str(c.icon) }
    if let parent = c.parent { o["parent"] = .string(parent) }
    return obj(o)
  }

  static func projectJSON(_ p: Project) -> JSONValue {
    obj([
      "budget_minor": p.budgetMinor.map(dec) ?? .null, "completed_on": str(p.completedOn), "count_in_plan": .bool(p.countInPlan),
      "created_at": .string(p.createdAt), "ends_on": str(p.endsOn), "icon": str(p.icon), "name": .string(p.name),
      "starts_on": str(p.startsOn), "status": .string(p.status), "version": num(p.version),
    ])
  }

  static func goalJSON(_ g: Goal) -> JSONValue {
    var so: [String: JSONValue] = ["kind": .string(g.source.kind)]
    if let v = g.source.categoryID { so["category_id"] = .string(v) }
    if let v = g.source.since { so["since"] = .string(v) }
    if let v = g.source.accountID { so["account_id"] = .string(v) }
    return obj([
      "completed_on": str(g.completedOn), "created_at": .string(g.createdAt), "icon": str(g.icon), "name": .string(g.name),
      "source": obj(so), "starting_minor": dec(g.startingMinor), "status": .string(g.status),
      "target_minor": dec(g.targetMinor), "target_month": str(g.targetMonth), "version": num(g.version),
    ])
  }

  static func billJSON(_ b: Bill) -> JSONValue {
    var o: [String: JSONValue] = [
      "account": str(b.account), "amount_minor": dec(b.amountMinor), "amount_mode": .string(b.amountMode),
      "anchor": .string(b.anchor), "cadence": obj(["every": num(b.cadence.every), "unit": .string(b.cadence.unit)]),
      "category": str(b.category), "currency": .string(b.currency), "direction": .string(b.direction), "end": str(b.end),
      "first_seq": dec(b.firstSeq), "keys": .array(b.keys.map(JSONValue.string)), "name": .string(b.name),
      "source": .string(b.source), "start": .string(b.start), "status": .string(b.status),
      "tolerance_bp": b.toleranceBp.map(num) ?? .null, "version": num(b.version),
    ]
    if !b.changes.isEmpty {
      o["changes"] = .array(b.changes.map { c in
        obj([
          "amount_minor": dec(c.amountMinor), "amount_mode": .string(c.amountMode), "from": .string(c.from),
          "tolerance_bp": c.toleranceBp.map(num) ?? .null,
        ])
      })
    }
    if !b.pauses.isEmpty {
      o["pauses"] = .array(b.pauses.map { p in obj(["from": .string(p.from), "until": str(p.until)]) })
    }
    if let c = b.createdAt { o["created_at"] = .string(c) }
    return obj(o)
  }

  /// 03a §4.3.
  static func planJSON(_ p: PlanState) -> JSONValue {
    func write(_ w: PlanWrite?) -> JSONValue {
      guard let w else { return .null }
      return obj(["at_ms": dec(w.atMs), "op_id": .string(w.opID), "writer_id": .string(w.writerID)])
    }
    var cells: [(String, String, PlanCell)] = []
    for (c, months) in p.cells { for (m, cell) in months { cells.append((c, m, cell)) } }
    cells.sort { a, b in
      let k = compareUTF8(a.0, b.0)
      return k != 0 ? k < 0 : compareUTF8(a.1, b.1) < 0
    }
    var o: [String: JSONValue] = [
      "cells": .array(cells.map { c, m, cell in
        obj([
          "category_id": .string(c), "month": .string(m), "latest_set_minor": cell.latestSet.map(dec) ?? .null,
          "onward_set_minor": cell.onwardSet.map(dec) ?? .null, "moves_all_minor": dec(cell.movesAll),
          "moves_since_set_minor": dec(cell.movesSinceSet), "write": write(cell.latestSetWrite),
        ])
      }),
      "moves": .array(p.moves.values.sorted { $0.position < $1.position }.map { r in
        obj([
          "op_id": .string(r.opID), "seq": dec(r.position.seq), "index": num(Int64(r.position.index)), "month": .string(r.month),
          "from": str(r.from), "to": str(r.to), "amount_minor": dec(r.amount), "reason": .string(r.reason),
          "batch_id": str(r.batchID), "undoes": str(r.undoes), "undone": .bool(r.undone),
        ])
      }),
      "income_sources": .array(p.incomeSources.values.sorted { compareUTF8($0.id, $1.id) < 0 }.map { s in
        obj([
          "id": .string(s.id), "name": .string(s.name), "category_id": .string(s.categoryID), "amount_minor": dec(s.amountMinor),
          "payday": num(s.payday), "active": .bool(s.active), "write": write(s.write),
        ])
      }),
      "roles": .array(p.roles.keys.sorted { compareUTF8($0, $1) < 0 }.map { c in
        obj(["category_id": .string(c), "role": .string(p.roles[c]!.role), "write": write(p.roles[c]!.write)])
      }),
    ]
    if !p.overwrites.isEmpty {
      o["overwrites"] = .array(p.overwrites.map { w in
        obj([
          "key_kind": .string(w.keyKind), "key": .string(w.key), "replaced_op": .string(w.replacedOp), "by_op": .string(w.byOp),
          "at_seq": dec(w.atSeq), "replaced_value": .string(w.replacedValue),
        ])
      })
    }
    return obj(o)
  }
}

// MARK: - Builders

private func dec(_ v: Int64) -> JSONValue { .string(String(v)) }
private func num(_ v: Int64) -> JSONValue { .number(JSONNumber(v)) }
private func str(_ v: String?) -> JSONValue { v.map(JSONValue.string) ?? .null }

/// An object from unordered members; the witness sorts every object's keys.
private func obj(_ members: [String: JSONValue]) -> JSONValue {
  .object(JSONObject(members.map { ($0.key, $0.value) }))
}

/// A map as `[key, value]` pairs sorted by the key's UTF-8 bytes.
private func pairs<V>(_ m: OrderedDictionary<String, V>, _ f: (V) -> JSONValue) -> JSONValue {
  .array(m.keys.sorted { compareUTF8($0, $1) < 0 }.map { k in .array([.string(k), f(m[k]!)]) })
}

private func pairs<V>(_ m: OrderedDictionary<ExactKey, V>, _ f: (V) -> JSONValue) -> JSONValue {
  .array(m.keys.sorted { compareUTF8($0.value, $1.value) < 0 }.map { k in .array([.string(k.value), f(m[k]!)]) })
}
