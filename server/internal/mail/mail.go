// Package mail is hasalad's outbound email transport (spec 02 §14.4): the
// Message a renderer builds, the Sender interface, the Cloudflare Email
// Service REST client, a Fake for tests and local runs, and spec 02 §14.6's
// plain-text templates.
//
// Only internal/mailq calls Sender.Send (spec 07 §6.1), so every email this
// server sends has a mail_log row. This package logs nothing on success and
// never logs a recipient, subject, body, code or token.
package mail

import (
	"context"
	"errors"
	"sync"
)

// Message is one email to one address.
type Message struct {
	To      string
	Subject string
	Text    string
	HTML    string // empty for every kind spec 02 owns (plain text only)
}

// Sender delivers one message. It returns the provider's message id when it
// gives one. Errors are classified with errors.Is: ErrPermanent (refused for
// good), ErrBounced (the recipient is a permanent bounce), ErrAuth (the token
// or the account is wrong: every lane stops); anything else is transient.
type Sender interface {
	Send(ctx context.Context, m Message) (providerID string, err error)
}

// Result classes (spec 02 §14.4, 05 §7.7).
var (
	ErrPermanent = errors.New("mail: refused by the provider")
	ErrBounced   = errors.New("mail: the recipient is a permanent bounce")
	ErrAuth      = errors.New("mail: the provider refused the credentials")
)

// Fake records every message instead of sending it (spec 02 §14.4
// "Unconfigured"). Tests read codes and freeze tokens from it. Err, when set,
// decides each send's outcome. Max, when positive, keeps only the newest Max
// messages (serve without [email] is a long-running process).
type Fake struct {
	mu   sync.Mutex
	sent []Message
	Err  func(Message) error
	Max  int
}

// Send records m.
func (f *Fake) Send(_ context.Context, m Message) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.Err != nil {
		if err := f.Err(m); err != nil {
			return "", err
		}
	}
	f.sent = append(f.sent, m)
	if f.Max > 0 && len(f.sent) > f.Max {
		f.sent = append([]Message(nil), f.sent[len(f.sent)-f.Max:]...)
	}
	return "fake", nil
}

// Sent is a copy of every message recorded so far, oldest first.
func (f *Fake) Sent() []Message {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]Message(nil), f.sent...)
}

// To is every message recorded for one recipient, oldest first.
func (f *Fake) To(addr string) []Message {
	var out []Message
	for _, m := range f.Sent() {
		if m.To == addr {
			out = append(out, m)
		}
	}
	return out
}

// Reset forgets every recorded message.
func (f *Fake) Reset() {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.sent = nil
}
