# Runbook: restore a backup on the QA host

A restore puts the database back to the time of a backup. An account that was
deleted after that time is in the dump again. The purge ledger stops it from
coming back:

- Each account deletion (`DELETE /api/v1/account` and `hasala-admin
  purge-user`) appends one line to `/var/lib/hasala-ledger/purged`: the random
  account id and the time. The append is part of the deletion. If it fails,
  nothing is deleted.
- Before `hasalad` and the console start, `hasala-purge-replay` runs
  `hasalad purge-user --replay-ledger`. It purges again each account in the
  ledger that the database still has, without a second goodbye email. It also
  removes the lines that are older than 60 days (the privacy policy's
  "Restore records" row).
- The ledger also records holder freezes and unfreezes, device removals,
  password changes, resets and removals, passkey removals (by the holder, and
  the old passkeys that a recovery removes), waitlist leaves, and waitlist
  entries deleted because their invite email bounced, with internal ids and
  times only (a passkey by its credential id). These are written after the
  change commits; a failed write is logged and does not stop the change. The
  replay applies each one again: a freeze (unless an unfreeze came later), a
  removed device (only when the device that signed the removal is still in the
  database; otherwise it only signs that device out, and the summary counts
  it), a password change (the restored password is cleared and every session
  ends, so a password-only account gets back in with its 12 words), a removed
  passkey (the passkey and its key wrap go, and the sessions it signed in end,
  with every passkey session the server cannot attribute; an account left with
  no passkey and no password gets back in with its 12 words), a waitlist leave,
  and a bounced-invite deletion (the entry goes again and its invite is
  revoked). Operator freezes are not recorded: no console or CLI command
  freezes or unfreezes an account yet.
- An older `hasalad` cannot read the new event lines. Before you roll back past
  this change, keep a copy of the ledger and remove the lines that have a third
  field.
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
   mode `0640`.

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
   that iPhone again. The journal
   shows counts only, never an account id.

## Limit

The ledger copy in a backup is as old as the backup. If the host lost its
ledger, an account that was deleted after the newest ledger copy that you have
comes back with the restore. Delete it again with
`sudo hasala-admin purge-user <ACCOUNT_ID> --confirm <ACCOUNT_ID>`.
