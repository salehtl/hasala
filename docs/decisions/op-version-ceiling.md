# Op version ceiling (2026-10-31)

A row one schema above the reader's stops sync on every device (spec 01 §6.6 R10). That is
right when a newer build wrote it. It also lets one live writer stop the whole account with
one row, and the beta has no way to remove another device.

**Decision.** `GET /api/v1/meta` reports `op_version_ceiling`, the op schema of the newest
shipped build (`OpVersionCeiling` in `server/internal/api/meta.go`). When a reader meets a
next-version row, it asks `/meta`. If the ceiling is at or below its own schema, no shipped
build wrote that row, so the reader sets the row aside and sync continues. Otherwise, or when
`/meta` gives no answer, it stops as before.

**Shipping a new schema.** Raise `OpVersionCeiling` and deploy `hasalad` before a build that
writes the new schema goes out. A device that read a row while the ceiling was low holds it
set aside, and a build that can read it folds it on its next cold fold.

**Trust.** The server still cannot make a reader accept anything: a false low ceiling only
sets aside a row the server could withhold anyway, and a false high ceiling is today's stop.

**Limit.** While the ceiling is above a device's schema, in the window of a real release, one
live writer can still stop an older build until it updates.
