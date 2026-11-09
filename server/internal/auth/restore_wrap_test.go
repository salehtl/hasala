package auth

import (
	"bytes"
	"errors"
	"testing"
	"time"

	"github.com/salehtl/hasala/server/internal/keyproto"
	"github.com/salehtl/hasala/server/internal/purgeledger"
)

func (f *keyFixture) deleteWrapOf(cred []byte) error {
	f.t.Helper()
	return f.keys.DeleteWrap(bgctx, f.info(f.token), cred, f.stepUpPasskey(f.token, keyproto.ActionKeysWrapDelete, cred))
}

func TestAWrapDeletionIsRecordedAndSurvivesARestore(t *testing.T) {
	f := newKeyFixture(t).guarded()
	path, rec := ledgerRecorder(t)
	f.keys.Record = rec
	second, _, err := f.addOver(f.token, f.device, true)
	if err != nil {
		t.Fatal(err)
	}
	wrap := saveRow(t, f.pool, "account_key_wraps", "credential_id = $1", second.CredID)
	f.clock.advance(2 * time.Second)

	if err := f.deleteWrapOf(second.CredID); err != nil {
		t.Fatal(err)
	}
	entries := readLedger(t, path)
	if len(entries) != 1 || entries[0].Kind != purgeledger.KindWrap || entries[0].ID != f.user ||
		!bytes.Equal(entries[0].Credential, second.CredID) {
		t.Fatalf("ledger %+v, want the deleted wrap", entries)
	}

	restoreRow(t, f.pool, "account_key_wraps", wrap)
	rep, err := Reapply(bgctx, f.pool, entries, f.clock.now())
	if err != nil || rep.Wraps != 1 || rep.Passkeys != 0 {
		t.Fatalf("reapply %+v %v, want one wrap", rep, err)
	}
	if n := f.count(`SELECT count(*) FROM account_key_wraps WHERE credential_id = $1`, second.CredID); n != 0 {
		t.Fatal("the deleted wrap came back")
	}
	if n := f.count(`SELECT count(*) FROM webauthn_credentials WHERE credential_id = $1`, second.CredID); n != 1 {
		t.Fatal("the replay removed the passkey whose wrap was deleted")
	}
	if n := f.count(`SELECT count(*) FROM account_key_wraps WHERE credential_id = $1`, f.credID); n != 1 {
		t.Fatal("the other passkey's wrap went")
	}
	if _, err := f.sessions.Resolve(bgctx, f.token); err != nil {
		t.Fatalf("a wrap replay ended a session: %v", err)
	}
	if rep, err := Reapply(bgctx, f.pool, entries, f.clock.now()); err != nil || rep.Wraps != 0 {
		t.Fatalf("a second replay %+v %v", rep, err)
	}
}

func TestAReplayLeavesAWrapPutAgainAfterItsDeletion(t *testing.T) {
	f := newKeyFixture(t).guarded()
	path, rec := ledgerRecorder(t)
	f.keys.Record = rec
	second, _, err := f.addOver(f.token, f.device, true)
	if err != nil {
		t.Fatal(err)
	}
	wrap := saveRow(t, f.pool, "account_key_wraps", "credential_id = $1", second.CredID)
	f.clock.advance(2 * time.Second)
	if err := f.deleteWrapOf(second.CredID); err != nil {
		t.Fatal(err)
	}
	entries := readLedger(t, path)
	restoreRow(t, f.pool, "account_key_wraps", wrap)

	for name, putAt := range map[string]time.Time{
		"the same second": entries[0].At,
		"a later second":  entries[0].At.Add(time.Second),
	} {
		if _, err := f.pool.Exec(bgctx, `UPDATE account_key_wraps SET created_at = $2 WHERE credential_id = $1`,
			second.CredID, putAt); err != nil {
			t.Fatal(err)
		}
		if rep, err := Reapply(bgctx, f.pool, entries, f.clock.now()); err != nil || rep.Wraps != 0 {
			t.Fatalf("%s: reapply %+v %v", name, rep, err)
		}
		if n := f.count(`SELECT count(*) FROM account_key_wraps WHERE credential_id = $1`, second.CredID); n != 1 {
			t.Fatalf("%s: the replay removed a wrap put after the deletion", name)
		}
	}
}

func TestAReplayNeverTakesTheLastWrapOfAnAccountWhoseWordsAreUnseen(t *testing.T) {
	f := newKeyFixtureUnbootstrapped(t)
	b := f.bootstrap(f.device, keyproto.AuthKindPasskey, f.attestation(), true)
	b.PhraseUnseen = true
	if _, err := f.keys.Bootstrap(bgctx, f.info(f.token), b); err != nil {
		t.Fatal(err)
	}
	entries := []purgeledger.Entry{{ID: f.user, At: f.clock.now().Add(time.Hour), Kind: purgeledger.KindWrap, Credential: f.credID}}
	if rep, err := Reapply(bgctx, f.pool, entries, f.clock.now()); err != nil || rep.Wraps != 0 {
		t.Fatalf("reapply %+v %v", rep, err)
	}
	if n := f.count(`SELECT count(*) FROM account_key_wraps WHERE user_id = $1`, f.user); n != 1 {
		t.Fatal("the replay took the wrap the 12 words still depend on")
	}
}

func TestAWrapDeletionThatChangesNothingRecordsNothing(t *testing.T) {
	f := newKeyFixture(t).guarded()
	path, rec := ledgerRecorder(t)
	f.keys.Record = rec
	missing := bytes.Repeat([]byte{0x5a}, 20)
	if err := f.deleteWrapOf(missing); err != nil {
		t.Fatalf("deleting a wrap that is not there: %v", err)
	}
	if entries := readLedger(t, path); len(entries) != 0 {
		t.Fatalf("ledger %+v after deleting nothing", entries)
	}

	if err := f.keys.DeleteWrap(bgctx, f.info(f.token), f.credID, nil); !errors.Is(err, ErrStepUpRequired) {
		t.Fatalf("a deletion with no step-up: %v", err)
	}
	if entries := readLedger(t, path); len(entries) != 0 {
		t.Fatalf("ledger %+v after a refused deletion", entries)
	}
	if n := f.count(`SELECT count(*) FROM account_key_wraps WHERE credential_id = $1`, f.credID); n != 1 {
		t.Fatal("a refused deletion removed the wrap")
	}
}

func (f *keyFixture) bootstrapWordsUnseen() {
	f.t.Helper()
	b := f.bootstrap(f.device, keyproto.AuthKindPasskey, f.attestation(), true)
	b.PhraseUnseen = true
	if _, err := f.keys.Bootstrap(bgctx, f.info(f.token), b); err != nil {
		f.t.Fatal(err)
	}
}

func TestAReplayKeepsThePasskeyTheUnseenWordsDependOn(t *testing.T) {
	f := newKeyFixtureUnbootstrapped(t)
	f.bootstrapWordsUnseen()
	entries := []purgeledger.Entry{{ID: f.user, At: f.clock.now().Add(time.Hour), Kind: purgeledger.KindPasskey, Credential: f.credID}}
	for i := 0; i < 2; i++ {
		rep, err := Reapply(bgctx, f.pool, entries, f.clock.now())
		if err != nil || rep != (ReapplyReport{Kept: 1}) {
			t.Fatalf("replay %d: %+v %v, want the removal reported as kept back", i+1, rep, err)
		}
	}
	if n := f.count(`SELECT count(*) FROM webauthn_credentials WHERE user_id = $1 AND credential_id = $2`, f.user, f.credID); n != 1 {
		t.Fatal("the replay took the only passkey that can show the 12 words")
	}
	if n := f.count(`SELECT count(*) FROM account_key_wraps WHERE user_id = $1`, f.user); n != 1 {
		t.Fatal("the replay took the wrap the 12 words still depend on")
	}
	if _, err := f.sessions.Resolve(bgctx, f.token); err != nil {
		t.Fatalf("a removal the replay kept back ended a session: %v", err)
	}
}

func TestAReplayStillRemovesAPasskeyWhenAnotherCanShowTheUnseenWords(t *testing.T) {
	f := newKeyFixtureUnbootstrapped(t).guarded()
	f.bootstrapWordsUnseen()
	second, _, err := f.addOver(f.token, f.device, true)
	if err != nil {
		t.Fatal(err)
	}
	at := f.clock.now().Add(time.Hour)
	entries := []purgeledger.Entry{
		{ID: f.user, At: at, Kind: purgeledger.KindPasskey, Credential: second.CredID},
		{ID: f.user, At: at, Kind: purgeledger.KindPasskey, Credential: f.credID},
	}
	rep, err := Reapply(bgctx, f.pool, entries, f.clock.now())
	if err != nil || rep != (ReapplyReport{Passkeys: 1, Kept: 1}) {
		t.Fatalf("reapply %+v %v, want the first removal applied and the last kept back", rep, err)
	}
	if n := f.count(`SELECT count(*) FROM webauthn_credentials WHERE credential_id = $1`, second.CredID); n != 0 {
		t.Fatal("the passkey with another wrap beside it came back")
	}
	if n := f.count(`SELECT count(*) FROM webauthn_credentials WHERE credential_id = $1`, f.credID); n != 1 {
		t.Fatal("the replay took the last passkey that can show the words")
	}
}

func TestAReplayCountsWordsTheLedgerSawAfterTheRemoval(t *testing.T) {
	for name, kind := range map[string]purgeledger.Kind{"a passkey": purgeledger.KindPasskey, "a wrap": purgeledger.KindWrap} {
		t.Run(name, func(t *testing.T) {
			f := newKeyFixtureUnbootstrapped(t)
			f.bootstrapWordsUnseen()
			at := f.clock.now().Add(time.Hour)
			entries := []purgeledger.Entry{
				{ID: f.user, At: at, Kind: kind, Credential: f.credID},
				{ID: f.user, At: at.Add(time.Minute), Kind: purgeledger.KindPhraseSeen},
			}
			rep, err := Reapply(bgctx, f.pool, entries, f.clock.now())
			if err != nil || rep.PhrasesSeen != 1 || rep.Kept != 0 || rep.Passkeys+rep.Wraps != 1 {
				t.Fatalf("reapply %+v %v, want the removal applied and the words seen", rep, err)
			}
			if n := f.count(`SELECT count(*) FROM account_key_wraps WHERE user_id = $1`, f.user); n != 0 {
				t.Fatal("a removal came back although the words were seen after it")
			}
			if rep, err := Reapply(bgctx, f.pool, entries, f.clock.now()); err != nil || rep != (ReapplyReport{}) {
				t.Fatalf("a second replay %+v %v, want nothing", rep, err)
			}
		})
	}
}

func removalOf(f *keyFixture, kind purgeledger.Kind, at time.Time) purgeledger.Entry {
	return purgeledger.Entry{ID: f.user, At: at.Truncate(time.Second), Kind: kind, Credential: f.credID}
}

func (f *keyFixture) assertKeptBackStaysPut() {
	f.t.Helper()
	if n := f.count(`SELECT count(*) FROM webauthn_credentials WHERE user_id = $1 AND credential_id = $2`, f.user, f.credID); n != 1 {
		f.t.Fatal("a removal kept back at an earlier replay took the passkey")
	}
	if n := f.count(`SELECT count(*) FROM account_key_wraps WHERE user_id = $1 AND credential_id = $2`, f.user, f.credID); n != 1 {
		f.t.Fatal("a removal kept back at an earlier replay took the wrap")
	}
	if _, err := f.sessions.Resolve(bgctx, f.token); err != nil {
		f.t.Fatalf("a removal kept back at an earlier replay ended a session: %v", err)
	}
}

func TestARemovalKeptBackStaysKeptAfterTheWordsAreSeen(t *testing.T) {
	for name, kind := range map[string]purgeledger.Kind{"a passkey": purgeledger.KindPasskey, "a wrap": purgeledger.KindWrap} {
		t.Run(name, func(t *testing.T) {
			f := newKeyFixtureUnbootstrapped(t)
			f.bootstrapWordsUnseen()
			at := f.clock.now().Add(time.Hour)
			removal := removalOf(f, kind, at)
			if _, err := Reapply(bgctx, f.pool, []purgeledger.Entry{removal}, f.clock.now()); err != nil {
				t.Fatal(err)
			}
			f.assertKeptBackStaysPut()
			seen := purgeledger.Entry{ID: f.user, At: removal.At.Add(time.Minute), Kind: purgeledger.KindPhraseSeen}
			rep, err := Reapply(bgctx, f.pool, []purgeledger.Entry{removal, seen}, f.clock.now())
			if err != nil || rep != (ReapplyReport{PhrasesSeen: 1}) {
				t.Fatalf("the replay after the words were seen: %+v %v, want only the words", rep, err)
			}
			f.assertKeptBackStaysPut()
			if rep, err := Reapply(bgctx, f.pool, []purgeledger.Entry{removal, seen}, f.clock.now()); err != nil || rep != (ReapplyReport{}) {
				t.Fatalf("one more replay: %+v %v, want nothing", rep, err)
			}
			f.assertKeptBackStaysPut()
		})
	}
}

func TestARemovalKeptBackStaysKeptOnceAnotherPasskeyHoldsAWrap(t *testing.T) {
	f := newKeyFixtureUnbootstrapped(t).guarded()
	f.bootstrapWordsUnseen()
	removal := removalOf(f, purgeledger.KindPasskey, f.clock.now().Add(time.Hour))
	if rep, err := Reapply(bgctx, f.pool, []purgeledger.Entry{removal}, f.clock.now()); err != nil || rep != (ReapplyReport{Kept: 1}) {
		t.Fatalf("reapply %+v %v, want the removal kept back", rep, err)
	}
	if _, _, err := f.addOver(f.token, f.device, true); err != nil {
		t.Fatal(err)
	}
	if rep, err := Reapply(bgctx, f.pool, []purgeledger.Entry{removal}, f.clock.now()); err != nil || rep != (ReapplyReport{}) {
		t.Fatalf("the replay after another passkey came: %+v %v, want nothing", rep, err)
	}
	f.assertKeptBackStaysPut()
}

func TestAWrapLineDatedBeforeAKeptBackPasskeyLineIsSkippedToo(t *testing.T) {
	f := newKeyFixtureUnbootstrapped(t)
	f.bootstrapWordsUnseen()
	at := f.clock.now().Add(time.Hour)
	removal := removalOf(f, purgeledger.KindPasskey, at)
	if _, err := Reapply(bgctx, f.pool, []purgeledger.Entry{removal}, f.clock.now()); err != nil {
		t.Fatal(err)
	}
	entries := []purgeledger.Entry{
		removalOf(f, purgeledger.KindWrap, at.Add(-time.Minute)),
		{ID: f.user, At: removal.At.Add(time.Minute), Kind: purgeledger.KindPhraseSeen},
	}
	if rep, err := Reapply(bgctx, f.pool, entries, f.clock.now()); err != nil || rep != (ReapplyReport{PhrasesSeen: 1}) {
		t.Fatalf("reapply %+v %v, want only the words", rep, err)
	}
	f.assertKeptBackStaysPut()
}

func TestAPasskeyRemovedAfterItWasKeptBackIsRemovedAgainByAReplay(t *testing.T) {
	f := newKeyFixtureUnbootstrapped(t)
	f.bootstrapWordsUnseen()
	at := f.clock.now().Add(time.Hour)
	removal := removalOf(f, purgeledger.KindPasskey, at)
	if _, err := Reapply(bgctx, f.pool, []purgeledger.Entry{removal}, f.clock.now()); err != nil {
		t.Fatal(err)
	}
	entries := []purgeledger.Entry{
		removal,
		{ID: f.user, At: removal.At.Add(time.Minute), Kind: purgeledger.KindPhraseSeen},
		removalOf(f, purgeledger.KindPasskey, at.Add(2*time.Minute)),
	}
	if rep, err := Reapply(bgctx, f.pool, entries, f.clock.now()); err != nil || rep.Passkeys != 1 || rep.Kept != 0 {
		t.Fatalf("reapply %+v %v, want the later removal applied", rep, err)
	}
	if n := f.count(`SELECT count(*) FROM webauthn_credentials WHERE user_id = $1 AND credential_id = $2`, f.user, f.credID); n != 0 {
		t.Fatal("the removal the holder made after the keep-back came undone")
	}
	if n := f.count(`SELECT count(*) FROM reapply_kept_credentials WHERE user_id = $1`, f.user); n != 0 {
		t.Fatal("the marker outlived its passkey")
	}
}
