package pgtest

import (
	"bytes"
	"context"
	"io"
	"net"
	"sync/atomic"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"
)

func LosingCommitAnswers(t *testing.T, p *pgxpool.Pool) (*pgxpool.Pool, func()) {
	t.Helper()
	armed := &atomic.Bool{}
	cfg := p.Config()
	dial := cfg.ConnConfig.DialFunc
	cfg.ConnConfig.DialFunc = func(ctx context.Context, network, addr string) (net.Conn, error) {
		c, err := dial(ctx, network, addr)
		if err != nil {
			return nil, err
		}
		return &commitLosingConn{Conn: c, armed: armed}, nil
	}
	pool, err := pgxpool.NewWithConfig(context.Background(), cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	return pool, func() { armed.Store(true) }
}

type commitLosingConn struct {
	net.Conn
	armed *atomic.Bool
	lost  atomic.Bool
}

func (c *commitLosingConn) Write(b []byte) (int, error) {
	if isCommitMessage(b) && c.armed.CompareAndSwap(true, false) {
		c.lost.Store(true)
	}
	return c.Conn.Write(b)
}

func (c *commitLosingConn) Read(b []byte) (int, error) {
	if c.lost.Load() {
		return 0, io.ErrUnexpectedEOF
	}
	return c.Conn.Read(b)
}

func isCommitMessage(b []byte) bool {
	const header = 5
	return len(b) > header && b[0] == 'Q' && bytes.Equal(b[header:], []byte("commit\x00"))
}
