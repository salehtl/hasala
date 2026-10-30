package purgeledger

import (
	"bufio"
	"bytes"
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"log/slog"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/keyproto"
)

const (
	FileMode  fs.FileMode = 0o660
	Retention             = 60 * 24 * time.Hour
)

var ErrNotWritten = errors.New("purgeledger: nothing was written")

type Kind string

const (
	KindPurge          Kind = ""
	KindFreeze         Kind = "freeze"
	KindDevice         Kind = "device"
	KindPassword       Kind = "password"
	KindUnfreeze       Kind = "unfreeze"
	KindWaitlistLeave  Kind = "waitlist-leave"
	KindPasskey        Kind = "passkey"
	KindWaitlistUnsent Kind = "waitlist-unsent"
	KindPhraseSeen     Kind = "phrase-seen"
	KindSessions       Kind = "sessions"
	KindEmail          Kind = "email"
	KindInviteRevoked  Kind = "invite-revoked"
	KindPurgeCancelled Kind = "purge-cancelled"
)

type Entry struct {
	ID         uuid.UUID
	At         time.Time
	Kind       Kind
	Trigger    time.Time
	Device     *Device
	Credential []byte
}

type Device struct {
	WriterID       string
	SignerWriterID string
	FinalCounter   int64
	FinalHead      []byte
	Nonce          []byte
	Sig            []byte
}

func Append(path string, ids []uuid.UUID, at time.Time) error {
	entries := make([]Entry, 0, len(ids))
	for _, id := range ids {
		entries = append(entries, Entry{ID: id, At: at})
	}
	return AppendEntries(path, entries...)
}

func AppendCancelled(path string, ids []uuid.UUID, at time.Time) error {
	entries := make([]Entry, 0, len(ids))
	for _, id := range ids {
		entries = append(entries, Entry{ID: id, At: at, Kind: KindPurgeCancelled})
	}
	return AppendEntries(path, entries...)
}

func AppendEntries(path string, entries ...Entry) error {
	if path == "" {
		return errors.New("purgeledger: no ledger path")
	}
	if len(entries) == 0 {
		return nil
	}
	var buf bytes.Buffer
	for _, e := range entries {
		if err := check(e); err != nil {
			return fmt.Errorf("%w: %w", ErrNotWritten, err)
		}
		buf.WriteString(formatEntry(e))
	}
	unlock, err := lock(path)
	if err != nil {
		return fmt.Errorf("%w: %w", ErrNotWritten, err)
	}
	defer unlock()
	return appendLocked(path, buf.Bytes())
}

func appendLocked(path string, line []byte) error {
	f, created, err := openAppend(path)
	if err != nil {
		return fmt.Errorf("%w: open %s: %w", ErrNotWritten, path, err)
	}
	if n, err := f.Write(line); err != nil {
		_ = f.Close()
		if n == 0 {
			return fmt.Errorf("%w: write %s: %w", ErrNotWritten, path, err)
		}
		return fmt.Errorf("purgeledger: write %s: %w", path, err)
	}
	if err := f.Sync(); err != nil {
		_ = f.Close()
		return fmt.Errorf("purgeledger: sync %s: %w", path, err)
	}
	if err := f.Close(); err != nil {
		return fmt.Errorf("purgeledger: close %s: %w", path, err)
	}
	if created {
		return syncDir(path)
	}
	return nil
}

func Read(path string) ([]Entry, error) {
	if path == "" {
		return nil, errors.New("purgeledger: no ledger path")
	}
	raw, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("purgeledger: read %s: %w", path, err)
	}
	lines, err := parse(path, raw)
	if err != nil {
		return nil, err
	}
	entries := make([]Entry, 0, len(lines))
	for _, l := range lines {
		if l.unknown {
			slog.Warn("purgeledger: skipped an entry of a kind this hasalad does not know",
				"path", path, "line", l.n, "kind", string(l.e.Kind))
			continue
		}
		entries = append(entries, l.e)
	}
	return entries, nil
}

func Prune(path string, cutoff time.Time) (int, error) {
	if path == "" {
		return 0, errors.New("purgeledger: no ledger path")
	}
	unlock, err := lock(path)
	if err != nil {
		return 0, err
	}
	defer unlock()
	return pruneLocked(path, cutoff)
}

func pruneLocked(path string, cutoff time.Time) (int, error) {
	raw, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return 0, nil
	}
	if err != nil {
		return 0, fmt.Errorf("purgeledger: read %s: %w", path, err)
	}
	lines, err := parse(path, raw)
	if err != nil || len(lines) == 0 {
		return 0, err
	}
	var keep bytes.Buffer
	dropped := 0
	for _, l := range lines {
		if l.e.At.Before(cutoff) {
			dropped++
			continue
		}
		if l.unknown {
			keep.WriteString(l.text + "\n")
			continue
		}
		keep.WriteString(formatEntry(l.e))
	}
	if dropped == 0 {
		return 0, nil
	}
	tmp := path + ".tmp"
	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, FileMode)
	if err != nil {
		return 0, fmt.Errorf("purgeledger: prune %s: %w", path, err)
	}
	werr := f.Chmod(FileMode)
	if werr == nil {
		_, werr = f.Write(keep.Bytes())
	}
	if werr == nil {
		werr = f.Sync()
	}
	if cerr := f.Close(); werr == nil {
		werr = cerr
	}
	if werr == nil {
		werr = os.Rename(tmp, path)
	}
	if werr != nil {
		_ = os.Remove(tmp)
		return 0, fmt.Errorf("purgeledger: prune %s: %w", path, werr)
	}
	return dropped, syncDir(path)
}

func IDs(entries []Entry) []uuid.UUID {
	armed := make(map[uuid.UUID]bool, len(entries))
	for _, e := range entries {
		switch e.Kind {
		case KindPurge:
			armed[e.ID] = true
		case KindPurgeCancelled:
			armed[e.ID] = false
		}
	}
	ids := make([]uuid.UUID, 0, len(entries))
	for _, e := range entries {
		if e.Kind == KindPurge && armed[e.ID] {
			armed[e.ID] = false
			ids = append(ids, e.ID)
		}
	}
	return ids
}

func check(e Entry) error {
	if e.ID == uuid.Nil {
		return errors.New("purgeledger: zero id")
	}
	if e.Kind != KindPasskey && e.Credential != nil {
		return fmt.Errorf("purgeledger: a %q entry carries no credential", e.Kind)
	}
	switch e.Kind {
	case KindPurge, KindPassword, KindUnfreeze, KindWaitlistLeave, KindWaitlistUnsent, KindPhraseSeen,
		KindSessions, KindEmail, KindInviteRevoked, KindPurgeCancelled:
		if !e.Trigger.IsZero() || e.Device != nil {
			return fmt.Errorf("purgeledger: a %q entry carries no trigger and no device", e.Kind)
		}
	case KindPasskey:
		if !e.Trigger.IsZero() || e.Device != nil || keyproto.CheckCredentialID(e.Credential) != nil {
			return errors.New("purgeledger: a passkey entry carries a credential id and no trigger or device")
		}
	case KindFreeze:
		if e.Trigger.IsZero() || e.Device != nil {
			return errors.New("purgeledger: a freeze entry carries its trigger time and no device")
		}
	case KindDevice:
		d := e.Device
		if !e.Trigger.IsZero() || d == nil || !keyproto.ValidWriterID(d.WriterID) || !keyproto.ValidWriterID(d.SignerWriterID) ||
			d.FinalCounter < 0 || len(d.FinalHead) != keyproto.HashSize || len(d.Nonce) != keyproto.NonceSize ||
			len(d.Sig) != keyproto.Ed25519SigSize {
			return errors.New("purgeledger: a device entry carries a well-formed revocation and no trigger")
		}
	default:
		return fmt.Errorf("purgeledger: unknown kind %q", e.Kind)
	}
	return nil
}

func formatEntry(e Entry) string {
	line := e.ID.String() + " " + e.At.UTC().Format(time.RFC3339)
	switch e.Kind {
	case KindFreeze:
		line += " " + string(e.Kind) + " " + e.Trigger.UTC().Format(time.RFC3339)
	case KindDevice:
		d := e.Device
		line += " " + string(e.Kind) + " " + d.WriterID + " " + d.SignerWriterID + " " +
			strconv.FormatInt(d.FinalCounter, 10) + " " + hex.EncodeToString(d.FinalHead) + " " +
			hex.EncodeToString(d.Nonce) + " " + hex.EncodeToString(d.Sig)
	case KindPasskey:
		line += " " + string(e.Kind) + " " + hex.EncodeToString(e.Credential)
	case KindPassword, KindUnfreeze, KindWaitlistLeave, KindWaitlistUnsent, KindPhraseSeen,
		KindSessions, KindEmail, KindInviteRevoked, KindPurgeCancelled:
		line += " " + string(e.Kind)
	}
	return line + "\n"
}

func parseTime(s string) (time.Time, bool) {
	t, err := time.Parse(time.RFC3339, s)
	return t, err == nil
}

func parseHex(s string, n int) ([]byte, bool) {
	if len(s) != 2*n || strings.ToLower(s) != s {
		return nil, false
	}
	b, err := hex.DecodeString(s)
	return b, err == nil
}

func unknownKind(k Kind) bool {
	switch k {
	case KindPurge, KindFreeze, KindDevice, KindPassword, KindUnfreeze, KindWaitlistLeave, KindPasskey, KindWaitlistUnsent,
		KindPhraseSeen, KindSessions, KindEmail, KindInviteRevoked, KindPurgeCancelled:
		return false
	}
	for _, r := range string(k) {
		if (r < 'a' || r > 'z') && (r < '0' || r > '9') && r != '-' {
			return false
		}
	}
	return true
}

type line struct {
	n       int
	e       Entry
	unknown bool
	text    string
}

func parseUnknown(text string) (Entry, bool) {
	f := strings.Split(text, " ")
	if len(f) < 3 || len(f[0]) != 36 {
		return Entry{}, false
	}
	id, err := uuid.Parse(f[0])
	if err != nil || id == uuid.Nil || id.String() != f[0] {
		return Entry{}, false
	}
	at, ok := parseTime(f[1])
	if !ok || !unknownKind(Kind(f[2])) {
		return Entry{}, false
	}
	for _, x := range f[3:] {
		if x == "" {
			return Entry{}, false
		}
	}
	return Entry{ID: id, At: at, Kind: Kind(f[2])}, true
}

func parseLine(text string) (Entry, bool) {
	f := strings.Split(text, " ")
	if len(f) < 2 || len(f[0]) != 36 {
		return Entry{}, false
	}
	id, err := uuid.Parse(f[0])
	if err != nil || id == uuid.Nil {
		return Entry{}, false
	}
	at, ok := parseTime(f[1])
	if !ok {
		return Entry{}, false
	}
	e := Entry{ID: id, At: at}
	if len(f) == 2 {
		return e, true
	}
	e.Kind = Kind(f[2])
	switch e.Kind {
	case KindPassword, KindUnfreeze, KindWaitlistLeave, KindWaitlistUnsent, KindPhraseSeen,
		KindSessions, KindEmail, KindInviteRevoked, KindPurgeCancelled:
		if len(f) != 3 {
			return Entry{}, false
		}
	case KindPasskey:
		if len(f) != 4 || len(f[3]) < 2*keyproto.MinCredentialID || len(f[3]) > 2*keyproto.MaxCredentialID {
			return Entry{}, false
		}
		if e.Credential, ok = parseHex(f[3], len(f[3])/2); !ok {
			return Entry{}, false
		}
	case KindFreeze:
		if len(f) != 4 {
			return Entry{}, false
		}
		if e.Trigger, ok = parseTime(f[3]); !ok {
			return Entry{}, false
		}
	case KindDevice:
		if len(f) != 9 {
			return Entry{}, false
		}
		d := &Device{WriterID: f[3], SignerWriterID: f[4]}
		n, err := strconv.ParseInt(f[5], 10, 64)
		if err != nil || strconv.FormatInt(n, 10) != f[5] {
			return Entry{}, false
		}
		d.FinalCounter = n
		var okH, okN, okS bool
		d.FinalHead, okH = parseHex(f[6], keyproto.HashSize)
		d.Nonce, okN = parseHex(f[7], keyproto.NonceSize)
		d.Sig, okS = parseHex(f[8], keyproto.Ed25519SigSize)
		if !okH || !okN || !okS {
			return Entry{}, false
		}
		e.Device = d
	default:
		return Entry{}, false
	}
	return e, check(e) == nil
}

func parse(path string, raw []byte) ([]line, error) {
	if len(raw) > 0 && raw[len(raw)-1] != '\n' {
		return nil, fmt.Errorf("purgeledger: %s does not end with a newline: its last entry is incomplete", path)
	}
	var lines []line
	sc := bufio.NewScanner(bytes.NewReader(raw))
	for n := 1; sc.Scan(); n++ {
		text := sc.Text()
		if e, ok := parseLine(text); ok {
			lines = append(lines, line{n: n, e: e, text: text})
			continue
		}
		e, ok := parseUnknown(text)
		if !ok {
			return nil, fmt.Errorf("purgeledger: %s line %d is not \"<id> <RFC 3339 time> [<kind> <fields>]\"", path, n)
		}
		lines = append(lines, line{n: n, e: e, unknown: true, text: text})
	}
	if err := sc.Err(); err != nil {
		return nil, fmt.Errorf("purgeledger: read %s: %w", path, err)
	}
	return lines, nil
}

func openAppend(path string) (*os.File, bool, error) {
	return openShared(path, os.O_WRONLY|os.O_APPEND)
}

func openShared(path string, flag int) (*os.File, bool, error) {
	f, err := os.OpenFile(path, flag|os.O_CREATE|os.O_EXCL, FileMode)
	if err == nil {
		if err := f.Chmod(FileMode); err != nil {
			_ = f.Close()
			return nil, false, err
		}
		return f, true, nil
	}
	if !errors.Is(err, fs.ErrExist) {
		return nil, false, err
	}
	f, err = os.OpenFile(path, flag, 0)
	return f, false, err
}

func lock(path string) (func(), error) {
	f, _, err := openShared(path+".lock", os.O_RDWR)
	if err != nil {
		return nil, fmt.Errorf("purgeledger: lock %s: %w", path, err)
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX); err != nil {
		_ = f.Close()
		return nil, fmt.Errorf("purgeledger: lock %s: %w", path, err)
	}
	return func() {
		_ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
		_ = f.Close()
	}, nil
}

func syncDir(path string) error {
	d, err := os.Open(filepath.Dir(path))
	if err != nil {
		return fmt.Errorf("purgeledger: sync directory of %s: %w", path, err)
	}
	defer d.Close()
	if err := d.Sync(); err != nil {
		return fmt.Errorf("purgeledger: sync directory of %s: %w", path, err)
	}
	return nil
}
