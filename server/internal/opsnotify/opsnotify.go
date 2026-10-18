// Package opsnotify posts operator notices to an ntfy topic: a fixed title
// and message, and an optional click URL (the operator console). A notice
// never carries anything about a person (no email address, bank or id), so
// the topic and its subscribers learn only that something happened.
package opsnotify

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// Timeout bounds one post; a notice that cannot be delivered is dropped.
const Timeout = 10 * time.Second

// Notifier posts to URL. Build it with New.
type Notifier struct {
	URL    string
	Click  string // optional; the Click header
	Client *http.Client
}

// New returns a Notifier for url (an ntfy topic URL) and click ("" for none).
func New(url, click string) *Notifier {
	return &Notifier{URL: url, Click: click, Client: &http.Client{Timeout: Timeout}}
}

// Post sends one notice and reports whether ntfy accepted it.
func (n *Notifier) Post(ctx context.Context, title, message, tags string) error {
	ctx, cancel := context.WithTimeout(ctx, Timeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, n.URL, strings.NewReader(message))
	if err != nil {
		return fmt.Errorf("opsnotify: %w", err)
	}
	req.Header.Set("Content-Type", "text/plain; charset=utf-8")
	req.Header.Set("Title", title)
	if tags != "" {
		req.Header.Set("Tags", tags)
	}
	if n.Click != "" {
		req.Header.Set("Click", n.Click)
	}
	resp, err := n.Client.Do(req)
	if err != nil {
		return fmt.Errorf("opsnotify: %w", err)
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
	if resp.StatusCode/100 != 2 {
		return fmt.Errorf("opsnotify: ntfy answered %d", resp.StatusCode)
	}
	return nil
}
