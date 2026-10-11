// CoreReplay (Replay/), spec 04 §2.2. Owner: WS-10 (Replay/V4/: WS-16).
//
// The fold of the op log into `State`:
//   - State.swift        the materialized state (v3 records plus 03a/03b/03c's v4 additions)
//   - Fold.swift         the engine: positions, the duplicate-delivery guard, the hard stops,
//                        and the parent-free v3 configuration ops
//   - Causal.swift       versioned entities: causality, forks, supersede, the txn edit paths,
//                        the fingerprint index
//   - CausalDecode.swift payload decoders of the versioned ops (v3 oracle semantics, v4 deltas)
//   - Payloads.swift     shared payload readers (`PayloadError` → `invalid_payload`)
//   - FX.swift           the FX snapshot rule
//   - Serialize.swift    `serializeState`, the convergence witness
//   - Snapshot.swift     the Codable fold snapshot and the fold fingerprint
//   - V4/                03c §3-§7 (txn deltas, annotations, merchant names, sender trust, v4
//                        categories and rules, projects, goals), 03a §3-§4 (plan) and 03b
//                        §3-§4 (bills and accounts, beta scope)
//
// Byte-exact module (spec 04 §2.4 R2): no Foundation JSON, no Double, no Calendar,
// every map ordered (R3).
