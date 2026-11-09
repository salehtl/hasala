# Runbook: restore a backup on the QA host

A restore puts the database back to the time of a backup. An account that was
deleted after that time is in the dump again. The purge ledger stops it from
coming back:

- Each account deletion (`DELETE /api/v1/account` and `hasala-admin
  purge-user`) appends one line to `/var/lib/hasala-ledger/purged`: the random
  account id and the time. The append is part of the deletion. If it fails,
  nothing is deleted. An append first cuts an incomplete last line, with a log
  line, and a write cut short is truncated back when possible and reports
  nothing written. When the failure comes after bytes may have reached the
  file and stayed there, a `purge-cancelled` line follows. If the database commit fails and the account is still
  there, a `purge-cancelled` line follows too. The replay does not
  purge that account unless a later deletion line names it. A deletion holds
  its account from before its line until its commit is settled. A replay leaves
  a held account to the next replay and prints
  `purge ledger: <n> account(s) have a deletion in progress and were left for the next replay`.
  A replay also reads the ledger again once it holds the row locks, so a
  `purge-cancelled` line already written keeps the account. If the line cannot
  be cancelled (for example, the database cannot be read after the failed
  commit, or the ledger stops taking writes after a part of the line that
  could not be truncated back), or the
  process stops between the append and the commit, the line stays and the next replay purges the account
  with no goodbye email. The holder asked for that deletion: the answer in the
  first case says that it may still take effect.
- Before `hasalad` and the console start, `hasala-purge-replay` runs
  `hasalad purge-user --replay-ledger`. It purges again each account in the
  ledger that the database still has, without a second goodbye email. It also
  removes the lines that are older than 60 days (the privacy policy's
  "Restore records" row).
- The ledger also records holder freezes and unfreezes, device removals,
  password changes, resets and removals, passkey removals (by the holder, and
  the old passkeys that a recovery removes), key wrap deletions, waitlist
  leaves, waitlist entries deleted because their invite email bounced, the first time the
  12 words were shown after a signup that skipped them, a sign-out of all
  sessions (`logout-all`), an email change, and an invite that the operator
  revoked (console or `hasalad invite revoke`), with internal ids and times
  only (a passkey by its credential id, an invite by its id; never an
  address). For a change made through `hasalad serve`, the line is kept in
  `restore_ledger_held` in the change's transaction, moved to the file after
  the commit, and retried by a sweep at start and every minute. The limit: a
  stop followed by a restore before any restart loses a held line. The console
  and the operator commands (`hasalad account unfreeze`, `hasalad invite
  revoke`) append after their commit, and a failed append does not undo the
  change. A
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
  no passkey and no password gets back in with its 12 words; while the 12 words
  are unseen, a replay keeps the passkey that holds the account's only key
  wrap), a deleted key wrap (the wrap goes again unless it was put back in the
  same second or later, and the last wrap of an account with unseen words
  stays), a waitlist leave,
  a bounced-invite deletion (the entry goes again and its invite is
  revoked), and a first view of the 12 words (the account's "words not yet
  seen" flag is cleared again, so Home does not ask for them again), a
  sign-out of all sessions (every session created at or before that second
  ends again, and its push token goes), an email change (the ledger has no
  address, so the replay cannot put the new one back: when the restored
  address was verified before the change, the account is marked for
  re-verification and as undeliverable, its unused freeze links and email
  codes are burned, and no alert with a freeze link goes to that address, no
  recovery can begin or finish (the answer is the same 404 as a frozen account)
  and no password reset code goes to it, until the holder verifies or changes it
  again), and an operator's invite
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
  still fails the whole ledger. An append and the replay cut an incomplete last
  line, with a log line (`purgeledger: cut an incomplete last line`). A last
  line with no newline that reads as a whole entry is refused and needs the
  operator (refer to "If the replay fails" below).
- An older `hasalad` fails on a kind it does not know. A `hasalad` from before
  the event kinds (before `legal/accuracy-fixes`) fails on every line with a
  third field; one from before `onboarding/phrase-on-home` fails on
  `phrase-seen`, and one from before `onboarding/w5-review-fixes` fails on
  `sessions`, `email`, `invite-revoked` and `wrap`. A `hasalad` from before
  `hardening/ledger-and-limits` skips these three kinds, so its replay does
  not apply them again. A `hasalad` from before `security/server-lifecycle`
  skips `purge-cancelled`, so its replay purges an account whose deletion was
  cancelled. Before you roll back to one of these, keep a copy of the ledger.
  Then, in this order: list the accounts whose latest deletion or
  `purge-cancelled` line is `purge-cancelled`; remove every deletion line of
  those accounts, because the build purges an account for any deletion line;
  remove all `purge-cancelled` lines; remove each other line the build cannot
  read.
- A freeze that a later unfreeze lifted is not applied again, but the sessions
  it ended stay ended: every session of that account created before the second
  of the freeze ends again with its push token, and the summary counts this
  with the sign-outs of all sessions. A session created in the same second as
  the freeze stays, because the ledger has whole seconds and the session that
  the unfreeze kept can be from that second.
- A single sign-out (`logout`) is not recorded: a session has no internal id
  for the ledger. A restore can bring back a session that was signed out
  alone. The holder can end it again with a sign-out of all sessions.
- If the replay fails, `hasalad` and the console do not start. When the error
  says that the file ends in a whole entry with no newline, add the newline or
  remove the line. When an older build already joined a new line to an
  incomplete one (the error names a line that is not a ledger entry), remove
  the joined line.
- Each daily and pre-migration backup keeps an encrypted copy of the ledger
  (`hasala-ledger-<tag>-<time>.tar.age`). A backup fails when the ledger file
  is missing.

Values in angle brackets are placeholders. Nothing real belongs in this file.

## Steps

1. Stop the API, the tunnel, the console and the health probes, so that the
   restore does not alert. The database keeps running.

   ```sh
   sudo systemctl stop hasalad cloudflared-hasala hasala-console hasala-health.timer
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

4. Move the log generation, so that each iPhone knows that the server was
   restored.

   ```sh
   sudo hasala-bump-generation
   ```

   The new value is the current time in seconds, or 1 more than the old value
   when that is higher. So it differs from every value that an iPhone holds,
   also on a new host that lost the file. Do not restore the file from a
   backup: a backup can be older than the last restore.

   `hasalad serve` also checks this. It keeps
   `/var/lib/hasala-ledger/generation.seal`. When it finds the database replaced
   and the file not raised, it raises the generation and logs a warning. Do this
   step anyway: the seal is not in the backups, and a new host starts without
   one.

5. Start Hasala, and examine the replay. This also starts the health probes
   again.

   ```sh
   sudo systemctl start hasala.target
   systemctl show -P Result hasala-purge-replay
   journalctl -u hasala-purge-replay -o cat | tail -2
   ```

   The result is `success`, and the summary line is
   `purge ledger: <n> entries, <m> account(s) purged again (...), ...`, with
   the counts of each event applied again, key wrap deletions included. When a
   deletion was in progress, its line about the accounts left for the next
   replay comes after this one. If the count of device removals
   whose signer is not in the database is above 0, ask the holder to remove
   that iPhone again. If the count of email changes is above 0, those
   accounts are back on their old address and marked for re-verification: the
   holder changes the address again in the app. If the count of
   `passkey removal(s) kept back because that passkey is the only way to show the unseen 12 words`
   is above 0, ask the holder to view the words, then remove that passkey
   again. A later replay does not apply the old line (the database notes the
   keep-back in `reapply_kept_credentials`), so only the new removal takes the
   passkey. The journal
   shows counts only, never an account id.

## Lift a freeze that the holder cannot lift

The holder lifts a freeze only with a passkey, or a device and a password,
that is older than the event the freeze is dated to. A freeze from the link in
a "Your recovery phrase was used" alert is dated to that recovery, and the
recovery replaced or re-dated every factor. A frozen account also refuses a
new recovery and a password reset. Then only the operator can lift it.

A device freeze is not dated back to a sign-out asked for from a session on that
same device, whichever proof it used, passkey or device (sign out everywhere,
freeze, unfreeze, password set, change, removal or reset with a code, passkey
removal). It is still dated back to a change from another device's session, from
a session on no device, or made with no session at all (recovery, a reset
finished on a new iPhone).

`GET /api/v1/account` reports `holder_can_lift` while the account is frozen,
for the session that asks:
false for an operator freeze, and false when no passkey is older than the
freeze's trigger and that session's own device, with a password, is not older.
The app then shows no
Unfreeze. It shows "Talk to a person" and asks the holder to write to us from
the account's address, so expect the request below.

Lifting a freeze, by the holder or the operator, retires every unused freeze
link of the account, and a link dated before the latest lift no longer freezes
it. A link from
a later alert still works. So an older link cannot freeze the
account again after the holder changed a password. A lift through any older
factor retires the links, so after a lift the holder relies on later alerts, the
in-app lockdown or the operator.

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
   restore would freeze it again. Run the command again once the ledger takes
   writes: it records the missed unfreeze. `hasalad invite revoke` does the
   same: a rerun records the missed revocation.
3. The factors that the recovery made work again. Tell the holder to sign in
   and remove each device, passkey or password that they do not know.

## Let a holder recover after a restored email change

The replay can put an account back on an address that the holder removed. That
address cannot begin a recovery or a password reset until a signed-in device
verifies or changes it. A holder who has no signed-in device and still uses that address needs the
operator.

1. Make sure that the request comes from the holder, and that the holder still
   controls this address, as in "Lift a freeze that the holder cannot lift".
   Do not do this on the strength of one message from that address.
2. Clear the mark.

   ```sh
   sudo -u hasala-migrate psql --host=/run/hasala-postgresql --username=hasala_migrate --dbname=hasala \
     -c "UPDATE users SET reverify_requested_at = NULL, email_undeliverable_at = NULL, email_verified_at = now() WHERE id = '<ACCOUNT_ID>'"
   ```

   Set `email_verified_at` too. The replay runs before each start of `hasalad`
   and marks the account again when the address was verified before the email
   change in the ledger.

3. The holder recovers with the emailed code and the 12 words.

## Limit

The ledger copy in a backup is as old as the backup. If the host lost its
ledger, an account that was deleted after the newest ledger copy that you have
comes back with the restore. Delete it again with
`sudo hasala-admin purge-user <ACCOUNT_ID> --confirm <ACCOUNT_ID>`.
