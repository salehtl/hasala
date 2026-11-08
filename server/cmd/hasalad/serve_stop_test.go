package main

import (
	"bytes"
	"context"
	"net"
	"net/http"
	"testing"
	"time"

	"github.com/salehtl/hasala/server/internal/api"
	"github.com/salehtl/hasala/server/internal/auth"
	"github.com/salehtl/hasala/server/internal/mail"
	"github.com/salehtl/hasala/server/internal/mailq"
	"github.com/salehtl/hasala/server/internal/pgtest"
)

type stopHeldSender struct {
	started chan struct{}
	release chan struct{}
	fake    mail.Fake
}

func (s *stopHeldSender) Send(ctx context.Context, m mail.Message) (string, error) {
	close(s.started)
	<-s.release
	return s.fake.Send(ctx, m)
}

type stopTag struct{}

func (stopTag) EmailTag(string) []byte { return bytes.Repeat([]byte{7}, 32) }

func TestFinishingServingWaitsForTheCodeEmailOfTheLastRequest(t *testing.T) {
	sender := &stopHeldSender{started: make(chan struct{}), release: make(chan struct{})}
	mailer := &auth.Mailer{Queue: mailq.New(pgtest.New(t), sender, stopTag{})}
	srv := newHTTPServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		mailer.SendCodes(auth.IssuedCode{Purpose: auth.PurposeSignup, To: "stopping@example.com",
			Tag: bytes.Repeat([]byte{7}, 32), Code: "123456", Send: true})
		w.WriteHeader(http.StatusNoContent)
	}))
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	go srv.Serve(ln)
	resp, err := http.Get("http://" + ln.Addr().String() + "/")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	select {
	case <-sender.started:
	case <-time.After(10 * time.Second):
		t.Fatal("the email never reached the sender")
	}

	ended := make(chan error, 1)
	go func() {
		ended <- finishServing(context.Background(), srv, &api.Server{Accounts: &auth.Accounts{Mail: mailer}})
	}()
	select {
	case err := <-ended:
		t.Fatalf("serving ended with the email still on its way: %v", err)
	case <-time.After(100 * time.Millisecond):
	}
	close(sender.release)
	select {
	case err := <-ended:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("serving did not end after the email was sent")
	}
	if n := len(sender.fake.Sent()); n != 1 {
		t.Fatalf("%d emails sent, want 1", n)
	}
}

func TestFinishingServingWithoutAccountsStillStopsTheListener(t *testing.T) {
	srv := newHTTPServer(http.NotFoundHandler())
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	served := make(chan error, 1)
	go func() { served <- srv.Serve(ln) }()
	if err := finishServing(context.Background(), srv, &api.Server{}); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-served:
		if err != http.ErrServerClosed {
			t.Fatalf("serve ended with %v", err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("the listener did not stop")
	}
}
