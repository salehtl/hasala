package mail

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

// CloudflareAPI is the API base the client talks to in production.
const CloudflareAPI = "https://api.cloudflare.com/client/v4"

// cloudflareTimeout is the per-call timeout (spec 02 §14.4).
const cloudflareTimeout = 10 * time.Second

// Cloudflare is the Cloudflare Email Service REST client (spec 02 §14.4):
// one POST per message, to one recipient, plain text (HTML only when a
// message carries it), from the configured sender. It holds the API token
// in memory and never logs it.
type Cloudflare struct {
	AccountID string
	Token     string
	From      string // "no-reply@hasala.app"
	// BaseURL defaults to CloudflareAPI; a test points it at an httptest
	// server. No test talks to the real API.
	BaseURL string
	Client  *http.Client
}

// cfRequest is the body the API takes. Only these fields are ever sent: no
// headers, attachments, cc, bcc or reply_to.
type cfRequest struct {
	To      string `json:"to"`
	From    string `json:"from"`
	Subject string `json:"subject"`
	Text    string `json:"text"`
	HTML    string `json:"html,omitempty"`
}

type cfError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

type cfResponse struct {
	Success bool      `json:"success"`
	Errors  []cfError `json:"errors"`
	Result  *struct {
		Delivered        []string `json:"delivered"`
		PermanentBounces []string `json:"permanent_bounces"`
		Queued           []string `json:"queued"`
	} `json:"result"`
}

// SendError carries the classification details mailq writes to
// mail_log.error: the HTTP status and Cloudflare's numeric code, never the
// provider's message (which may echo the address).
type SendError struct {
	Class  error
	Status int
	Code   int
}

func (e *SendError) Error() string {
	return fmt.Sprintf("%v (http %d, cf %d)", e.Class, e.Status, e.Code)
}

func (e *SendError) Unwrap() error { return e.Class }

// errTransient is the class of everything retryable.
var errTransient = errors.New("mail: transient failure")

// Send posts m. See Sender for the error classes.
func (c *Cloudflare) Send(ctx context.Context, m Message) (string, error) {
	if c.AccountID == "" || c.Token == "" || c.From == "" {
		return "", fmt.Errorf("%w: the Cloudflare client is not configured", ErrAuth)
	}
	if m.To == "" || strings.ContainsAny(m.To, "\r\n,;") || strings.ContainsAny(m.Subject, "\r\n") {
		return "", fmt.Errorf("%w: a message has one plain recipient and a one-line subject", ErrPermanent)
	}
	base := c.BaseURL
	if base == "" {
		base = CloudflareAPI
	}
	body, err := json.Marshal(cfRequest{To: m.To, From: c.From, Subject: m.Subject, Text: m.Text, HTML: m.HTML})
	if err != nil {
		return "", err
	}
	ctx, cancel := context.WithTimeout(ctx, cloudflareTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		base+"/accounts/"+c.AccountID+"/email/sending/send", bytes.NewReader(body))
	if err != nil {
		return "", err
	}
	req.Header.Set("Authorization", "Bearer "+c.Token)
	req.Header.Set("Content-Type", "application/json")
	client := c.Client
	if client == nil {
		client = &http.Client{Timeout: cloudflareTimeout}
	}
	resp, err := client.Do(req)
	if err != nil {
		return "", &SendError{Class: errTransient}
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
				return "", &SendError{Class: ErrBounced, Status: resp.StatusCode}
			}
		}
		return "", nil
	case resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden:
		return "", &SendError{Class: ErrAuth, Status: resp.StatusCode, Code: code}
	case resp.StatusCode == http.StatusBadRequest:
		return "", &SendError{Class: ErrPermanent, Status: resp.StatusCode, Code: code}
	default:
		// 429, 5xx, a 200 that is not a success, anything unexpected.
		return "", &SendError{Class: errTransient, Status: resp.StatusCode, Code: code}
	}
}
