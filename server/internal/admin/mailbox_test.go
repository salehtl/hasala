package admin

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
)

// insertMailboxGrant plants one mailbox_grants row directly, below
// internal/mailbox's own API — this file tests what the CONSOLE reads back,
// not what the broker writes, so the fixture writes the row itself rather
// than going through mailbox.Grants.
func insertMailboxGrant(t *testing.T, c *console, userID uuid.UUID, status string, lastBrokerAt *time.Time) []byte {
	t.Helper()
	hash := sha256.Sum256([]byte("refresh-token-for-" + userID.String()))
	if _, err := c.pool.Exec(bg,
		`INSERT INTO mailbox_grants (user_id, provider, status, refresh_token_hash, created_at, last_broker_at)
		 VALUES ($1, 'gmail', $2, $3, now(), $4)`,
		userID, status, hash[:], lastBrokerAt); err != nil {
		t.Fatalf("insert mailbox grant: %v", err)
	}
	return hash[:]
}

func TestMailboxIsBehindTheToken(t *testing.T) {
	c := newConsole(t)
	if rec := c.do(http.MethodGet, "/admin/mailbox", "", nil); rec.Code != http.StatusUnauthorized {
		t.Fatalf("GET /admin/mailbox without a token: %d, want 401", rec.Code)
	}
}

// The page's headline number: how many grants sit in each status. Two
// active, one reconnect_required — the count that means something is
// actually broken must be distinguishable from the count that does not.
func TestMailboxReportsGrantCountsByStatus(t *testing.T) {
	c := newConsole(t)
	a, b, cc := insertUser(t, c.pool), insertUser(t, c.pool), insertUser(t, c.pool)
	insertMailboxGrant(t, c, a, "active", nil)
	insertMailboxGrant(t, c, b, "active", nil)
	insertMailboxGrant(t, c, cc, "reconnect_required", nil)

	got := c.ok("GET", "/admin/mailbox", nil)
	byStatus, ok := got["grants_by_status"].(map[string]any)
	if !ok {
		t.Fatalf("grants_by_status missing or the wrong shape: %v", got)
	}
	if byStatus["active"] != float64(2) {
		t.Errorf("active count = %v, want 2", byStatus["active"])
	}
	if byStatus["reconnect_required"] != float64(1) {
		t.Errorf("reconnect_required count = %v, want 1", byStatus["reconnect_required"])
	}
}

// No grants at all must render as zero counts and a null age — never a
// fabricated zero, which would claim a broker contact that never happened.
func TestMailboxWithNoGrantsReportsEmptyCountsAndNullAge(t *testing.T) {
	c := newConsole(t)
	got := c.ok("GET", "/admin/mailbox", nil)
	byStatus, ok := got["grants_by_status"].(map[string]any)
	if !ok || len(byStatus) != 0 {
		t.Fatalf("grants_by_status = %v, want an empty map", got["grants_by_status"])
	}
	if age, present := got["max_last_broker_age_seconds"]; present && age != nil {
		t.Errorf("max_last_broker_age_seconds = %v, want null with no grants", age)
	}
}

// The reported age is the OLDEST touch, not the newest — the number that
// tells an operator a broker loop may be stuck, not the reassuring one.
func TestMailboxMaxLastBrokerAgeIsTheOldestTouchNotTheNewest(t *testing.T) {
	c := newConsole(t)
	a, b := insertUser(t, c.pool), insertUser(t, c.pool)
	recent := time.Now().Add(-1 * time.Minute)
	stale := time.Now().Add(-10 * time.Hour)
	insertMailboxGrant(t, c, a, "active", &recent)
	insertMailboxGrant(t, c, b, "reconnect_required", &stale)

	got := c.ok("GET", "/admin/mailbox", nil)
	age, ok := got["max_last_broker_age_seconds"].(float64)
	if !ok {
		t.Fatalf("max_last_broker_age_seconds missing or not a number: %v", got)
	}
	// ~10 hours = 36000s. The window is wide (10 minutes either side) to
	// absorb test wall-clock slack, but far too narrow to mistake the
	// 1-minute-old grant's age for the 10-hour-old one's.
	if age < 35400 || age > 36600 {
		t.Errorf("max_last_broker_age_seconds = %v, want ~36000 (the STALE grant, not the recent one)", age)
	}
}

// TestMailboxNeverRendersATokenHash is the content-free proof this route
// exists to satisfy. mailbox_grants has no email, subject or transaction
// column to accidentally leak — the mutation this guards against is a
// future change to mailboxGrantHealth that also scans refresh_token_hash
// (or user_id) into the response. Mutate the query to do that and this test
// must fail: the response is checked for the exact hex digest a real grant
// row holds, not merely for the absence of an unrelated word.
func TestMailboxNeverRendersATokenHash(t *testing.T) {
	c := newConsole(t)
	u := insertUser(t, c.pool)
	hash := insertMailboxGrant(t, c, u, "active", nil)
	hexHash := hex.EncodeToString(hash)

	rec := c.do(http.MethodGet, "/admin/mailbox", testToken, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("GET /admin/mailbox: %d %s", rec.Code, rec.Body)
	}
	body := rec.Body.String()
	if strings.Contains(body, hexHash) {
		t.Fatalf("response contains the grant's refresh-token-hash hex: %s", body)
	}
	if strings.Contains(body, u.String()) {
		t.Fatalf("response names a user id: %s", body)
	}

	// Content-free does not mean empty: the counts this route exists to
	// report must still be present.
	var out map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatal(err)
	}
	byStatus, _ := out["grants_by_status"].(map[string]any)
	if byStatus["active"] != float64(1) {
		t.Fatalf("grants_by_status = %v, want active:1", out["grants_by_status"])
	}
}
