/**
 * One RFC822 helper the mailbox lane needs in two places, and the reason it is
 * its own module rather than a copy in each.
 *
 * # The bug it exists to close
 *
 * `@ledger/client/mail/authres` bounds its input at 256 KiB and answers
 * `parse_error` above it — a deliberate refusal to unfold an attacker-sized
 * header block. Both callers here used to hand it the WHOLE decoded message,
 * whose cap is `MAILBOX_MAX_MESSAGE_BYTES` (1,000,000). So every message between
 * 256 KiB and 1 MB — an ordinary HTML bank alert with embedded images is easily
 * that — failed gate 1 on its size alone, no matter how good its
 * Authentication-Results were, and could never auto-file.
 *
 * The A-R ceiling is a bound on the HEADER BLOCK, which is what
 * {@link headerBlock} hands it. Nothing about the verdict changes: `authres`'s
 * own unfolder already stops at the first blank line, so slicing there gives it
 * byte-for-byte the same fields it would have read — only now the megabyte of
 * body below is not counted against a header budget.
 *
 * The ceiling itself lives in `client/src/mail/authres.ts`, which this lane does
 * not own; slicing on this side is the whole fix and needs no change there.
 */

/**
 * The header block of a raw RFC822 message: everything before the first blank
 * line, which is where the headers end (RFC 5322 §2.1).
 *
 * A message with no blank line at all is all headers by that definition, so it
 * is returned whole — the caller's parser bounds it, and inventing a truncation
 * point here would be guessing at where a malformed message's fields stop.
 */
export function headerBlock(raw: string): string {
  const end = /\r\n\r\n|\n\n|\r\r/.exec(raw);
  return end === null ? raw : raw.slice(0, end.index);
}
