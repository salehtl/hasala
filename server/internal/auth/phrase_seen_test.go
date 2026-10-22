package auth

import (
	"errors"
	"testing"
	"time"

	"github.com/salehtl/hasala/server/internal/keyproto"
	"github.com/salehtl/hasala/server/internal/purgeledger"
)

func (f *keyFixture) phraseSeenAt() *time.Time {
	f.t.Helper()
	var at *time.Time
	if err := f.pool.QueryRow(bgctx, `SELECT phrase_seen_at FROM account_keys WHERE user_id = $1`, f.user).Scan(&at); err != nil {
		f.t.Fatal(err)
	}
	return at
}

func TestTheFirstViewMarksTheWordsSeenAndSurvivesARestore(t *testing.T) {
	f := newKeyFixtureUnbootstrapped(t)
	path, rec := ledgerRecorder(t)
	acct := &Accounts{Pool: f.pool, Sessions: f.sessions, Passkeys: f.passkeys, StepUp: f.stepUp, Mail: &Mailer{},
		Now: f.clock.now, Record: rec}
	b := f.bootstrap(f.device, keyproto.AuthKindPasskey, f.attestation(), true)
	b.PhraseUnseen = true
	if _, err := f.keys.Bootstrap(bgctx, f.info(f.token), b); err != nil {
		t.Fatal(err)
	}
	if at := f.phraseSeenAt(); at != nil {
		t.Fatalf("phrase_seen_at %v after a bootstrap without the words", at)
	}
	f.clock.advance(10*time.Minute + 300*time.Millisecond)
	first := f.clock.now()
	for range 2 {
		if _, err := acct.ViewPhrase(bgctx, f.info(f.token), f.stepUpPasskey(f.token, keyproto.ActionPhraseView)); err != nil {
			t.Fatal(err)
		}
		f.clock.advance(time.Minute)
	}
	if at := f.phraseSeenAt(); at == nil || !at.Equal(first) {
		t.Fatalf("phrase_seen_at %v, want the first view %v", at, first)
	}
	if n := f.count(`SELECT count(*) FROM auth_events WHERE kind = 'phrase_viewed'`); n != 2 {
		t.Fatalf("%d phrase_viewed events, want one per view", n)
	}
	entries := readLedger(t, path)
	if len(entries) != 1 || entries[0].Kind != purgeledger.KindPhraseSeen || entries[0].ID != f.user {
		t.Fatalf("ledger %+v, want one first view", entries)
	}
	if rep, err := Reapply(bgctx, f.pool, entries, f.clock.now()); err != nil || rep != (ReapplyReport{}) {
		t.Fatalf("a replay on the live database %+v %v, want nothing", rep, err)
	}
	if _, err := f.pool.Exec(bgctx, `UPDATE account_keys SET phrase_seen_at = NULL WHERE user_id = $1`, f.user); err != nil {
		t.Fatal(err)
	}
	rep, err := Reapply(bgctx, f.pool, entries, f.clock.now())
	if err != nil || rep.PhrasesSeen != 1 {
		t.Fatalf("reapply %+v %v, want one first view", rep, err)
	}
	if at := f.phraseSeenAt(); at == nil || at.After(first) || at.Before(first.Add(-time.Second)) {
		t.Fatalf("after the replay phrase_seen_at %v", at)
	}
	if rep, err := Reapply(bgctx, f.pool, entries, f.clock.now()); err != nil || rep.PhrasesSeen != 0 {
		t.Fatalf("a second replay %+v %v", rep, err)
	}
}

func TestAFailedViewLeavesTheWordsUnseen(t *testing.T) {
	f := newKeyFixtureUnbootstrapped(t)
	path, rec := ledgerRecorder(t)
	acct := &Accounts{Pool: f.pool, Sessions: f.sessions, Passkeys: f.passkeys, StepUp: f.stepUp, Mail: &Mailer{},
		Now: f.clock.now, Record: rec}
	b := f.bootstrap(f.device, keyproto.AuthKindPasskey, f.attestation(), true)
	b.PhraseUnseen = true
	if _, err := f.keys.Bootstrap(bgctx, f.info(f.token), b); err != nil {
		t.Fatal(err)
	}
	if _, err := f.owner.Exec(bgctx, `DELETE FROM account_key_wraps WHERE user_id = $1`, f.user); err != nil {
		t.Fatal(err)
	}
	if _, err := acct.ViewPhrase(bgctx, f.info(f.token), f.stepUpPasskey(f.token, keyproto.ActionPhraseView)); !errors.Is(err, ErrStepUpFailed) {
		t.Fatalf("a view with a passkey without a wrap: %v", err)
	}
	if at := f.phraseSeenAt(); at != nil {
		t.Fatalf("phrase_seen_at %v after a refused view", at)
	}
	if entries := readLedger(t, path); len(entries) != 0 {
		t.Fatalf("ledger %+v after a refused view", entries)
	}
}

func TestTheSyncedCheckIsABadRequestWhenTheCredentialIsMissing(t *testing.T) {
	f := newKeyFixtureUnbootstrapped(t)
	if err := checkSyncedPasskey(bgctx, f.pool, f.user, []byte("not-a-credential")); !errors.Is(err, ErrKeysMalformed) {
		t.Fatalf("a credential that is not there: %v", err)
	}
	if err := checkSyncedPasskey(bgctx, f.pool, f.user, f.credID); err != nil {
		t.Fatalf("the synced creating passkey: %v", err)
	}
	if _, err := f.owner.Exec(bgctx, `UPDATE webauthn_credentials SET backup_state = false WHERE user_id = $1`, f.user); err != nil {
		t.Fatal(err)
	}
	if err := checkSyncedPasskey(bgctx, f.pool, f.user, f.credID); !errors.Is(err, ErrKeysMalformed) {
		t.Fatalf("a passkey that is not backed up: %v", err)
	}
}
