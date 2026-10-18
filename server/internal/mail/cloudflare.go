package mail

// cloudflare.go is the Cloudflare Email Service REST client (spec 02 §14.4).
// Tests point BaseURL at an httptest server; nothing in this repository's
// tests calls the real API.

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// DefaultBaseURL is the provider's API root.
const DefaultBaseURL = "https://api.cloudflare.com/client/v4"

const sendTimeout = 10 * time.Second

// Cloudflare sends through Email Service. Build it with NewCloudflare.
type Cloudflare struct {
	accountID, token, from string
	// FromName is the sender's display name ("Hasala"); empty sends the bare
	// address. config refuses a name with <, >, ", @ or a line break.
	FromName string
	BaseURL  string
	HTTP     *http.Client
}

// NewCloudflare validates its inputs. from is the sender address
// (no-reply@hasala.app); set FromName for a display name.
func NewCloudflare(accountID, token, from string) (*Cloudflare, error) {
	if accountID == "" || token == "" || from == "" {
		return nil, errors.New("mail: Cloudflare needs an account id, a token and a sender")
	}
	if strings.ContainsAny(token, "\r\n ") {
		return nil, errors.New("mail: the API token must be one line")
	}
	return &Cloudflare{accountID: accountID, token: token, from: from, BaseURL: DefaultBaseURL,
		HTTP: &http.Client{Timeout: sendTimeout,
			CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}}, nil
}

type cfRequest struct {
	To      string `json:"to"`
	From    any    `json:"from"` // the address, or cfAddress with a name
	Subject string `json:"subject"`
	Text    string `json:"text"`
	HTML    string `json:"html,omitempty"`
}

// cfAddress is the API's named address: {"address": ..., "name": ...}.
type cfAddress struct {
	Address string `json:"address"`
	Name    string `json:"name"`
}

type cfResponse struct {
	Success bool `json:"success"`
	Errors  []struct {
		Code    int    `json:"code"`
		Message string `json:"message"`
	} `json:"errors"`
	Result *struct {
		Delivered        []string `json:"delivered"`
		PermanentBounces []string `json:"permanent_bounces"`
		Queued           []string `json:"queued"`
		MessageID        string   `json:"message_id"`
		ID               string   `json:"id"`
	} `json:"result"`
}

// Send posts one message. The error carries the class, the HTTP status and the
// provider's numeric code, never the provider's body (it echoes addresses).
func (c *Cloudflare) Send(ctx context.Context, m Message) (string, error) {
	if m.To == "" || strings.ContainsAny(m.To, "\r\n,; ") || strings.ContainsAny(m.Subject, "\r\n") {
		return "", fmt.Errorf("%w: a message has one plain recipient and a one-line subject", ErrPermanent)
	}
	var from any = c.from
	if c.FromName != "" {
		from = cfAddress{Address: c.from, Name: c.FromName}
	}
	body, err := json.Marshal(cfRequest{To: m.To, From: from, Subject: m.Subject, Text: m.Text, HTML: m.HTML})
	if err != nil {
		return "", fmt.Errorf("%w: encode", ErrPermanent)
	}
	ctx, cancel := context.WithTimeout(ctx, sendTimeout)
	defer cancel()
	url := strings.TrimSuffix(c.BaseURL, "/") + "/accounts/" + c.accountID + "/email/sending/send"
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return "", fmt.Errorf("mail: request: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+c.token)
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return "", fmt.Errorf("mail: upstream: network")
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	var out cfResponse
	_ = json.Unmarshal(raw, &out)
	code := 0
	if len(out.Errors) > 0 {
		code = out.Errors[0].Code
	}
	switch {
	case resp.StatusCode == http.StatusOK && out.Success && out.Result != nil:
		for _, b := range out.Result.PermanentBounces {
			if strings.EqualFold(b, m.To) {
				return "", fmt.Errorf("%w: http 200", ErrBounced)
			}
		}
		id := out.Result.MessageID
		if id == "" {
			id = out.Result.ID
		}
		if len(id) > 128 {
			id = id[:128]
		}
		return id, nil
	case resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden:
		return "", fmt.Errorf("%w: http %d code %d", ErrAuth, resp.StatusCode, code)
	case resp.StatusCode == http.StatusBadRequest:
		return "", fmt.Errorf("%w: http %d code %d", ErrPermanent, resp.StatusCode, code)
	}
	return "", fmt.Errorf("mail: upstream: http %d code %d", resp.StatusCode, code)
}
