package auth

import (
	"bytes"
	"errors"
	"path/filepath"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/authtest"
	"github.com/salehtl/hasala/server/internal/keyproto"
	"github.com/salehtl/hasala/server/internal/purgeledger"
)

func plantMailboxLink(t *testing.T, pool *pgxpool.Pool, u uuid.UUID, holder string, seed byte) {
	t.Helper()
	if _, err := pool.Exec(bgctx,
		`INSERT INTO mailbox_links (user_id, provider, address_hmac, route_key_id, holder_writer_id, created_at, updated_at)
		 VALUES ($1, 'gmail', $2, $3, $4, now(), now())`,
		u, bytes.Repeat([]byte{seed}, 32), bytes.Repeat([]byte{seed}, 8), holder); err != nil {
		t.Fatal(err)
	}
}

func ledgerRecorder(t *testing.T) (string, func(purgeledger.Entry)) {
	path := filepath.Join(t.TempDir(), "purged")
	return path, func(e purgeledger.Entry) {
		if err := purgeledger.AppendEntries(path, e); err != nil {
			t.Errorf("record %s: %v", e.Kind, err)
		}
	}
}

func readLedger(t *testing.T, path string) []purgeledger.Entry {
	t.Helper()
	entries, err := purgeledger.Read(path)
	if err != nil {
		t.Fatal(err)
	}
	return entries
}

func TestRevokingTheHolderDropsTheMailboxLinkAndRecordsTheRemoval(t *testing.T) {
	f := newKeyFixture(t)
	path, rec := ledgerRecorder(t)
	f.writers.Record = rec
	stolen := authtest.NewDevice(t)
	f.enrol(stolen)
	plantMailboxLink(t, f.pool, f.user, stolen.WriterID, 0x11)
	before := f.count(`SELECT count(*) FROM auth_events WHERE user_id = $1 AND kind = 'mailbox_unlinked'`, f.user)

	su := f.stepUpPasskey(f.token, keyproto.ActionWriterRevoke, []byte(stolen.WriterID))
	rev := f.revocation(stolen.WriterID, f.device, 0, make([]byte, 32), su)
	if err := f.writers.Revoke(bgctx, f.user, f.info(f.token), rev); err != nil {
		t.Fatal(err)
	}
	if n := f.count(`SELECT count(*) FROM mailbox_links WHERE user_id = $1`, f.user); n != 0 {
		t.Fatal("the removed iPhone still holds the mailbox link")
	}
	if n := f.count(`SELECT count(*) FROM auth_events WHERE user_id = $1 AND kind = 'mailbox_unlinked' AND writer_id = $2`,
		f.user, f.device.WriterID); n != before+1 {
		t.Fatalf("%d mailbox_unlinked events by the revoking device, want %d", n, before+1)
	}
	entries := readLedger(t, path)
	if len(entries) != 1 || entries[0].Kind != purgeledger.KindDevice || entries[0].ID != f.user {
		t.Fatalf("ledger %+v, want one device removal", entries)
	}
	d := entries[0].Device
	if d.WriterID != stolen.WriterID || d.SignerWriterID != f.device.WriterID || d.FinalCounter != 0 ||
		!bytes.Equal(d.Nonce, rev.Nonce) || !bytes.Equal(d.Sig, rev.Sig) || !bytes.Equal(d.FinalHead, rev.FinalHead) {
		t.Fatalf("recorded %+v", d)
	}
	f.verifiedRoster()
}

func TestRevokingAnotherDeviceKeepsTheHoldersLink(t *testing.T) {
	f := newKeyFixture(t)
	path, rec := ledgerRecorder(t)
	f.writers.Record = rec
	other := authtest.NewDevice(t)
	f.enrol(other)
	plantMailboxLink(t, f.pool, f.user, f.device.WriterID, 0x12)
	su := f.stepUpPasskey(f.token, keyproto.ActionWriterRevoke, []byte(other.WriterID))
	if err := f.writers.Revoke(bgctx, f.user, f.info(f.token), f.revocation(other.WriterID, f.device, 0, make([]byte, 32), su)); err != nil {
		t.Fatal(err)
	}
	if n := f.count(`SELECT count(*) FROM mailbox_links WHERE user_id = $1 AND holder_writer_id = $2`, f.user, f.device.WriterID); n != 1 {
		t.Fatal("revoking a device that holds no link dropped the holder's link")
	}
	if n := f.count(`SELECT count(*) FROM auth_events WHERE user_id = $1 AND kind = 'mailbox_unlinked'`, f.user); n != 0 {
		t.Fatal("an unlink was recorded for a link that stayed")
	}
	if n := len(readLedger(t, path)); n != 1 {
		t.Fatalf("%d ledger entries, want 1", n)
	}
}

func TestAFailedRevocationRecordsNothing(t *testing.T) {
	f := newKeyFixture(t)
	path, rec := ledgerRecorder(t)
	f.writers.Record = rec
	other := authtest.NewDevice(t)
	f.enrol(other)
	plantMailboxLink(t, f.pool, f.user, other.WriterID, 0x13)
	su := f.stepUpPasskey(f.token, keyproto.ActionWriterRevoke, []byte(other.WriterID))
	if err := f.writers.Revoke(bgctx, f.user, f.info(f.token), f.revocation(other.WriterID, f.device, 3, make([]byte, 32), su)); !errors.Is(err, ErrHeadMoved) {
		t.Fatalf("a wrong head: %v", err)
	}
	if n := f.count(`SELECT count(*) FROM mailbox_links WHERE user_id = $1`, f.user); n != 1 {
		t.Fatal("a refused revocation dropped the link")
	}
	if n := len(readLedger(t, path)); n != 0 {
		t.Fatalf("a refused revocation wrote %d ledger entries", n)
	}
}

func TestReapplyRevokesADeviceARestoreBroughtBack(t *testing.T) {
	f := newKeyFixture(t)
	stolen := authtest.NewDevice(t)
	stolenTok := f.enrol(stolen)
	counter, head := f.appendRows(stolen, 2)
	registerPushToken(t, f.pool, f.user, stolen.WriterID, stolenTok, "stolen")
	plantMailboxLink(t, f.pool, f.user, stolen.WriterID, 0x14)
	rev := f.revocation(stolen.WriterID, f.device, counter, head, nil)
	entries := []purgeledger.Entry{
		{ID: f.user, At: f.clock.now().Truncate(time.Second), Kind: purgeledger.KindDevice, Device: &purgeledger.Device{
			WriterID: rev.WriterID, SignerWriterID: rev.SignerWriterID, FinalCounter: rev.FinalCounter,
			FinalHead: rev.FinalHead, Nonce: rev.Nonce, Sig: rev.Sig}},
		{ID: uuid.New(), At: f.clock.now().Truncate(time.Second), Kind: purgeledger.KindPassword},
	}
	rep, err := Reapply(bgctx, f.pool, entries, f.clock.now())
	if err != nil || rep.Devices != 1 || rep.Passwords != 0 || rep.Freezes != 0 {
		t.Fatalf("reapply %+v %v, want one device", rep, err)
	}
	r := f.verifiedRoster()
	if w := r[stolen.WriterID]; w.live || w.finalCounter != counter || !bytes.Equal(w.finalHead, head) {
		t.Fatalf("roster after the replay: %+v", w)
	}
	if !r[f.device.WriterID].live {
		t.Fatal("the signer was revoked")
	}
	if n := f.count(`SELECT count(*) FROM sessions WHERE token_hash = $1 AND revoked_at IS NULL`, SessionHash(stolenTok)); n != 0 {
		t.Fatal("the removed device's session is live again")
	}
	if n := f.count(`SELECT count(*) FROM apns_tokens WHERE writer_id = $1`, stolen.WriterID); n != 0 {
		t.Fatal("the removed device's push token survived")
	}
	if n := f.count(`SELECT count(*) FROM mailbox_links WHERE user_id = $1`, f.user); n != 0 {
		t.Fatal("the removed device's mailbox link survived")
	}
	if _, err := f.sessions.Resolve(bgctx, f.token); err != nil {
		t.Fatalf("another device's session was revoked: %v", err)
	}
	rep, err = Reapply(bgctx, f.pool, entries, f.clock.now())
	if err != nil || rep != (ReapplyReport{}) {
		t.Fatalf("a second replay %+v %v, want nothing", rep, err)
	}
	if n := f.count(`SELECT count(*) FROM key_history WHERE user_id = $1 AND event = 'revoked'`, f.user); n != 1 {
		t.Fatalf("%d revocations in the key history, want 1", n)
	}
}

func TestPasswordChangesSurviveARestore(t *testing.T) {
	f := newAcctFixture(t)
	path, rec := ledgerRecorder(t)
	f.acct.Record = rec
	m := f.passwordMember("Maya")
	other, err := m.loginPassword(m.s, nil)
	if err != nil {
		t.Fatal(err)
	}
	var (
		oldHash, oldSalt []byte
		oldVersion       int
		oldSetAt         time.Time
	)
	if err := f.pool.QueryRow(bgctx, `SELECT password_hash, password_salt, password_version, password_set_at FROM users WHERE id = $1`,
		m.user.UserID).Scan(&oldHash, &oldSalt, &oldVersion, &oldSetAt); err != nil {
		t.Fatal(err)
	}
	f.clock.advance(time.Hour)
	newS := f.stretch(m.addr, "an entirely new password")
	if _, err := f.acct.ChangePassword(bgctx, m.info(), newS, m.deviceStepUp(keyproto.ActionPasswordChange, m.s, sumBytes(newS))); err != nil {
		t.Fatal(err)
	}
	entries := readLedger(t, path)
	if len(entries) != 1 || entries[0].Kind != purgeledger.KindPassword || entries[0].ID != m.user.UserID {
		t.Fatalf("ledger %+v, want one password change", entries)
	}

	if rep, err := Reapply(bgctx, f.pool, entries, f.clock.now()); err != nil || rep.Passwords != 0 {
		t.Fatalf("a replay on the live database %+v %v, want nothing", rep, err)
	}
	if _, err := m.loginPassword(newS, nil); err != nil {
		t.Fatalf("the new password stopped working after a replay without a restore: %v", err)
	}

	if _, err := f.pool.Exec(bgctx, `UPDATE users SET password_hash = $2, password_salt = $3, password_version = $4, password_set_at = $5
	    WHERE id = $1`, m.user.UserID, oldHash, oldSalt, oldVersion, oldSetAt); err != nil {
		t.Fatal(err)
	}
	if _, err := f.pool.Exec(bgctx, `UPDATE sessions SET revoked_at = NULL, revoked_reason = NULL WHERE token_hash = $1`,
		SessionHash(other.Session.Token)); err != nil {
		t.Fatal(err)
	}
	if _, err := m.loginPassword(m.s, nil); err != nil {
		t.Fatalf("the simulated restore did not bring the old password back: %v", err)
	}
	rep, err := Reapply(bgctx, f.pool, entries, f.clock.now())
	if err != nil || rep.Passwords != 1 {
		t.Fatalf("reapply %+v %v, want one password", rep, err)
	}
	if _, err := m.loginPassword(m.s, nil); !errors.Is(err, ErrPasswordRejected) {
		t.Fatalf("the old password works again after the replay: %v", err)
	}
	if _, err := f.sessions.Resolve(bgctx, other.Session.Token); !errors.Is(err, ErrSessionRevoked) {
		t.Fatalf("a session the change ended is live again: %v", err)
	}
	if n := f.count(`SELECT count(*) FROM users WHERE id = $1 AND password_hash IS NULL`, m.user.UserID); n != 1 {
		t.Fatal("the restored password was not removed")
	}
	if rep, err := Reapply(bgctx, f.pool, entries, f.clock.now()); err != nil || rep.Passwords != 0 {
		t.Fatalf("a second replay %+v %v", rep, err)
	}
}

func TestARefusedPasswordChangeRecordsNothing(t *testing.T) {
	f := newAcctFixture(t)
	path, rec := ledgerRecorder(t)
	f.acct.Record = rec
	m := f.passwordMember("Maya")
	if _, err := f.acct.ChangePassword(bgctx, m.info(), m.s, nil); !errors.Is(err, ErrStepUpRequired) {
		t.Fatalf("no step-up: %v", err)
	}
	if n := len(readLedger(t, path)); n != 0 {
		t.Fatalf("%d entries for a refused change", n)
	}
}

func TestAFreezeSurvivesARestore(t *testing.T) {
	f := newAcctFixture(t)
	path, rec := ledgerRecorder(t)
	f.acct.Record = rec
	m := f.passwordMember("Maya")
	other, err := m.loginPassword(m.s, nil)
	if err != nil {
		t.Fatal(err)
	}
	f.clock.advance(time.Hour)
	if _, err := f.acct.FreezeNow(bgctx, m.info(), m.deviceStepUp(keyproto.ActionAccountFreeze, m.s)); err != nil {
		t.Fatal(err)
	}
	entries := readLedger(t, path)
	if len(entries) != 1 || entries[0].Kind != purgeledger.KindFreeze || entries[0].ID != m.user.UserID ||
		!entries[0].Trigger.Equal(f.clock.now().Truncate(time.Second)) {
		t.Fatalf("ledger %+v, want one freeze", entries)
	}
	if rep, err := Reapply(bgctx, f.pool, entries, f.clock.now()); err != nil || rep.Freezes != 0 {
		t.Fatalf("a replay on the frozen account %+v %v, want nothing", rep, err)
	}

	if _, err := f.pool.Exec(bgctx, `UPDATE users SET frozen_at = NULL, freeze_trigger_at = NULL, frozen_by = NULL WHERE id = $1`,
		m.user.UserID); err != nil {
		t.Fatal(err)
	}
	if _, err := f.pool.Exec(bgctx, `UPDATE sessions SET revoked_at = NULL, revoked_reason = NULL WHERE user_id = $1`,
		m.user.UserID); err != nil {
		t.Fatal(err)
	}
	if _, err := f.pool.Exec(bgctx, `INSERT INTO auth_events (user_id, kind, at) VALUES ($1, 'account_unfrozen', $2)`,
		m.user.UserID, f.clock.now().Add(-2*time.Hour)); err != nil {
		t.Fatal(err)
	}
	f.clock.advance(time.Minute)
	rep, err := Reapply(bgctx, f.pool, entries, f.clock.now())
	if err != nil || rep.Freezes != 1 {
		t.Fatalf("reapply %+v %v, want one freeze", rep, err)
	}
	var frozenBy string
	var trigger time.Time
	if err := f.pool.QueryRow(bgctx, `SELECT frozen_by, freeze_trigger_at FROM users WHERE id = $1`, m.user.UserID).
		Scan(&frozenBy, &trigger); err != nil {
		t.Fatal(err)
	}
	if frozenBy != FrozenByHolder || !trigger.Equal(entries[0].Trigger) {
		t.Fatalf("frozen by %q at trigger %v", frozenBy, trigger)
	}
	for _, tok := range []string{m.token, other.Session.Token} {
		if _, err := f.sessions.Resolve(bgctx, tok); !errors.Is(err, ErrSessionRevoked) {
			t.Fatalf("a session the freeze ended is live again: %v", err)
		}
	}
	if rep, err := Reapply(bgctx, f.pool, entries, f.clock.now()); err != nil || rep.Freezes != 0 {
		t.Fatalf("a second replay %+v %v", rep, err)
	}
}

func TestAnUnfreezeAfterTheFreezeIsKept(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	at := f.clock.now().Truncate(time.Second)
	f.clock.advance(time.Hour)
	if _, err := f.pool.Exec(bgctx, `INSERT INTO auth_events (user_id, kind, at) VALUES ($1, 'account_unfrozen', $2)`,
		m.user.UserID, f.clock.now()); err != nil {
		t.Fatal(err)
	}
	entries := []purgeledger.Entry{{ID: m.user.UserID, At: at, Kind: purgeledger.KindFreeze, Trigger: at}}
	if rep, err := Reapply(bgctx, f.pool, entries, f.clock.now()); err != nil || rep.Freezes != 0 {
		t.Fatalf("reapply %+v %v: a lifted freeze came back", rep, err)
	}
	if _, err := f.sessions.Resolve(bgctx, m.token); err != nil {
		t.Fatalf("the session was revoked: %v", err)
	}
}

func TestReapplyOnlySignsOutADeviceWhoseSignerTheRestoreLost(t *testing.T) {
	f := newKeyFixture(t)
	stolen := authtest.NewDevice(t)
	stolenTok := f.enrol(stolen)
	plantMailboxLink(t, f.pool, f.user, stolen.WriterID, 0x15)
	lost := authtest.NewDevice(t)
	unknown := f.revocation(stolen.WriterID, lost, 0, make([]byte, 32), nil)
	forged := f.revocation(stolen.WriterID, f.device, 0, make([]byte, 32), nil)
	forged.Sig = bytes.Repeat([]byte{0x01}, len(forged.Sig))
	at := f.clock.now().Truncate(time.Second)
	var entries []purgeledger.Entry
	for _, rev := range []Revocation{unknown, forged} {
		entries = append(entries, purgeledger.Entry{ID: f.user, At: at, Kind: purgeledger.KindDevice, Device: &purgeledger.Device{
			WriterID: rev.WriterID, SignerWriterID: rev.SignerWriterID, FinalCounter: rev.FinalCounter,
			FinalHead: rev.FinalHead, Nonce: rev.Nonce, Sig: rev.Sig}})
	}
	rep, err := Reapply(bgctx, f.pool, entries, f.clock.now())
	if err != nil || rep.Devices != 0 || rep.Unsigned != 2 {
		t.Fatalf("reapply %+v %v, want two unsigned removals", rep, err)
	}
	if n := f.count(`SELECT count(*) FROM key_history WHERE user_id = $1 AND event = 'revoked'`, f.user); n != 0 {
		t.Fatalf("%d revocations the roster cannot verify went into the key history", n)
	}
	r := f.verifiedRoster()
	if !r[stolen.WriterID].live {
		t.Fatal("the writer was revoked without a key-history row")
	}
	if n := f.count(`SELECT count(*) FROM sessions WHERE token_hash = $1 AND revoked_at IS NULL`, SessionHash(stolenTok)); n != 0 {
		t.Fatal("the removed device's session is live again")
	}
	if n := f.count(`SELECT count(*) FROM mailbox_links WHERE user_id = $1`, f.user); n != 0 {
		t.Fatal("the removed device's mailbox link survived")
	}
	if _, err := f.sessions.Resolve(bgctx, f.token); err != nil {
		t.Fatalf("another device's session was revoked: %v", err)
	}
	rep, err = Reapply(bgctx, f.pool, entries, f.clock.now())
	if err != nil || rep.Devices != 0 || rep.Unsigned != 2 {
		t.Fatalf("a second replay %+v %v, want the two unsigned removals reported again", rep, err)
	}
}

func TestARecordedUnfreezeKeepsTheFreezeLiftedAfterARestore(t *testing.T) {
	f := newAcctFixture(t)
	path, rec := ledgerRecorder(t)
	f.acct.Record = rec
	m := f.passwordMember("Maya")
	f.clock.advance(time.Hour)
	if _, err := f.acct.FreezeNow(bgctx, m.info(), m.deviceStepUp(keyproto.ActionAccountFreeze, m.s)); err != nil {
		t.Fatal(err)
	}
	in, err := m.loginPassword(m.s, m.device)
	if err != nil || !in.Restricted {
		t.Fatalf("a sign-in into the frozen account: %+v %v", in, err)
	}
	m.token = in.Session.Token
	if _, err := f.acct.Unfreeze(bgctx, m.info(), m.deviceStepUp(keyproto.ActionAccountUnfreeze, m.s)); err != nil {
		t.Fatal(err)
	}
	entries := readLedger(t, path)
	if len(entries) != 2 || entries[0].Kind != purgeledger.KindFreeze || entries[1].Kind != purgeledger.KindUnfreeze ||
		entries[1].ID != m.user.UserID {
		t.Fatalf("ledger %+v, want a freeze and an unfreeze", entries)
	}
	if _, err := f.pool.Exec(bgctx, `DELETE FROM auth_events WHERE user_id = $1 AND kind IN ('account_frozen', 'account_unfrozen')`,
		m.user.UserID); err != nil {
		t.Fatal(err)
	}
	rep, err := Reapply(bgctx, f.pool, entries, f.clock.now())
	if err != nil || rep.Freezes != 0 {
		t.Fatalf("reapply %+v %v: a freeze the holder lifted came back", rep, err)
	}
	if _, err := f.sessions.Resolve(bgctx, m.token); err != nil {
		t.Fatalf("the unfrozen session was revoked: %v", err)
	}

	f.clock.advance(time.Hour)
	again := f.clock.now().Truncate(time.Second)
	entries = append(entries, purgeledger.Entry{ID: m.user.UserID, At: again, Kind: purgeledger.KindFreeze, Trigger: again})
	rep, err = Reapply(bgctx, f.pool, entries, f.clock.now())
	if err != nil || rep.Freezes != 1 {
		t.Fatalf("reapply %+v %v, want the later freeze", rep, err)
	}
	if n := f.count(`SELECT count(*) FROM users WHERE id = $1 AND frozen_by = 'holder'`, m.user.UserID); n != 1 {
		t.Fatal("the freeze after the unfreeze was not applied again")
	}
}

func TestAHolderFreezeOnAnOperatorFrozenAccountIsKeptByTheReplay(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	f.clock.advance(time.Hour)
	opAt := f.clock.now()
	if _, err := f.pool.Exec(bgctx, `UPDATE users SET frozen_at = $2, freeze_trigger_at = $2, frozen_by = 'operator' WHERE id = $1`,
		m.user.UserID, opAt); err != nil {
		t.Fatal(err)
	}
	at := opAt.Add(time.Minute).Truncate(time.Second)
	trigger := opAt.Add(-time.Hour).Truncate(time.Second)
	entries := []purgeledger.Entry{{ID: m.user.UserID, At: at, Kind: purgeledger.KindFreeze, Trigger: trigger}}
	rep, err := Reapply(bgctx, f.pool, entries, f.clock.now())
	if err != nil || rep.Freezes != 1 {
		t.Fatalf("reapply %+v %v, want the holder's freeze kept", rep, err)
	}
	var (
		by    string
		also  bool
		since time.Time
	)
	if err := f.pool.QueryRow(bgctx, `SELECT frozen_by, holder_also_froze, freeze_trigger_at FROM users WHERE id = $1`,
		m.user.UserID).Scan(&by, &also, &since); err != nil {
		t.Fatal(err)
	}
	if by != FrozenByOperator || !also || !since.Equal(trigger) {
		t.Fatalf("frozen by %q, holder also %v, trigger %v", by, also, since)
	}
	if rep, err := Reapply(bgctx, f.pool, entries, f.clock.now()); err != nil || rep.Freezes != 0 {
		t.Fatalf("a second replay %+v %v", rep, err)
	}
}

func saveRow(t *testing.T, pool *pgxpool.Pool, table, where string, args ...any) string {
	t.Helper()
	var row string
	if err := pool.QueryRow(bgctx, `SELECT row_to_json(r)::text FROM `+table+` r WHERE `+where, args...).Scan(&row); err != nil {
		t.Fatal(err)
	}
	return row
}

func restoreRow(t *testing.T, pool *pgxpool.Pool, table, row string) {
	t.Helper()
	if _, err := pool.Exec(bgctx, `INSERT INTO `+table+` SELECT * FROM json_populate_record(NULL::`+table+`, $1::json)`, row); err != nil {
		t.Fatal(err)
	}
}

func TestAPasskeyRemovalIsRecordedAndSurvivesARestore(t *testing.T) {
	f := newKeyFixture(t).guarded()
	path, rec := ledgerRecorder(t)
	f.passkeys.Record = rec
	second, _, err := f.addOver(f.token, f.device, true)
	if err != nil {
		t.Fatal(err)
	}
	minted, err := f.sessions.IssueForCredential(bgctx, f.user, second.CredID)
	if err != nil {
		t.Fatal(err)
	}
	cred := saveRow(t, f.pool, "webauthn_credentials", "credential_id = $1", second.CredID)
	wrap := saveRow(t, f.pool, "account_key_wraps", "credential_id = $1", second.CredID)

	su := f.stepUpPasskey(f.token, keyproto.ActionPasskeyDelete, second.CredID)
	if _, err := f.passkeys.DeletePasskey(bgctx, f.info(f.token), second.CredID, su); err != nil {
		t.Fatal(err)
	}
	entries := readLedger(t, path)
	if len(entries) != 1 || entries[0].Kind != purgeledger.KindPasskey || entries[0].ID != f.user ||
		!bytes.Equal(entries[0].Credential, second.CredID) {
		t.Fatalf("ledger %+v, want the removed credential", entries)
	}
	if _, err := f.sessions.Resolve(bgctx, minted); !errors.Is(err, ErrSessionRevoked) {
		t.Fatalf("the removed passkey's session: %v", err)
	}

	restoreRow(t, f.pool, "webauthn_credentials", cred)
	restoreRow(t, f.pool, "account_key_wraps", wrap)
	if _, err := f.pool.Exec(bgctx, `UPDATE sessions SET revoked_at = NULL, revoked_reason = NULL WHERE credential_id = $1`,
		second.CredID); err != nil {
		t.Fatal(err)
	}
	early := []purgeledger.Entry{{ID: f.user, At: entries[0].At.Add(-time.Hour), Kind: purgeledger.KindPasskey, Credential: second.CredID}}
	if rep, err := Reapply(bgctx, f.pool, early, f.clock.now()); err != nil || rep.Passkeys != 0 {
		t.Fatalf("a removal older than the credential: %+v %v", rep, err)
	}
	rep, err := Reapply(bgctx, f.pool, entries, f.clock.now())
	if err != nil || rep.Passkeys != 1 || rep.Devices != 0 || rep.Freezes != 0 || rep.Passwords != 0 {
		t.Fatalf("reapply %+v %v, want one passkey", rep, err)
	}
	if n := f.count(`SELECT count(*) FROM webauthn_credentials WHERE credential_id = $1`, second.CredID); n != 0 {
		t.Fatal("the restored passkey came back")
	}
	if n := f.count(`SELECT count(*) FROM account_key_wraps WHERE credential_id = $1`, second.CredID); n != 0 {
		t.Fatal("the restored passkey's wrap stayed")
	}
	if n := f.count(`SELECT count(*) FROM account_key_wraps WHERE user_id = $1 AND credential_id = $2`, f.user, f.credID); n != 1 {
		t.Fatal("the other passkey's wrap went")
	}
	if _, err := f.sessions.Resolve(bgctx, minted); !errors.Is(err, ErrSessionRevoked) {
		t.Fatalf("the restored session of the removed passkey: %v", err)
	}
	if _, err := f.sessions.Resolve(bgctx, f.token); err != nil {
		t.Fatalf("the other passkey's session: %v", err)
	}
	if rep, err := Reapply(bgctx, f.pool, entries, f.clock.now()); err != nil || rep.Passkeys != 0 {
		t.Fatalf("a second replay %+v %v", rep, err)
	}
}

func TestARefusedPasskeyRemovalRecordsNothing(t *testing.T) {
	f := newKeyFixture(t).guarded()
	path, rec := ledgerRecorder(t)
	f.passkeys.Record = rec
	su := f.stepUpPasskey(f.token, keyproto.ActionPasskeyDelete, f.credID)
	if _, err := f.passkeys.DeletePasskey(bgctx, f.info(f.token), f.credID, su); !errors.Is(err, ErrLastPasskey) {
		t.Fatalf("delete of the last passkey: %v", err)
	}
	if n := len(readLedger(t, path)); n != 0 {
		t.Fatalf("a refused removal wrote %d ledger entries", n)
	}
}

func TestRecoveryRecordsTheOldPasskeysItRemoves(t *testing.T) {
	f := newAcctFixture(t)
	path, rec := ledgerRecorder(t)
	f.acct.Record = rec
	m := f.passwordMember("Maya")
	first := f.enrolPasskey(m.user.UserID)
	second := f.enrolPasskey(m.user.UserID)
	id, v := f.verifiedRecovery(m, "passkey")
	req, fresh := f.passkeyRecoveryRequest(m, id, v)
	if _, err := f.acct.RecoverFinish(bgctx, req); err != nil {
		t.Fatal(err)
	}
	removed := map[string]bool{}
	passwords := 0
	for _, e := range readLedger(t, path) {
		if e.ID != m.user.UserID {
			t.Fatalf("an entry for another id: %+v", e)
		}
		switch e.Kind {
		case purgeledger.KindPasskey:
			removed[string(e.Credential)] = true
		case purgeledger.KindPassword:
			passwords++
		default:
			t.Fatalf("unexpected entry %+v", e)
		}
	}
	if len(removed) != 2 || !removed[string(first.CredID)] || !removed[string(second.CredID)] || removed[string(fresh.CredID)] ||
		passwords != 1 {
		t.Fatalf("recorded %d passkeys and %d passwords, want the two old passkeys and the password", len(removed), passwords)
	}
}

func TestAReplayNeverLeavesAPasswordOnlyAccountFrozenWithNoWayIn(t *testing.T) {
	for _, freezeFirst := range []bool{true, false} {
		name := "password then freeze"
		if freezeFirst {
			name = "freeze then password"
		}
		t.Run(name, func(t *testing.T) {
			f := newAcctFixture(t)
			m := f.passwordMember("Maya")
			other, err := m.loginPassword(m.s, nil)
			if err != nil {
				t.Fatal(err)
			}
			if n := f.count(`SELECT count(*) FROM webauthn_credentials WHERE user_id = $1`, m.user.UserID); n != 0 {
				t.Fatalf("the password member has %d passkeys", n)
			}
			f.clock.advance(time.Hour)
			first := f.clock.now().Truncate(time.Second)
			second := first.Add(time.Minute)
			f.clock.advance(2 * time.Minute)
			freeze := purgeledger.Entry{ID: m.user.UserID, At: second, Kind: purgeledger.KindFreeze, Trigger: second}
			password := purgeledger.Entry{ID: m.user.UserID, At: first, Kind: purgeledger.KindPassword}
			entries := []purgeledger.Entry{password, freeze}
			if freezeFirst {
				freeze.At, freeze.Trigger, password.At = first, first, second
				entries = []purgeledger.Entry{freeze, password}
			}
			rep, err := Reapply(bgctx, f.pool, entries, f.clock.now())
			if err != nil || rep != (ReapplyReport{Freezes: 1, Passwords: 1, Lifted: 1}) {
				t.Fatalf("reapply %+v %v, want the freeze and the password applied and the freeze lifted", rep, err)
			}
			if n := f.count(`SELECT count(*) FROM users WHERE id = $1 AND frozen_at IS NULL AND freeze_trigger_at IS NULL
			    AND frozen_by IS NULL AND NOT holder_also_froze AND password_hash IS NULL`, m.user.UserID); n != 1 {
				t.Fatal("the account is frozen with no passkey and no password")
			}
			for _, tok := range []string{m.token, other.Session.Token} {
				if _, err := f.sessions.Resolve(bgctx, tok); !errors.Is(err, ErrSessionRevoked) {
					t.Fatalf("a session the replay ended is live again: %v", err)
				}
			}
			if n := f.count(`SELECT count(*) FROM auth_events WHERE user_id = $1 AND kind = 'account_unfrozen'`, m.user.UserID); n != 1 {
				t.Fatalf("%d unfreeze events, want 1", n)
			}
			if rep, err := Reapply(bgctx, f.pool, entries, f.clock.now()); err != nil || rep != (ReapplyReport{}) {
				t.Fatalf("a second replay %+v %v, want nothing", rep, err)
			}
			if n := f.count(`SELECT count(*) FROM users WHERE id = $1 AND frozen_at IS NULL`, m.user.UserID); n != 1 {
				t.Fatal("a second replay froze the account again")
			}
		})
	}
}

func TestAReplayLiftsAFreezeWhenAPasskeyRemovalLeavesNoAuthenticator(t *testing.T) {
	f := newKeyFixture(t)
	if n := f.count(`SELECT count(*) FROM users WHERE id = $1 AND password_hash IS NULL`, f.user); n != 1 {
		t.Fatal("the passkey account has a password")
	}
	f.clock.advance(10 * time.Minute)
	at := f.clock.now().Truncate(time.Second)
	f.clock.advance(time.Minute)
	entries := []purgeledger.Entry{
		{ID: f.user, At: at, Kind: purgeledger.KindFreeze, Trigger: at},
		{ID: f.user, At: at.Add(time.Second), Kind: purgeledger.KindPasskey, Credential: f.credID},
	}
	rep, err := Reapply(bgctx, f.pool, entries, f.clock.now())
	if err != nil || rep != (ReapplyReport{Freezes: 1, Passkeys: 1, Lifted: 1}) {
		t.Fatalf("reapply %+v %v, want the freeze and the passkey applied and the freeze lifted", rep, err)
	}
	if n := f.count(`SELECT count(*) FROM users WHERE id = $1 AND frozen_at IS NULL`, f.user); n != 1 {
		t.Fatal("the account is frozen with no passkey and no password")
	}
	if n := f.count(`SELECT count(*) FROM webauthn_credentials WHERE user_id = $1`, f.user); n != 0 {
		t.Fatal("the removed passkey came back")
	}
	if _, err := f.sessions.Resolve(bgctx, f.token); !errors.Is(err, ErrSessionRevoked) {
		t.Fatalf("a session the freeze ended is live again: %v", err)
	}
	if rep, err := Reapply(bgctx, f.pool, entries, f.clock.now()); err != nil || rep != (ReapplyReport{}) {
		t.Fatalf("a second replay %+v %v, want nothing", rep, err)
	}
}

func TestAReplayKeepsAFreezeWhenAPasskeyIsLeft(t *testing.T) {
	f := newKeyFixture(t).guarded()
	second, _, err := f.addOver(f.token, f.device, true)
	if err != nil {
		t.Fatal(err)
	}
	f.clock.advance(10 * time.Minute)
	at := f.clock.now().Truncate(time.Second)
	entries := []purgeledger.Entry{
		{ID: f.user, At: at, Kind: purgeledger.KindFreeze, Trigger: at},
		{ID: f.user, At: at, Kind: purgeledger.KindPasskey, Credential: second.CredID},
	}
	rep, err := Reapply(bgctx, f.pool, entries, f.clock.now())
	if err != nil || rep != (ReapplyReport{Freezes: 1, Passkeys: 1}) {
		t.Fatalf("reapply %+v %v, want the freeze kept", rep, err)
	}
	if n := f.count(`SELECT count(*) FROM users WHERE id = $1 AND frozen_by = 'holder'`, f.user); n != 1 {
		t.Fatal("a freeze on an account with a passkey left was lifted")
	}
}

func TestARecordedUnfreezeLiftsTheFreezeARestoreBroughtBack(t *testing.T) {
	f := newAcctFixture(t)
	path, rec := ledgerRecorder(t)
	f.acct.Record = rec
	m := f.passwordMember("Maya")
	f.clock.advance(time.Hour)
	if _, err := f.acct.FreezeNow(bgctx, m.info(), m.deviceStepUp(keyproto.ActionAccountFreeze, m.s)); err != nil {
		t.Fatal(err)
	}
	frozenRow := saveRow(t, f.pool, "users", "id = $1", m.user.UserID)
	in, err := m.loginPassword(m.s, m.device)
	if err != nil || !in.Restricted {
		t.Fatalf("a sign-in into the frozen account: %+v %v", in, err)
	}
	m.token = in.Session.Token
	f.clock.advance(time.Minute)
	if _, err := f.acct.Unfreeze(bgctx, m.info(), m.deviceStepUp(keyproto.ActionAccountUnfreeze, m.s)); err != nil {
		t.Fatal(err)
	}
	entries := readLedger(t, path)
	if len(entries) != 2 || entries[1].Kind != purgeledger.KindUnfreeze {
		t.Fatalf("ledger %+v, want a freeze and an unfreeze", entries)
	}
	if rep, err := Reapply(bgctx, f.pool, entries, f.clock.now()); err != nil || rep != (ReapplyReport{}) {
		t.Fatalf("a replay on the live database %+v %v, want nothing", rep, err)
	}

	var frozenAt, trigger time.Time
	if err := f.pool.QueryRow(bgctx, `SELECT frozen_at, freeze_trigger_at FROM json_populate_record(NULL::users, $1::json)`,
		frozenRow).Scan(&frozenAt, &trigger); err != nil {
		t.Fatal(err)
	}
	if _, err := f.pool.Exec(bgctx, `UPDATE users SET frozen_at = $2, freeze_trigger_at = $3, frozen_by = 'holder' WHERE id = $1`,
		m.user.UserID, frozenAt, trigger); err != nil {
		t.Fatal(err)
	}
	if _, err := f.pool.Exec(bgctx, `UPDATE sessions SET restricted = true WHERE token_hash = $1`, SessionHash(m.token)); err != nil {
		t.Fatal(err)
	}
	if _, err := f.pool.Exec(bgctx, `DELETE FROM auth_events WHERE user_id = $1 AND kind = 'account_unfrozen'`, m.user.UserID); err != nil {
		t.Fatal(err)
	}
	rep, err := Reapply(bgctx, f.pool, entries, f.clock.now())
	if err != nil || rep != (ReapplyReport{Unfreezes: 1}) {
		t.Fatalf("reapply %+v %v, want the unfreeze", rep, err)
	}
	if n := f.count(`SELECT count(*) FROM users WHERE id = $1 AND frozen_at IS NULL AND freeze_trigger_at IS NULL
	    AND frozen_by IS NULL AND NOT holder_also_froze`, m.user.UserID); n != 1 {
		t.Fatal("the freeze the holder lifted came back")
	}
	if _, err := f.sessions.Resolve(bgctx, m.token); !errors.Is(err, ErrSessionRevoked) {
		t.Fatalf("a restricted session the unfreeze ended is live again: %v", err)
	}
	if rep, err := Reapply(bgctx, f.pool, entries, f.clock.now()); err != nil || rep != (ReapplyReport{}) {
		t.Fatalf("a second replay %+v %v, want nothing", rep, err)
	}
}

func TestAnUnfreezeReplayNeverLiftsTheOperatorsFreeze(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	f.clock.advance(time.Hour)
	opAt := f.clock.now()
	if _, err := f.pool.Exec(bgctx, `UPDATE users SET frozen_at = $2, freeze_trigger_at = $2, frozen_by = 'operator' WHERE id = $1`,
		m.user.UserID, opAt); err != nil {
		t.Fatal(err)
	}
	at := opAt.Add(time.Minute).Truncate(time.Second)
	entries := []purgeledger.Entry{{ID: m.user.UserID, At: at, Kind: purgeledger.KindUnfreeze}}
	if rep, err := Reapply(bgctx, f.pool, entries, f.clock.now()); err != nil || rep != (ReapplyReport{}) {
		t.Fatalf("reapply %+v %v: a holder's unfreeze lifted the operator's freeze", rep, err)
	}
	if n := f.count(`SELECT count(*) FROM users WHERE id = $1 AND frozen_by = 'operator' AND NOT holder_also_froze`, m.user.UserID); n != 1 {
		t.Fatal("the operator's freeze changed")
	}
	if _, err := f.pool.Exec(bgctx, `UPDATE users SET holder_also_froze = true WHERE id = $1`, m.user.UserID); err != nil {
		t.Fatal(err)
	}
	if rep, err := Reapply(bgctx, f.pool, entries, f.clock.now()); err != nil || rep != (ReapplyReport{Unfreezes: 1}) {
		t.Fatalf("reapply %+v %v, want the holder's part lifted", rep, err)
	}
	if n := f.count(`SELECT count(*) FROM users WHERE id = $1 AND frozen_at IS NOT NULL AND frozen_by = 'operator' AND NOT holder_also_froze`,
		m.user.UserID); n != 1 {
		t.Fatal("the operator's freeze did not stay, or the holder's part was not lifted")
	}
	if _, err := f.sessions.Resolve(bgctx, m.token); err != nil {
		t.Fatalf("lifting the holder's part under the operator's freeze revoked a session: %v", err)
	}
	if rep, err := Reapply(bgctx, f.pool, entries, f.clock.now()); err != nil || rep != (ReapplyReport{}) {
		t.Fatalf("a second replay %+v %v, want nothing", rep, err)
	}
}

func TestAnUnfreezeIsNotAppliedToALaterFreeze(t *testing.T) {
	f := newAcctFixture(t)
	m := f.passwordMember("Maya")
	f.clock.advance(time.Hour)
	unfrozeAt := f.clock.now().Truncate(time.Second)
	f.clock.advance(time.Hour)
	frozeAt := f.clock.now()
	if _, err := f.pool.Exec(bgctx, `UPDATE users SET frozen_at = $2, freeze_trigger_at = $2, frozen_by = 'holder' WHERE id = $1`,
		m.user.UserID, frozeAt); err != nil {
		t.Fatal(err)
	}
	for _, entries := range [][]purgeledger.Entry{
		{{ID: m.user.UserID, At: unfrozeAt, Kind: purgeledger.KindUnfreeze}},
		{{ID: m.user.UserID, At: unfrozeAt.Add(-time.Hour), Kind: purgeledger.KindUnfreeze},
			{ID: m.user.UserID, At: unfrozeAt, Kind: purgeledger.KindFreeze, Trigger: unfrozeAt},
			{ID: m.user.UserID, At: frozeAt.Add(time.Minute).Truncate(time.Second), Kind: purgeledger.KindUnfreeze},
			{ID: m.user.UserID, At: frozeAt.Add(2 * time.Minute).Truncate(time.Second), Kind: purgeledger.KindFreeze,
				Trigger: frozeAt.Add(2 * time.Minute).Truncate(time.Second)}},
	} {
		rep, err := Reapply(bgctx, f.pool, entries, f.clock.now())
		if err != nil || rep.Unfreezes != 0 || rep.Lifted != 0 {
			t.Fatalf("reapply %+v %v: an unfreeze lifted a later freeze", rep, err)
		}
		if n := f.count(`SELECT count(*) FROM users WHERE id = $1 AND frozen_by = 'holder'`, m.user.UserID); n != 1 {
			t.Fatal("the freeze was lifted")
		}
	}
}

func TestAReplayOnTheLiveDatabaseAppliesNothing(t *testing.T) {
	t.Run("password, freeze and unfreeze", func(t *testing.T) {
		f := newAcctFixture(t)
		path, rec := ledgerRecorder(t)
		f.acct.Record = rec
		m := f.passwordMember("Maya")
		f.clock.advance(time.Hour + 700*time.Millisecond)
		newS := f.stretch(m.addr, "an entirely new password")
		if _, err := f.acct.ChangePassword(bgctx, m.info(), newS, m.deviceStepUp(keyproto.ActionPasswordChange, m.s, sumBytes(newS))); err != nil {
			t.Fatal(err)
		}
		m.s = newS
		if rep, err := Reapply(bgctx, f.pool, readLedger(t, path), f.clock.now()); err != nil || rep != (ReapplyReport{}) {
			t.Fatalf("a replay after a password change %+v %v, want nothing", rep, err)
		}
		f.clock.advance(time.Minute + 450*time.Millisecond)
		if _, err := f.acct.FreezeNow(bgctx, m.info(), m.deviceStepUp(keyproto.ActionAccountFreeze, m.s)); err != nil {
			t.Fatal(err)
		}
		before := saveRow(t, f.pool, "users", "id = $1", m.user.UserID)
		if rep, err := Reapply(bgctx, f.pool, readLedger(t, path), f.clock.now()); err != nil || rep != (ReapplyReport{}) {
			t.Fatalf("a replay after a freeze %+v %v, want nothing", rep, err)
		}
		if after := saveRow(t, f.pool, "users", "id = $1", m.user.UserID); after != before {
			t.Fatalf("a replay after a freeze changed the account:\n%s\n%s", before, after)
		}
		f.clock.advance(time.Hour + 250*time.Millisecond)
		in, err := m.loginPassword(m.s, m.device)
		if err != nil || !in.Restricted {
			t.Fatalf("a sign-in into the frozen account: %+v %v", in, err)
		}
		m.token = in.Session.Token
		if _, err := f.acct.Unfreeze(bgctx, m.info(), m.deviceStepUp(keyproto.ActionAccountUnfreeze, m.s)); err != nil {
			t.Fatal(err)
		}
		entries := readLedger(t, path)
		if len(entries) != 3 {
			t.Fatalf("ledger %+v, want a password change, a freeze and an unfreeze", entries)
		}
		if rep, err := Reapply(bgctx, f.pool, entries, f.clock.now()); err != nil || rep != (ReapplyReport{}) {
			t.Fatalf("a replay after an unfreeze %+v %v, want nothing", rep, err)
		}
		if _, err := f.sessions.Resolve(bgctx, m.token); err != nil {
			t.Fatalf("the replay revoked the live session: %v", err)
		}
	})
	t.Run("passkey and device removals", func(t *testing.T) {
		f := newKeyFixture(t).guarded()
		path, rec := ledgerRecorder(t)
		f.passkeys.Record, f.writers.Record = rec, rec
		f.clock.advance(time.Minute + 600*time.Millisecond)
		second, _, err := f.addOver(f.token, f.device, true)
		if err != nil {
			t.Fatal(err)
		}
		f.clock.advance(time.Minute + 350*time.Millisecond)
		su := f.stepUpPasskey(f.token, keyproto.ActionPasskeyDelete, second.CredID)
		if _, err := f.passkeys.DeletePasskey(bgctx, f.info(f.token), second.CredID, su); err != nil {
			t.Fatal(err)
		}
		if rep, err := Reapply(bgctx, f.pool, readLedger(t, path), f.clock.now()); err != nil || rep != (ReapplyReport{}) {
			t.Fatalf("a replay after a passkey removal %+v %v, want nothing", rep, err)
		}
		stolen := authtest.NewDevice(t)
		f.enrol(stolen)
		plantMailboxLink(t, f.pool, f.user, stolen.WriterID, 0x16)
		f.clock.advance(time.Minute + 820*time.Millisecond)
		su = f.stepUpPasskey(f.token, keyproto.ActionWriterRevoke, []byte(stolen.WriterID))
		if err := f.writers.Revoke(bgctx, f.user, f.info(f.token), f.revocation(stolen.WriterID, f.device, 0, make([]byte, 32), su)); err != nil {
			t.Fatal(err)
		}
		entries := readLedger(t, path)
		if len(entries) != 2 || entries[1].Kind != purgeledger.KindDevice {
			t.Fatalf("ledger %+v, want a passkey and a device removal", entries)
		}
		if rep, err := Reapply(bgctx, f.pool, entries, f.clock.now()); err != nil || rep != (ReapplyReport{}) {
			t.Fatalf("a replay after a device removal %+v %v, want nothing", rep, err)
		}
		if _, err := f.sessions.Resolve(bgctx, f.token); err != nil {
			t.Fatalf("the replay revoked the live session: %v", err)
		}
	})
}
