// Package mail is the outbound email abstraction (spec 02 §14.4, spec 07
// §6.1): a Message, the Sender interface, the error classes the queue acts
// on, the Cloudflare Email Service client, and a Fake for tests and local runs.
//
// Only internal/mailq calls Sender.Send (spec 07 F7-5), so every email passes
// through the email log. Nothing here logs a recipient, subject or body.
package mail

import (
	"context"
	"errors"
	"sync"
)

// Message is one email to one recipient. HTML is optional.
type Message struct {
	To, Subject, Text, HTML string
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

// Fake records every message instead of sending it. Tests read codes and
// links from it; `serve` without an [email] group uses it and logs a WARN.
type Fake struct {
	mu   sync.Mutex
	sent []Message
	// Err, when set, is returned for every send (and nothing is recorded).
	Err error
	// ErrFor, when set, decides per message.
	ErrFor func(Message) error
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
	return "fake-" + itoa(len(f.sent)), nil
}

// Sent returns a copy of every recorded message.
func (f *Fake) Sent() []Message {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]Message(nil), f.sent...)
}

// Reset forgets the recorded messages.
func (f *Fake) Reset() {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.sent = nil
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var b [20]byte
	i := len(b)
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	return string(b[i:])
}
