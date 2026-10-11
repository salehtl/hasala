// CoreSync (Sync/), spec 04 §2.2. Owner: WS-11.
//
//   SyncWire.swift     the sync routes' JSON (`02` #28–#30)
//   SyncStatus.swift   phases, halts, latches; how each server answer maps (§5.1, §5.5, §5.7)
//   SyncContext.swift  one account's store, secrets, client, clock and randomness
//   Roster.swift       the verified roster, pinned under AAK.pub (01 §10.13)
//   Puller.swift       pull through the §6.6 reader, the fold seam, one transaction per page (§5.2)
//   LedgerPageObserver.swift  the fold seam's production observer: fold, snapshot, cold re-fold,
//                      projection with the outbox overlay, the author context (§5.2-§5.3, §4.3)
//   Pusher.swift       batch, seal, sign, persist, upload, the response table, 409 resend (§5.5)
//   SyncEngine.swift   the actor: coalesced runs and the published status (§5.1)
//   Account*.swift     the auth ceremonies' core halves (§6.2–§6.4): signup, sign-in, enrolment, step-up
//
// The modules CoreOutbox and the app's Live/ layer need with it are re-exported,
// so they import CoreSync alone.
@_exported import CoreAuth
@_exported import CoreJSON
@_exported import CorePrimitives
@_exported import CoreStore
@_exported import CoreTime
@_exported import CoreWire
