package api

import (
	"net/http"
	"testing"
)

func TestBankRequestsListAndSenderDomain(t *testing.T) {
	h := newHarness(t).passkeys()
	keys, fake, _ := h.accounts()
	a := h.passwordSignup(keys, fake, "maya@example.com")
	other := h.passwordSignup(keys, fake, "omar@example.com")

	w := h.req("GET", "/api/v1/bank-requests", a.token, nil)
	wantStatus(t, w, http.StatusOK)
	empty := decodeJSON[BankRequestsResponse](t, w)
	if len(empty.Requests) != 0 || len(empty.Catalog) < 10 {
		t.Fatalf("empty list %+v", empty)
	}
	states := map[string]string{}
	for _, c := range empty.Catalog {
		states[c.Bank] = c.State
	}
	if states["enbd"] != "supported" || states["fab"] != "requested" {
		t.Fatalf("catalog states %v", states)
	}

	wantStatus(t, h.req("POST", "/api/v1/bank-requests", a.token,
		map[string]any{"bank": "fab", "source": "app"}), http.StatusAccepted)
	wantStatus(t, h.req("POST", "/api/v1/bank-requests", a.token,
		map[string]any{"bank": "fab", "senderDomain": "Alerts.Example.AE.", "source": "app"}), http.StatusAccepted)
	wantStatus(t, h.req("POST", "/api/v1/bank-requests", a.token,
		map[string]any{"bank": "fab", "senderDomain": "second.example.ae", "source": "app"}), http.StatusAccepted)
	wantStatus(t, h.req("POST", "/api/v1/bank-requests", a.token,
		map[string]any{"bank": "other", "otherBank": "Some Bank", "source": "app"}), http.StatusAccepted)
	for _, bad := range []string{"localhost", "a b.ae", "x@bank.ae", "bank..ae", "-bank.ae"} {
		w := h.req("POST", "/api/v1/bank-requests", other.token,
			map[string]any{"bank": "adcb", "senderDomain": bad, "source": "app"})
		wantStatus(t, w, http.StatusBadRequest)
	}
	var domain string
	var n int
	_ = h.pool.QueryRow(bg, `SELECT sender_domain FROM bank_requests WHERE user_id = $1 AND bank_slug = 'fab'`, a.user).
		Scan(&domain)
	_ = h.pool.QueryRow(bg, `SELECT count(*) FROM bank_requests WHERE user_id = $1`, other.user).Scan(&n)
	if domain != "alerts.example.ae" || n != 0 {
		t.Fatalf("domain %q, %d refused requests stored", domain, n)
	}

	if _, err := h.pool.Exec(bg, `UPDATE banks SET status = 'planned' WHERE slug = 'fab'`); err != nil {
		t.Fatal(err)
	}
	got := decodeJSON[BankRequestsResponse](t, h.req("GET", "/api/v1/bank-requests", a.token, nil))
	if len(got.Requests) != 2 || got.Requests[0].Bank != "fab" || got.Requests[0].State != "collecting_samples" ||
		got.Requests[0].Name != "First Abu Dhabi Bank" || got.Requests[1].Bank != "other" ||
		got.Requests[1].Name != "Some Bank" || got.Requests[1].State != "requested" || got.Requests[0].RequestedAt == "" {
		t.Fatalf("requests %+v", got.Requests)
	}
	if o := decodeJSON[BankRequestsResponse](t, h.req("GET", "/api/v1/bank-requests", other.token, nil)); len(o.Requests) != 0 {
		t.Fatalf("another account sees %+v", o.Requests)
	}
	wantStatus(t, h.req("GET", "/api/v1/bank-requests", "", nil), http.StatusNotFound)
}
