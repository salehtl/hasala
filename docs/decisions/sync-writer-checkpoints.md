# Writer checkpoints (2026-11-11)

The op log has a `writer_checkpoint` op: one device's list of the chain heads it has read,
one head (counter and hash) for each writer and stream (`Wire/Checkpoint.swift`). The
current builds fold it (`Fold.applyCheckpoint`), and `OpAuthor.writerCheckpoint` can write
it. No build writes one during a push, and nothing writes `last_full_check_at` in the
ledger store. The check that compares the chain heads across devices (I11) has nothing to
compare.

**Decision.** The beta goes without writer checkpoints. No build writes a
`writer_checkpoint` op, and I11 is not checked.

**What each device already checks.** Each device pins what it has read, and a pull must
continue from it (spec 01 §6.6):

- Its own chain. A pulled row of its own writer above the highest counter it sealed stops
  sync (R1, `ownChainConflict`).
- Every writer's chain. Each page continues each writer's chain from the head the device
  pinned: the next counter, the previous hash and the blob hash must agree (R2), and the
  signed heads must verify against the writer's key (R2b). A gap, a fork or a counter that
  goes back stops sync.

**What checkpoints would add.** A comparison between devices. Without them, each device
checks its own view of each chain, and no device learns how far another device has read a
third writer's chain. Two devices that hold different lengths of that chain each pass their
own checks.

**Later.** Checkpoints come with a written rule, decided before any build writes one:

- the cadence: when a push writes a checkpoint, and which heads it lists;
- a mismatch: what a device does when a checkpoint names a head it has not read, or another
  hash for a counter it has read (a stop with a wall, or a notice on the Integrity screen),
  and how it recovers.

Writing checkpoints changes the ops written, so it needs the owner's decision.
