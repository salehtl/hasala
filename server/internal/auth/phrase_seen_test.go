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

func TestTheWordsSeenSurviveARestore(t *testing.T) {
	f := newKeyFixtureUnbootstrapped(t)
	path, rec := ledgerRecorder(t)
	acct := &Accounts{Pool: f.pool, Now: f.clock.now, Record: rec}
	if err := acct.NotePhraseSeen(bgctx, f.user); !errors.Is(err, ErrNoKeys) {
		t.Fatalf("an account without keys: %v", err)
	}
	b := f.bootstrap(f.device, keyproto.AuthKindPasskey, f.attestation(), true)
	b.PhraseUnseen = true
	if _, err := f.keys.Bootstrap(bgctx, f.info(f.token), b); err != nil {
		t.Fatal(err)
	}
	if at := f.phraseSeenAt(); at != nil {
		t.Fatalf("phrase_seen_at %v after a bootstrap without the words", at)
	}
	f.clock.advance(time.Hour + 300*time.Millisecond)
	for range 2 {
		if err := acct.NotePhraseSeen(bgctx, f.user); err != nil {
			t.Fatal(err)
		}
	}
	if at := f.phraseSeenAt(); at == nil || !at.Equal(f.clock.now()) {
		t.Fatalf("phrase_seen_at %v, want %v", at, f.clock.now())
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
	if at := f.phraseSeenAt(); at == nil || at.After(f.clock.now()) || at.Before(f.clock.now().Add(-time.Second)) {
		t.Fatalf("after the replay phrase_seen_at %v", at)
	}
	if rep, err := Reapply(bgctx, f.pool, entries, f.clock.now()); err != nil || rep.PhrasesSeen != 0 {
		t.Fatalf("a second replay %+v %v", rep, err)
	}
}

func TestAReplayNeverMarksWordsSeenBeforeTheKeysExisted(t *testing.T) {
	f := newKeyFixtureUnbootstrapped(t)
	b := f.bootstrap(f.device, keyproto.AuthKindPasskey, f.attestation(), true)
	b.PhraseUnseen = true
	if _, err := f.keys.Bootstrap(bgctx, f.info(f.token), b); err != nil {
		t.Fatal(err)
	}
	early := []purgeledger.Entry{{ID: f.user, At: f.clock.now().Add(-time.Hour), Kind: purgeledger.KindPhraseSeen}}
	if rep, err := Reapply(bgctx, f.pool, early, f.clock.now()); err != nil || rep.PhrasesSeen != 0 {
		t.Fatalf("reapply %+v %v, want nothing", rep, err)
	}
	if at := f.phraseSeenAt(); at != nil {
		t.Fatalf("phrase_seen_at %v", at)
	}
}

func TestPhraseUnseenIsOnlyForTheSyncedCreatingPasskey(t *testing.T) {
	t.Run("no PRF wrap", func(t *testing.T) {
		f := newKeyFixtureUnbootstrapped(t)
		b := f.bootstrap(f.device, keyproto.AuthKindPasskey, f.attestation(), false)
		b.PhraseUnseen = true
		if _, err := f.keys.Bootstrap(bgctx, f.info(f.token), b); !errors.Is(err, ErrKeysMalformed) {
			t.Fatalf("bootstrap: %v", err)
		}
	})
	for _, c := range []struct{ name, set string }{
		{"not backed up", "backup_state = false"},
		{"not backup eligible", "backup_eligible = false, backup_state = false"},
	} {
		t.Run(c.name, func(t *testing.T) {
			f := newKeyFixtureUnbootstrapped(t)
			if _, err := f.owner.Exec(bgctx, `UPDATE webauthn_credentials SET `+c.set+` WHERE user_id = $1`, f.user); err != nil {
				t.Fatal(err)
			}
			b := f.bootstrap(f.device, keyproto.AuthKindPasskey, f.attestation(), true)
			b.PhraseUnseen = true
			if _, err := f.keys.Bootstrap(bgctx, f.info(f.token), b); !errors.Is(err, ErrKeysMalformed) {
				t.Fatalf("bootstrap: %v", err)
			}
			if _, err := f.keys.Bootstrap(bgctx, f.info(f.token), f.bootstrap(f.device, keyproto.AuthKindPasskey, f.attestation(), true)); err != nil {
				t.Fatal(err)
			}
			if f.phraseSeenAt() == nil {
				t.Fatal("an ordinary bootstrap left the words unseen")
			}
		})
	}
}
