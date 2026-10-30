# Runbook: restore a backup on the QA host

A restore puts the database back to the time of a backup. An account that was
deleted after that time is in the dump again. The purge ledger stops it from
coming back:

- Each account deletion (`DELETE /api/v1/account` and `hasala-admin
  purge-user`) appends one line to `/var/lib/hasala-ledger/purged`: the random
  account id and the time. The append is part of the deletion. If it fails,
  nothing is deleted. If the database commit then fails and the account is
  still there, a `purge-cancelled` line follows, and the replay does not purge
  that account unless a later deletion line names it. If the line cannot be
  cancelled (for example, the database cannot be read after the failed commit),
  or the process stops between the append and the commit, the line stays and
  the next replay purges the account. The holder asked for that deletion: the
  answer in the first case says that it may still take effect.
- Before `hasalad` and the console start, `hasala-purge-replay` runs
  `hasalad purge-user --replay-ledger`. It purges again each account in the
  ledger that the database still has, without a second goodbye email. It also
  removes the lines that are older than 60 days (the privacy policy's
  "Restore records" row).
- The ledger also records holder freezes and unfreezes, device removals,
  password changes, resets and removals, passkey removals (by the holder, and
  the old passkeys that a recovery removes), waitlist leaves, waitlist
  entries deleted because their invite email bounced, the first time the
  12 words were shown after a signup that skipped them, a sign-out of all
  sessions (`logout-all`), an email change, and an invite that the operator
  revoked (console or `hasalad invite revoke`), with internal ids and times
  only (a passkey by its credential id, an invite by its id; never an
  address). These are written after the
  change commits; a failed write is logged and does not stop the change. A
  console revocation that the ledger did not record shows an error page. The
  console runs as `hasala-console` and appends through the `hasala-ledger`
  group, so `purged` and `purged.lock` are mode `0660`. The
  replay applies each one again: a freeze (unless an unfreeze came later), an
  unfreeze (when it is the account's latest freeze or unfreeze in the ledger
  and the restored freeze is not newer than it; it never lifts an operator's
  freeze, and the restored sessions end; every unfreeze line also retires the
  restored freeze links dated before it and restores its `account_unfrozen`
  event, whether or not the restored row is frozen), a removed device (only when the device that signed the removal is still in the
  database; otherwise it only signs that device out, and the summary counts
  it), a password change (the restored password is cleared and every session
  ends, so a password-only account gets back in with its 12 words), a removed
  passkey (the passkey and its key wrap go, and the sessions it signed in end,
  with every passkey session the server cannot attribute; an account left with
  no passkey and no password gets back in with its 12 words), a waitlist leave,
  a bounced-invite deletion (the entry goes again and its invite is
  revoked), and a first view of the 12 words (the account's "words not yet
  seen" flag is cleared again, so Home does not ask for them again), a
  sign-out of all sessions (every session created at or before that second
  ends again, and its push token goes), an email change (the ledger has no
  address, so the replay cannot put the new one back: when the restored
  address was verified before the change, the account is marked for
  re-verification and as undeliverable, its unused freeze links and email
  codes are burned, and no alert with a freeze link goes to that address until
  the holder verifies or changes it again), and an operator's invite
  revocation (the invite is revoked again, and its waitlist entry goes back to
  the list when it has no other open invite). A replay never leaves an account frozen with no passkey and no
  password, because then nothing could lift the freeze: it lifts that holder
  freeze (the sessions stay ended), records an `account_unfrozen` event, and
  the summary counts it. The holder gets back in with the 12 words. The
  operator's unfreeze (`hasalad account unfreeze`, refer to "Lift a freeze
  that the holder cannot lift") appends the same `unfreeze` line as the
  holder's, and the replay applies it again in the same way. Operator
  freezes are not recorded: no console or CLI command freezes an account yet.
- A `hasalad` from the branch `onboarding/w5-review-fixes` on skips a line of a
  kind it does not know, with a log line (`purgeledger: skipped an entry of a
  kind this hasalad does not know`), keeps it in the file until it is past
  retention, and replays the rest. A line of a known kind that is malformed
  still fails the whole ledger.
- An older `hasalad` fails on a kind it does not know. A `hasalad` from before
  the event kinds (before `legal/accuracy-fixes`) fails on every line with a
  third field; one from before `onboarding/phrase-on-home` fails on
  `phrase-seen`, and one from before `onboarding/w5-review-fixes` fails on
  `sessions`, `email` and `invite-revoked`. A `hasalad` from before
  `hardening/ledger-and-limits` skips these three kinds, so its replay does
  not apply them again. A `hasalad` from before `security/server-lifecycle`
  skips `purge-cancelled`, so its replay purges an account whose deletion was
  cancelled. Before you roll back to one of these, keep a copy of the ledger and remove
  the lines it cannot read.
- A freeze that a later unfreeze lifted is not applied again, but the sessions
  it ended stay ended: every session of that account created before the second
  of the freeze ends again with its push token, and the summary counts this
  with the sign-outs of all sessions. A session created in the same second as
  the freeze stays, because the ledger has whole seconds and the session that
  the unfreeze kept can be from that second.
- A single sign-out (`logout`) is not recorded: a session has no internal id
  for the ledger. A restore can bring back a session that was signed out
  alone. The holder can end it again with a sign-out of all sessions.
- If the replay fails, `hasalad` and the console do not start.
- Each daily and pre-migration backup keeps an encrypted copy of the ledger
  (`hasala-ledger-<tag>-<time>.tar.age`). A backup fails when the ledger file
  is missing.

Values in angle brackets are placeholders. Nothing real belongs in this file.

## Steps

1. Stop the API, the tunnel and the console. The database keeps running.

   ```sh
   sudo systemctl stop hasalad cloudflared-hasala hasala-console
   ```

2. Keep the host's ledger. It is newer than every backup. Do not replace it
   with the copy from a backup.

   ```sh
   sudo cp -a /var/lib/hasala-ledger/purged /root/purged.before-restore
   ```

   If the host lost the ledger (for example, a new host), decrypt the ledger
   copy of every backup that you have, on the Mac that holds the identity, and
   merge them. Put the result on the host as
   `/var/lib/hasala-ledger/purged`, owner `hasala`, group `hasala-ledger`,
   mode `0660`.

   ```sh
   for f in hasala-ledger-*.tar.age; do age -d -i <identity> "$f" | tar -xOf - purged; done | sort -u > purged
   ```

3. Load the dump. Decrypt it on the Mac that holds the identity, and stream it
   to the host. The plaintext dump is never written to a file.

   ```sh
   age -d -i <identity> hasala-daily-<time>.dump.age \
     | ssh <host> sudo -u hasala-migrate pg_restore --host=/run/hasala-postgresql \
         --username=hasala_migrate --dbname=hasala --clean --if-exists \
         --single-transaction --exit-on-error
   ```

   Try this command on a VM before the first restore on the host.

4. Add 1 to the log generation, so that each iPhone knows that the server was
   restored.

   ```sh
   n=$(sudo cat /var/lib/hasala-ledger/generation 2>/dev/null || echo 1)
   echo $((n + 1)) | sudo -u hasala tee /var/lib/hasala-ledger/generation
   ```

5. Start Hasala, and examine the replay.

   ```sh
   sudo systemctl start hasala.target
   systemctl show -P Result hasala-purge-replay
   journalctl -u hasala-purge-replay -o cat | tail -1
   ```

   The result is `success`, and the last line is
   `purge ledger: <n> entries, <m> account(s) purged again (...), ...`, with
   the counts of each event applied again. If the count of device removals
   whose signer is not in the database is above 0, ask the holder to remove
   that iPhone again. If the count of email changes is above 0, those
   accounts are back on their old address and marked for re-verification: the
   holder changes the address again in the app. The journal
   shows counts only, never an account id.

## Lift a freeze that the holder cannot lift

The holder lifts a freeze only with a passkey, or a device and a password,
that is older than the event the freeze is dated to. A freeze from the link in
a "Your recovery phrase was used" alert is dated to that recovery, and the
recovery replaced or re-dated every factor. A frozen account also refuses a
new recovery and a password reset. Then only the operator can lift it.

Lifting a freeze, by the holder or the operator, retires every unused freeze
link of the account, and a link dated before the latest lift no longer freezes
it. A link from a later alert still works. So an older link cannot freeze the
account again after the holder changed a password. The cost: when someone who
holds an older factor lifts a freeze, the holder's older links stop working
too, and the holder relies on later alerts, the in-app lockdown or the operator.

1. Make sure that the request comes from the holder. Ask them to write to
   support from the account's address, and confirm it out of band. Do not
   lift a freeze on the strength of one message.
2. Lift the freeze. Type the account id two times.

   ```sh
   sudo hasala-admin account unfreeze <ACCOUNT_ID> --confirm <ACCOUNT_ID>
   ```

   The output is `account <ACCOUNT_ID>: unfrozen (was frozen by the holder);
   every session is signed out`, or `account <ACCOUNT_ID>: was not frozen;
   nothing changed`. The command lifts any freeze, ends every session,
   records an `account_unfrozen` event, queues the unfreeze alert to the
   account's address (`hasalad serve` sends it) and writes an `admin_audit`
   row (`cli.account_unfreeze`). It then appends an `unfreeze` line to the
   ledger, so a later restore does not bring the freeze back. If that append
   fails, the command says so and exits 1: the account is unfrozen, but a
   restore would freeze it again. Run the command again after a restore in
   that case.
3. The factors that the recovery made work again. Tell the holder to sign in
   and remove each device, passkey or password that they do not know.

## Limit

The ledger copy in a backup is as old as the backup. If the host lost its
ledger, an account that was deleted after the newest ledger copy that you have
comes back with the restore. Delete it again with
`sudo hasala-admin purge-user <ACCOUNT_ID> --confirm <ACCOUNT_ID>`.
