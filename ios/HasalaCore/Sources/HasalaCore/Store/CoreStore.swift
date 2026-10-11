// CoreStore (Store/), spec 04 §2.2. Owner: WS-11.
//
//   SecretStore.swift    the SecretStore seam, SecretItem (§4.4's mapping), MemorySecretStore
//   SecretRecords.swift  the session and binding item formats, typed access (Secrets)
//   LedgerSchema.swift   ledger.sqlite migration "v1" (§4.2)
//   LedgerStore.swift    the row store, client state, pending ops and the in-flight batch
//   FileHygiene.swift    file protection and backup exclusion (§4.1)
//
//   LedgerStore+FoldSnapshot.swift  the fold snapshot row (§5.3): bound tip, load checks
//   LedgerStore+Pending.swift       pending ingest ids and the newest pending stamp
