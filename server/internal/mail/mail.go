// Package mail is the outbound email abstraction (spec 02 §14.4, spec 07
// §6.1): a Message, the Sender interface, the error classes the queue acts
// on, the Cloudflare Email Service client, Unconfigured for a server without
// email, a Fake for tests, and spec 02 §14.6's plain-text account emails
// (account.go). Spec 07's templated kinds render in internal/mailq.
//
// Only internal/mailq calls Sender.Send (spec 07 F7-5), so every email passes
// through the email log. Nothing here logs a recipient, subject or body.
package mail

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"sync"
)

// Message is one email to one recipient. HTML is optional.
type Message struct {
	To, Subject, Text, HTML string
	Unsubscribe             string
}

// Sender sends one message and returns the provider's message id when it gives
// one. Errors are classified: ErrPermanent (refused for good), ErrBounced (the
// recipient is a permanent bounce), ErrAuth (the token or entitlement is
// wrong: stop sending), anything else transient.
type Sender interface {
	Send(ctx context.Context, m Message) (providerID string, err error)
}

// The error classes (spec 02 §14.4).
var (
	ErrPermanent = errors.New("mail: refused permanently")
	ErrBounced   = errors.New("mail: the recipient is a permanent bounce")
	ErrAuth      = errors.New("mail: the provider refused the credentials")
)

// ErrNotConfigured is Unconfigured's refusal. It is ErrPermanent, so the
// queue marks the row failed at once and never retries it.
var ErrNotConfigured = fmt.Errorf("%w: not configured", ErrPermanent)

// Unconfigured is `serve`'s Sender without an [email] group: every send fails
// permanently and nothing is kept, so the email log says `failed` (never
// `sent` for a message that went nowhere) and no rendered code, link key or
// token stays in memory. An invite whose email failed can be resent once
// email is configured; the resend re-mints its code.
type Unconfigured struct{}

// Send refuses m.
func (Unconfigured) Send(context.Context, Message) (string, error) { return "", ErrNotConfigured }

// Fake records every message instead of sending it, for tests only: it keeps
// every rendered message (codes and links included) in memory.
type Fake struct {
	mu   sync.Mutex
	sent []Message
	// Err, when set, is returned for every send (and nothing is recorded).
	Err error
	// ErrFor, when set, decides per message.
	ErrFor func(Message) error
	// Max, when positive, keeps only the newest Max messages.
	Max int
}

// Send records m.
func (f *Fake) Send(_ context.Context, m Message) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.Err != nil {
		return "", f.Err
	}
	if f.ErrFor != nil {
		if err := f.ErrFor(m); err != nil {
			return "", err
		}
	}
	f.sent = append(f.sent, m)
	n := len(f.sent)
	if f.Max > 0 && len(f.sent) > f.Max {
		f.sent = append([]Message(nil), f.sent[len(f.sent)-f.Max:]...)
	}
	return "fake-" + strconv.Itoa(n), nil
}

// Sent returns a copy of every recorded message.
func (f *Fake) Sent() []Message {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]Message(nil), f.sent...)
}

// To is every recorded message to one recipient, oldest first.
func (f *Fake) To(addr string) []Message {
	var out []Message
	for _, m := range f.Sent() {
		if m.To == addr {
			out = append(out, m)
		}
	}
	return out
}

// Reset forgets the recorded messages.
func (f *Fake) Reset() {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.sent = nil
}
