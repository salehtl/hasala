package turnstile

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"slices"
	"strings"
	"time"
)

const DefaultVerifyURL = "https://challenges.cloudflare.com/turnstile/v0/siteverify"

const Timeout = 10 * time.Second

const maxToken = 2048

var (
	ErrRefused     = errors.New("turnstile: token refused")
	ErrUnavailable = errors.New("turnstile: siteverify unavailable")
)

type Verifier struct {
	secret    string
	Hostnames []string
	URL       string
	HTTP      *http.Client
}

func New(secret string, hostnames []string) (*Verifier, error) {
	secret = strings.TrimSpace(secret)
	if secret == "" || strings.ContainsAny(secret, "\r\n ") {
		return nil, errors.New("turnstile: the secret must be one non-empty line")
	}
	return &Verifier{secret: secret, Hostnames: hostnames, URL: DefaultVerifyURL,
		HTTP: &http.Client{Timeout: Timeout,
			CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}}, nil
}

type answer struct {
	Success  bool   `json:"success"`
	Hostname string `json:"hostname"`
	Action   string `json:"action"`
}

func (v *Verifier) Verify(ctx context.Context, token, action string) error {
	if token == "" || len(token) > maxToken {
		return ErrRefused
	}
	ctx, cancel := context.WithTimeout(ctx, Timeout)
	defer cancel()
	form := url.Values{"secret": {v.secret}, "response": {token}}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, v.URL, strings.NewReader(form.Encode()))
	if err != nil {
		return fmt.Errorf("%w: request", ErrUnavailable)
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := v.HTTP.Do(req)
	if err != nil {
		return fmt.Errorf("%w: network", ErrUnavailable)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 16<<10))
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("%w: http %d", ErrUnavailable, resp.StatusCode)
	}
	var a answer
	if err := json.Unmarshal(raw, &a); err != nil {
		return fmt.Errorf("%w: bad body", ErrUnavailable)
	}
	switch {
	case !a.Success:
		return ErrRefused
	case action != "" && a.Action != action:
		return fmt.Errorf("%w: action", ErrRefused)
	case len(v.Hostnames) > 0 && !slices.Contains(v.Hostnames, a.Hostname):
		return fmt.Errorf("%w: hostname", ErrRefused)
	}
	return nil
}
