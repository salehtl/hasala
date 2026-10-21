# Recurring items: lifecycle, matching and detection

**Status: decided 2026-10-21** (owner: scope "everything", UI from existing parts, past
payments linked only when the person confirms). Built on branch `recurring/lifecycle`.

A recurring item is a `bill` in the code and "Recurring" on screen (Profile › Recurring).
This document is the plan of record: the model, every decision on edge cases, and how the
work was split for parallel development.

## Principles that bound the design

- **Append-only.** Every change is a new op. Nothing is rewritten or deleted. Undo writes a
  new version that restores the old record.
- **The server stays blind.** No server, Go or `server/oracle` change. Bills, terms,
  pauses, matches and candidates exist only in the encrypted ops and on the device.
- **No new op type, no schema bump.** `bill_set` gains optional payload keys. Older builds
  ignore unknown keys (`decodeBill` reads named keys only), so they keep folding every
  edit: no blob is set aside and no device hard-stops with "Update Hasala".
- **Money is integer fils** in decimal strings on the wire, `Int64` in memory, overflow
  checked (`Fils`, `planSum`).
- **Derived, not written.** Matching (which payment paid which due) and detection (which
  merchants repeat) are pure functions of the log, computed on each device at read time.
  Every device computes the same answer from the same log, so there is nothing to
  converge and nothing to race. Ops are written only for what the person decides.
- **No silent drop.** A refused payload stays in the log as an anomaly. A concurrent edit
  that loses a fork is shown on the bill ("Changed on two iPhones") with the values it
  replaced.

## The model

### `bill_set` (versioned entity, whole record) — new optional keys

```json
"changes": [{"from": "2026-11-06", "amount_mode": "fixed", "amount_minor": "6300", "tolerance_bp": 200}],
"pauses":  [{"from": "2026-12-01", "until": null}]
```

- Absent or `[]` means none. Authors omit the key when the list is empty, so every
  existing record, fixture and state hash stays byte for byte the same.
- Top-level `amount_mode`, `amount_minor`, `tolerance_bp` stay the **original terms**.
  The terms of a due date are those of the last change with `from <= due`, else the
  original terms. Older builds keep showing the original price; nothing breaks.
- `changes`: at most 24; `from` strictly increasing, each `>= start` and `<= end` when
  `end` is set; `amount_minor > 0`; `tolerance_bp` 0–5000 with `fixed`, `null` with
  `variable`.
- `pauses`: at most 24 ranges; `from >= start`; `until` is `null` only on the last range,
  otherwise `until > from`; ranges strictly ordered and not overlapping
  (`next.from >= prev.until`). A due `d` is paused when `from <= d` and (`until == null` or
  `d < until`).
- A grammar violation refuses the whole edit (payload anomaly, no version consumed),
  exactly like today's refusals.

### `status`

| Value | Meaning | Shown |
| --- | --- | --- |
| `active` | Expected on its schedule (minus pauses). | Coming up / Paused |
| `cancelled` | It ended. `end` is the last day a due can fall on. | Ended |
| `dismissed` | Not a bill (a wrong detection, or a manual item deleted). | Hidden; its id blocks re-detection |

`cancelled` and `dismissed` were shown the same before this change; they are now apart.

### `bill_occurrence_set` (unchanged)

`paid{txn?}`, `skipped`, `snoozed{until}`, `clear`, keyed by `(bill, due)`. A `paid` with a
`txn` is an explicit link the person made (past-payment linking, "I paid it" with a chosen
payment). The matcher never writes it.

## Decisions on edge cases

### Past transactions

1. **History is the payments.** A bill's past is its paid dues (explicit links first, then
   matcher links). Past figures never come from the bill's terms, so editing a price never
   changes what was spent.
2. **Adding an item by hand** sets `start` to the first due the person picks (default: the
   next due). The sheet then offers recent payments that look like it (same merchant key,
   within tolerance of the terms, near a due, not linked to another bill), newest first,
   none ticked. Each ticked payment becomes `paid{txn}` on its due; if it falls before
   `start`, `start` moves back to that due in the same blob. Nothing is linked without a
   tap.
3. **Dues before tracking began are never late.** "Late" and "to come" consider only dues
   on or after the bill's tracking day (the day its first version was authored, or `start`
   if later). An unpaid due before that is shown as "Not tracked" in history, not as late.
4. **Tracking a detected candidate** creates the bill with `start` = the first due of the
   series the detector saw, so its history fills from matched payments with no op per
   payment.
5. **Archived, transfer, held-copy, superseded and refund rows never match.** An explicit
   `paid{txn}` that points at a row later archived or superseded still counts as paid; the
   history shows the date without an amount.

### Price changes

6. **Edit amount** asks "Starting" with the latest paid due and the next six dues
   (default: the next due) and appends a change. A change dated on or before a due that
   already has a payment re-labels that payment as at the new price, which is how a person
   says "this month's charge was the new price".
7. **A change with the same `from` as an existing one replaces it** (the editor rewrites
   the list; the grammar forbids duplicates).
8. **Price-change proposal**: a fixed-amount bill whose matched payment for a due is
   outside that due's tolerance shows "Netflix is 63.00 now (was 56.00)". Accept appends
   `{from: that due, amount_minor: the charge}`. Not now is device-local for that payment.
   The proposal never writes on its own, also not for detected bills and not for "Sort
   automatically" users. A variable bill never proposes.
9. **Foreign currency**: a bill in AED matches a foreign charge by its home amount when the
   row has one; otherwise it does not match on amount and is offered for manual linking.

### Pause and resume

10. Pause asks "Until I resume" (default) or "Until" a date. It appends a range from today
    (or the next due when today is past it). Resume sets `until` = today on the open range.
11. Paused dues are not expected: not late, not "to come", not in the plan.
12. A payment matched to a paused due marks it paid and raises "Charged while paused".
13. Ending while paused closes the open range at `end`.

### End and reactivate

14. End asks "Last payment" (default: the latest paid due, else today; never before
    `start`). `end` must be after `start`; when the person ends on the start day, `end` =
    start + 1 day (the grammar is strict).
15. A payment matched after `end` (same keys, within tolerance, within one cadence of the
    next due that would have been) raises "Charged after you ended it" with
    "Start tracking again" and "It's fine" (device-local).
16. Start tracking again: `status: active`, `end: null`, and a pause range
    `[old end, today)` appended so the gap is not counted as unpaid.
17. Delete (manual items) and Not a bill (detected) both write `status: dismissed`. Both
    have undo.

### Schedule edits

18. A schedule edit (cadence, anchor) is a whole-record edit. Resolutions on dates that
    are no longer dues stay in the log; paid ones still show in history, skipped and
    snoozed ones are ignored.
19. Monthly and yearly dues keep the anchor's day, clamped to short months (31 → 30/28/29).
    Weekly and daily dues step from the anchor.

### Matching (derived)

20. A debit row matches a bill when its merchant key is one of the bill's `keys`, its
    currency is the bill's (or its home amount is AED for an AED bill), and its amount is
    within the due's tolerance (fixed) or within 50% of the due's amount (variable).
21. Each row matches at most one due of one bill; each due takes at most one row. A row is
    assigned to the nearest unpaid due within ± half a cadence (at most 15 days for
    monthly), ties to the earlier due. Rows outside every window stay unmatched.
22. Explicit resolutions win: a due with `paid`, `skipped` or `snoozed` is not given a
    matcher row; a row named in an explicit `paid{txn}` is not given to another due.
23. Two bills sharing a key: a row goes to the bill whose due terms are closest in amount,
    then the older bill (`first_seq`).

### Detection (derived)

24. Candidates are series of ≥ 3 debit rows with one merchant key and currency, with
    regular gaps (monthly 26–35 days, weekly 6–8, yearly 350–380), amounts within 20% of
    the median (else a variable candidate), and the last row within 1.5 cadences of today.
25. A candidate's id is `detectedBillID(key, direction, currency)` (Pass A). A key already
    covered by any bill head (manual, active, ended or dismissed) never becomes a
    candidate, so "Not a bill" and ended items are never re-proposed, and a manual item
    is never duplicated by a detected one.
26. Track writes a `bill_set` create with that derived id (two iPhones that track the same
    candidate converge on one id; the second create is a `duplicate_create` anomaly and
    changes nothing). Not a bill writes a create with `status: dismissed`, so it syncs.

### Conflicts and old builds

27. Concurrent edits of one bill fork; the later `authored_at` wins (existing rule). The
    bill shows "Changed on two iPhones" from `fork_notice`, with the replaced record and
    Re-apply (a new version with those values).
28. A build without this change ignores `changes` and `pauses`: it shows the original
    price and no pause, and an edit made there drops the lists (whole record). The What
    to Test of the first build with this change asks testers to update every device.

### Plan

29. The plan reads one `BillExpectation` per due in the month for active bills in a
    `bills`-role category: amount from the due's terms, `isEstimate` for variable,
    status paid / upcoming / due / late from explicit and matched payments. Paused,
    ended and dismissed dues give none.

### Salary

30. Salary stays `income_source_set`. Its row on Recurring opens an edit sheet (amount,
    payday, active). Past months use received income, so an edit never changes history;
    it applies from the current month on. A dated raise is not built.

### Privacy

31. Nothing new leaves the device. Detection and matching run on the device. Cloud
    suggestions are not used for bills. Notifications about bills stay off (Remind me
    stays Debug only).

## Parallel build plan

Contracts first, then independent streams, each in its own worktree, merged into
`recurring/lifecycle`.

| Wave | Stream | Owns | Depends on |
| --- | --- | --- | --- |
| 1 | **Core model** | `Replay/V4/BillsAccounts.swift`, `Replay/State.swift` (Bill), `Replay/Serialize.swift` (billJSON), `Projection/Schema.swift` (v7), `Projection/Projector.swift`, `LedgerReader+Accounts.swift`, `OpAuthor+BillsAccounts.swift`, new `Domain/Bills/BillSchedule.swift` (dues, terms, pauses, tracking day), tests and `conformance/swift` fold edges | — |
| 1 | **Kit contracts** | `HasalaModels` (`Bill`, `BillCandidate`, `LedgerEdit` cases, attention kinds), `HasalaMocks/InMemoryLedger.swift`, HasalaKit tests | — |
| 2 | **Matcher** | new `Domain/Bills/BillMatcher.swift` + tests | Core model |
| 2 | **Detector** | new `Domain/Bills/BillDetector.swift` + tests | Core model |
| 2 | **Live authoring** | `Live/Ledger/LedgerEditAuthor.swift`, `LiveLedgerStore.swift`, `LedgerStateMapper.swift` bill mapping, `HasalaTests` | Core model, Kit contracts |
| 2 | **UI** | `Features/Bills/*`, `BillsEngine.swift`, salary sheet, `HasalaUITests` | Kit contracts |
| 3 | **Integration** | matcher, detector, plan feed and fork card wired into the mapper; attention cards; end-to-end tests | all of wave 2 |
