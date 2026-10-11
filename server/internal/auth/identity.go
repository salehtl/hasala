// Package auth issues and resolves the opaque server-side session tokens every
// authenticated request carries, and owns the passkey ceremonies, device
// writers and the key-history log.
//
// Sign in with Apple and Google ID-token sign-in (ledgerd's /auth/exchange)
// was removed in the hasalad surgery (spec 02 §2.3, §2.4): a replayable bearer
// credential with no place in Hasala. Its JWKS cache and JWT checks moved to
// internal/googlejwt, which verifies Google-signed Pub/Sub and link tokens and
// never signs anyone in. What is left here is the account vocabulary the
// passkey ceremonies still use until the email account model replaces it
// (spec 02 §5.3, D-4; WS-3).
//
// # What a session token is, and what it is deliberately NOT
//
// A session token is an opaque 32-byte random string. It is not a JWT, carries
// no claims, and means nothing except "row present, unexpired, unrevoked" —
// which is what makes it revocable in one UPDATE.
//
// Sessions are DELIBERATELY WEAK. A session token alone must never be
// sufficient to register a new writer, delete the account or change an
// authenticator; whoever builds such a flow must not reach for
// Sessions.Resolve as the only gate — it answers "is this a live session",
// a strictly weaker question than "is this the account owner, present, on an
// enrolled device, right now" (spec 02 §8, step-up).
package auth

import (
	"crypto/sha256"
	"time"
)

// The identity vocabulary of users.idp. It is a closed set and part of
// SubjectHash's input. ledgerd's 'apple' and 'google' went with the ID-token
// exchange (spec 02 §2.3, §2.4): the passkey ceremony is the only thing that
// mints an identity, and the users.idp CHECK admits nothing else, until WS-3
// replaces the users table with the email-keyed account of spec 02 §5.3.
const IdPPasskey = "passkey"

// Identity is who a ceremony says the bearer is: a provider plus that
// provider's opaque subject string. The Subject is the raw value; it is hashed
// by SubjectHash before it goes anywhere near storage.
type Identity struct {
	IdP     string
	Subject string
	// IssuedAt is when the ceremony that produced this identity completed.
	IssuedAt time.Time
}

// SubjectHash is what `users.idp_sub_hash` stores: SHA-256 over
// "v2|" + idp + "|" + subject. The raw subject is never persisted.
//
// The "|" separator is not injective for arbitrary inputs, which is safe here
// only because idp is a closed vocabulary containing no "|" (validIdP and the
// users.idp CHECK), and a passkey subject is base64url of 32 random bytes, an
// alphabet that cannot contain one either.
func SubjectHash(idp, subject string) []byte {
	sum := sha256.Sum256([]byte("v2|" + idp + "|" + subject))
	return sum[:]
}

func validIdP(idp string) bool {
	return idp == IdPPasskey
}
