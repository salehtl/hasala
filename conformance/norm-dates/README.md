# conformance/norm-dates

Date and time canonicalisation that must be identical in every client: the
normalizer's forwarded-`Date` parser and `emailDate`, and the wire timestamp
grammar the fold applies to `posted_at` and `authored_at`. The ledgerd
TypeScript client (removed after commit 9b4aae2) wrote the vectors; the Swift
port (Norm, Time) must reproduce every vector. All inputs are synthetic.

Golden file: the Swift test owns the expected output and rewrites it with
`HASALA_UPDATE_GOLDEN=1` (see `conformance/README.md`). To add or change a
case, edit its input by hand, run update mode, and review the diff.

## `dates.json`

Strings are written with every non-ASCII code point escaped as `\uXXXX`.

### `forward_dates[]`: `{name, input, expect}`

`parseForwardDate(input)` from `src/norm/unwrap.ts`, rendered as RFC 3339 UTC
with no fraction (`YYYY-MM-DDTHH:MM:SSZ`), or `null` when no layout reads it.

- Four closed layouts: `Jan 2, 2006 at 3:04 PM`, `Mon, Jan 2, 2006 at 3:04 PM`,
  `2 January 2006 at 15:04:05`, `2 January 2006 at 15:04`. Month and weekday
  names are ASCII case-insensitive; `AM`/`PM` are upper case only; the weekday
  is not checked against the date.
- The value is trimmed of TAB, LF, VT, FF, CR, SPACE, U+00A0 and U+FEFF; then
  U+202F and U+00A0 become spaces; then each layout space matches one or more
  spaces (as in Go's `time.Parse`).
- If no layout reads the value, it is retried once with its last
  space-delimited token (a zone name) removed.
- The result is naive: read as UTC, no zone applied. A year is taken literally
  (`0050` is the year 50).

These are the same answers as the Go normalizer's `parseForwardDate`
(`server/internal/norm`), which every vector was checked against when the suite
was written.

### `email_dates[]`: `{name, forward_date, received_at, expect: {email_date, date_source}}`

Stage 10's choice (`emailDateOf` in `src/norm/norm.ts`): the forwarded date when
`forward_date` is non-empty and parses, with `date_source` `forward_header`;
otherwise the arrival time `received_at` (RFC 3339, any offset) converted to
UTC and truncated to the second, with `date_source` `received`. A port that
gets the arrival time as epoch milliseconds (Gmail's `internalDate`) must
render the same instant the same way.

### `instants[]`: `{name, input, expect}`

The wire timestamp grammar (`parseInstantMs` and `canonicalTime` in
`src/wire/op.ts`; Go's `server/internal/oplog/opref` applies the same rules,
the zero time aside, see below):

- `expect` is `{"ok": false}` when the string is refused, else
  `{"ok": true, "epoch_ms", "canonical", "utc_day"}`.
- Accepted shape: `YYYY-MM-DDTHH:MM:SS`, an optional non-empty fraction, then
  `Z` or `±HH:MM` (offset hours 00-23, minutes 00-59); upper-case `T` and `Z`;
  calendar ranges checked (no hour 24, no second 60, no 30 February).
- `epoch_ms`: milliseconds since the Unix epoch as a decimal string (it may be
  negative); the fraction is truncated, never rounded.
- `canonical`: `YYYY-MM-DDTHH:MM:SS.mmmZ` in UTC. A string whose UTC instant
  would need a year outside 0000-9999 is refused.
- Go's zero time `0001-01-01T00:00:00Z` is refused (`go-zero-time-refused`).
  The TypeScript oracle refuses it inside `parseInstantMs`; Go's
  `parseWireTime` accepts it, and opref refuses it one level up, in the op
  checks that reject a zero `authored_at` or `received_at` (`IsZero`). A port
  refuses it wherever it parses an instant, as the oracle does. One
  millisecond later (`year-one`) is accepted everywhere.
- `utc_day`: the UTC calendar day of `epoch_ms` (`YYYY-MM-DD`), the day the
  duplicate fingerprint keys on (`replay/state.ts` `utcDay`).
