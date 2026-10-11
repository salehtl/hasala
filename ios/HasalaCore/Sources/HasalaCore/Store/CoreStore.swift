// CoreStore (Store/), spec 04 §2.2. Owner: WS-11.
//
//   SecretStore.swift    the SecretStore seam, SecretItem (§4.4's mapping), MemorySecretStore
//   SecretRecords.swift  the session and binding item formats, typed access (Secrets)
//   LedgerSchema.swift   ledger.sqlite migration "v1" (§4.2)
//   LedgerStore.swift    the row store, client state, pending ops and the in-flight batch
//   FileHygiene.swift    file protection and backup exclusion (§4.1)
//
// TODO(WS-10): fold_snapshot read/write (§5.3) once CoreReplay's StateSnapshot exists.
