package purgeledger

import (
	"bufio"
	"bytes"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/google/uuid"
)

const (
	FileMode  fs.FileMode = 0o640
	Retention             = 60 * 24 * time.Hour
)

type Entry struct {
	ID uuid.UUID
	At time.Time
}

func Append(path string, ids []uuid.UUID, at time.Time) error {
	if path == "" {
		return errors.New("purgeledger: no ledger path")
	}
	if len(ids) == 0 {
		return nil
	}
	var buf bytes.Buffer
	for _, id := range ids {
		if id == uuid.Nil {
			return errors.New("purgeledger: zero account id")
		}
		buf.WriteString(formatEntry(Entry{ID: id, At: at}))
	}
	unlock, err := lock(path)
	if err != nil {
		return err
	}
	defer unlock()
	f, created, err := openAppend(path)
	if err != nil {
		return fmt.Errorf("purgeledger: open %s: %w", path, err)
	}
	if _, err := f.Write(buf.Bytes()); err != nil {
		_ = f.Close()
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
	return parse(path, raw)
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
	entries, err := Read(path)
	if err != nil || len(entries) == 0 {
		return 0, err
	}
	var keep bytes.Buffer
	dropped := 0
	for _, e := range entries {
		if e.At.Before(cutoff) {
			dropped++
			continue
		}
		keep.WriteString(formatEntry(e))
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
	seen := make(map[uuid.UUID]bool, len(entries))
	ids := make([]uuid.UUID, 0, len(entries))
	for _, e := range entries {
		if !seen[e.ID] {
			seen[e.ID] = true
			ids = append(ids, e.ID)
		}
	}
	return ids
}

func formatEntry(e Entry) string {
	return e.ID.String() + " " + e.At.UTC().Format(time.RFC3339) + "\n"
}

func parse(path string, raw []byte) ([]Entry, error) {
	if len(raw) > 0 && raw[len(raw)-1] != '\n' {
		return nil, fmt.Errorf("purgeledger: %s does not end with a newline: its last entry is incomplete", path)
	}
	var entries []Entry
	sc := bufio.NewScanner(bytes.NewReader(raw))
	for n := 1; sc.Scan(); n++ {
		idText, atText, ok := strings.Cut(sc.Text(), " ")
		id, idErr := uuid.Parse(idText)
		at, atErr := time.Parse(time.RFC3339, atText)
		if !ok || idErr != nil || atErr != nil || id == uuid.Nil || len(idText) != 36 {
			return nil, fmt.Errorf("purgeledger: %s line %d is not \"<account id> <RFC 3339 time>\"", path, n)
		}
		entries = append(entries, Entry{ID: id, At: at})
	}
	if err := sc.Err(); err != nil {
		return nil, fmt.Errorf("purgeledger: read %s: %w", path, err)
	}
	return entries, nil
}

func openAppend(path string) (*os.File, bool, error) {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_APPEND|os.O_CREATE|os.O_EXCL, FileMode)
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
	f, err = os.OpenFile(path, os.O_WRONLY|os.O_APPEND, 0)
	return f, false, err
}

func lock(path string) (func(), error) {
	f, err := os.OpenFile(path+".lock", os.O_RDWR|os.O_CREATE, FileMode)
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
