// CoreDomain (Domain/), spec 04 §2.2. Owner: WS-16.
//
//   - Author/OpAuthor.swift        the op constructor for the beta's actions (03c §3.8, §5; 03a §9)
//   - Author/OpAuthor+BillsAccounts.swift  accounts, cards, bills, occurrences, check-ins (03b)
//   - Author/AuthorStamps.swift    the device's shared stamp memory (03c §1.8.2 own_last_ms)
//   - Sample/SampleSeed.swift      the sample-data loader (the bundled seed → blobs of ops)
//   - Categories/TaxonomyView.swift the effective category table (03c §4.4)
//   - Plan/PlanEngine.swift         plan math: assigned, activity, income, RTA, buckets, hero, pace,
//                                   goals, setup seeding (03a §6)
//   - Review/ReviewQueue.swift      review lanes (03c §3.7)
//   - Txn/                          display names, account attribution and link states (03c §3.6,
//                                   §3.9.2; 03b §4.5)
//   - Trust/EffectiveTrust.swift    the trusted-sender set and its author rules (03c §7.2)
//
// Pure: no clock, no I/O. `today` and `now` are always parameters.
