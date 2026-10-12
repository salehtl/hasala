package api

import (
	"crypto/rand"
	"time"

	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/auth"
)

// SessionResponse is the part of every session-minting answer these tests
// read (register/finish's SessionMintResponse, login/finish's
// SignInResponse).
type SessionResponse struct {
	SessionToken string `json:"session_token"`
	UserID       string `json:"user_id"`
}

// invite is a signup ready for register/begin: a printed invite, minted as
// `hasalad invite mint` does, and a proven signup ceremony on a fresh address
// written directly (signup/begin itself is routes_signup_test.go's subject).
// It returns the signup id.
func (h *harness) invite(note string) string {
	h.t.Helper()
	code, err := auth.MintInvite(bg, h.pool, auth.MintOptions{Note: note, Now: time.Now().UTC()})
	if err != nil {
		h.t.Fatal(err)
	}
	rnd := func() []byte {
		b := make([]byte, 32)
		_, _ = rand.Read(b)
		return b
	}
	id := uuid.NewString()
	now := time.Now().UTC()
	if _, err := h.pool.Exec(bg,
		`INSERT INTO signup_ceremonies (id, user_id, invite_code_hash, email_norm, email_tag, display_name,
		   email_proven, signup_nonce, created_at, expires_at)
		 VALUES ($1, gen_random_uuid(), $2, $3, $4, 'Test User', true, $5, $6, $7)`,
		id, auth.InviteCodeHash(code), "u-"+uuid.NewString()+"@example.test", rnd(), rnd(), now, now.Add(auth.SignupTTL)); err != nil {
		h.t.Fatal(err)
	}
	return id
}
