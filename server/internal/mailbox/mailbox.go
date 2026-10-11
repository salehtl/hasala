// Package mailbox is ledgerd's Gmail transaction-mailbox OAuth broker
// (2026-08-11-gmail-transaction-mailbox-design (ledgerd design archive),
// decisions D2 and D3): a user who would rather not forward bank mail by
// hand can instead grant this server a read scope over a burner Gmail
// account, and the PWA fetches that mailbox itself. This package brokers
// only the OAuth exchange that makes the fetch possible; it never fetches a
// message.
//
// # D2 — the client fetches; the server never reads the mailbox
//
// The spec's own words: "The PWA calls the Gmail API directly
// (history.list / messages.get?format=raw) ... a server-side poller makes
// the server a permanent, elective plaintext reader holding a live Google
// credential, against both the sealing direction and the recorded
// 2026-08-09 decision that client-side fetch 'is the only design that makes
// the server blind in transit as well as at rest.'" This package is where
// that rule is enforced by absence rather than by a check somewhere else:
// there is no Gmail API base URL anywhere below it, and [Google]'s fields —
// AuthURL, TokenURL, RevokeURL — name Google's OAuth surface and nothing
// past it. A future change that needs this package to read
// messages.get or history.list is a change to the design this package
// exists to hold the line on, not a field to add here.
//
// # D3 — the refresh token lives client-side; the server is a stateless
// token broker that stores a digest
//
// Google's web-application OAuth clients require the client secret at both
// code exchange and refresh, and Google does not issue durable refresh
// tokens to secretless browser clients. So this server holds the secret
// (config.MailboxConfig.GoogleClientSecret, env-only) and performs the
// code→token exchange and every refresh — but stores no live token.
// [Google.Exchange] and [Google.Refresh] hold a [Tokens] value only in
// memory, for the span of one call; [TokenHash] — sha256(refresh token),
// the exact sessions.token_hash posture — is the only representation
// [Grants] ever persists, so a dump of mailbox_grants yields no mailbox
// credential.
//
// D3a is why the digest is a binding and not a convenience: a digestless
// broker would be an oracle, letting any authenticated session present any
// stolen or superseded refresh token and have this server countersign it
// with the client secret. [Grants.VerifyAndTouch] closes that — it refuses
// unless the caller presents a hash matching the CALLING user's own grant
// row, and it collapses "no grant for this user", "wrong digest" and
// (implicitly) "this token belongs to someone else" into the single
// [ErrGrantMismatch], because distinguishing them in a response would be an
// oracle over who else holds a grant. [Grants.Upsert] rotates the stored
// digest in the same statement a reconnect writes (D9's holdership
// rotation: UNIQUE(user_id, provider) makes a reconnect an UPSERT), so a
// superseded device's next broker call fails closed rather than racing the
// new holder — proven by TestSupersededTokenDigestFailsClosed.
package mailbox
