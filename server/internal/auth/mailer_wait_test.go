package auth

import (
	"bytes"
	"context"
	"testing"
	"time"

	"github.com/salehtl/hasala/server/internal/mail"
	"github.com/salehtl/hasala/server/internal/mailq"
	"github.com/salehtl/hasala/server/internal/pgtest"
)

type heldSender struct {
	started chan struct{}
	release chan struct{}
	fake    mail.Fake
}

func (s *heldSender) Send(ctx context.Context, m mail.Message) (string, error) {
	s.started <- struct{}{}
	<-s.release
	return s.fake.Send(ctx, m)
}

type oneTag struct{}

func (oneTag) EmailTag(string) []byte { return bytes.Repeat([]byte{7}, 32) }

func TestAStopWaitsForACodeEmailAlreadyHandedOver(t *testing.T) {
	sender := &heldSender{started: make(chan struct{}, 2), release: make(chan struct{})}
	m := &Mailer{Queue: mailq.New(pgtest.New(t), sender, oneTag{})}
	code := IssuedCode{Purpose: PurposeSignup, To: "stopping@example.com", Tag: bytes.Repeat([]byte{7}, 32), Code: "123456", Send: true}

	m.SendCodes(code)
	select {
	case <-sender.started:
	case <-time.After(10 * time.Second):
		t.Fatal("the email never reached the sender")
	}

	short, cancel := context.WithTimeout(bgctx, 50*time.Millisecond)
	defer cancel()
	m.Wait(short)
	if short.Err() == nil {
		t.Fatal("the wait ended while the email was still on its way")
	}

	done := make(chan struct{})
	go func() {
		m.Wait(bgctx)
		close(done)
	}()
	select {
	case <-done:
		t.Fatal("the wait ended before the email was sent")
	case <-time.After(50 * time.Millisecond):
	}
	close(sender.release)
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("the wait did not end after the email was sent")
	}
	if len(sender.fake.Sent()) != 1 {
		t.Fatalf("%d emails sent, want the one handed over", len(sender.fake.Sent()))
	}
}

func TestWaitingWithNoCodeEmailsReturnsAtOnce(t *testing.T) {
	var none *Mailer
	none.Wait(bgctx)
	done := make(chan struct{})
	go func() {
		(&Mailer{}).Wait(bgctx)
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("a wait with nothing in flight did not return")
	}
}
