// CoreProjection (Projection/), spec 04 §2.2. Owner: WS-10.
//
//   - Schema.swift        projection.sqlite: tables and views (04 §4.3; 03c §3.9, §4.4, §5.6, §6.3,
//                         §7.3; 03a §5), rebuilt whole on a version change
//   - Projector.swift     State (+ the pending overlay) → the tables, one transaction, `complete`
//   - LedgerReader.swift  typed queries and ValueObservation streams for the screens
//   - LedgerReader+Accounts.swift  accounts, cards, check-ins, bills, projects, income, trust
//   - ProjectionStore.swift  projection.sqlite as one value (the caller never holds GRDB)
//
// The only GRDB users besides CoreStore (R6). The database is plaintext financial data:
// the caller opens it under the same file protection and backup exclusion as the store (04 §4.1).
