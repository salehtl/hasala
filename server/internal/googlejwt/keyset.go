package googlejwt

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"sync"
	"time"

	jose "github.com/go-jose/go-jose/v4"
)

// ---------------------------------------------------------------------------
// The key set: bounded staleness AND a bound on attacker-forced fetches
// ---------------------------------------------------------------------------

// maxJWKSBytes caps the published key document. Google's is ~1 KB.
const maxJWKSBytes = 256 << 10

// jwksFetchTimeout bounds one JWKS fetch, so an unresponsive provider cannot
// pin a request for however long the caller's context allows.
const jwksFetchTimeout = 10 * time.Second

// jwksRefresh is the minimum interval between JWKS fetch ATTEMPTS, and
// therefore the single number that governs every timing property here:
//
//   - a key the provider rotates IN starts working within this long,
//   - a key the provider rotates OUT (revoked, compromised) stops working
//     within this long,
//   - key material replaced under an unchanged kid likewise, and
//   - an unauthenticated caller can force at most ONE outbound request per
//     provider per this interval, no matter how many forged tokens they send.
//
// One minute makes the rotation lag indistinguishable from a retry while
// keeping the outbound rate trivial (1440 GETs/day/provider in the worst case,
// versus ~2 in the normal one).
const jwksRefresh = time.Minute

// jwksStaleMax is how long a key set we have failed to refresh may still be
// used. Serving stale keys through a provider outage is deliberate — failing
// closed would turn a Google blip into a total sign-in outage — but it is not
// unbounded, because "the JWKS is unreachable" must not keep a revoked key
// alive forever.
const jwksStaleMax = time.Hour

// cachingKeySet is the oidc.KeySet handed to go-oidc's IDTokenVerifier. It
// replaces oidc.NewRemoteKeySet, which could not be used here for a specific,
// measured reason.
//
// # Why not oidc.RemoteKeySet
//
// Two independent defects, both verified against v3.11.0's source and both
// reproduced with a test before this type was written:
//
//  1. Its cache never expires. cachedKeys is written only by keysFromRemote,
//     is never invalidated or timestamped, and the struct's `now` field is set
//     by the constructor and never read anywhere in the file. A key the
//     provider REVOKES therefore stays trusted for the life of the process.
//
//  2. Its refetch trigger is "verification failed", not "kid unknown". The
//     comment above the call says "if the kid doesn't match", but the code
//     falls through to keysFromRemote whenever no cached key VERIFIES — which
//     includes a valid kid with a bad signature. There is no negative caching
//     and no rate limit.
//
// Defect 2 is the dangerous one, and it is dangerous because every check an
// attacker must pass to reach it is public: `iss` and `alg` are fixed, `exp`
// is theirs to choose, and `aud` is the client ID that ships inside the mobile
// app. The kid is published in the JWKS itself. Measured before this change:
// 20 forged tokens signed with the attacker's own key but naming the
// provider's real kid produced 21 outbound JWKS fetches — an unauthenticated
// amplifier pointed at Apple's and Google's endpoints, whose success would get
// us rate limited there and take every sign-in down with it.
//
// # Why not a negative cache of missed kids
//
// The obvious patch — remember recently-failed kids and short-circuit them —
// is a trap. Its key is attacker-supplied, and a "miss" is indistinguishable
// from a bad signature under a REAL kid. An attacker forges garbage under the
// provider's live kid, poisons that entry, and every legitimate sign-in is
// short-circuited for the TTL: an amplification nuisance converted into a full
// authentication outage. There is no attacker-keyed state in this type at all,
// which is the property that makes that class of bug impossible rather than
// merely absent.
//
// # What this does instead
//
// It owns the refetch policy: the key set is refreshed on a clock, never in
// response to a token. A failed verification consults the cache and returns;
// it cannot cause I/O. That makes the outbound rate a function of time alone,
// and makes every rotation property fall out of one constant (jwksRefresh).
//
// # What is still go-oidc's, and still go-jose's
//
// All of the cryptography. This type fetches a document, unmarshals it with
// go-jose's own jose.JSONWebKeySet, selects candidates by kid, and calls
// go-jose's jws.Verify. It parses no key material by hand and implements no
// algorithm. go-oidc's IDTokenVerifier remains the authority for the
// algorithm allow-list, `iss`, `exp` and `nbf`, and go-oidc ships this exact
// selection-and-verify loop itself as StaticKeySet — implementing oidc.KeySet
// is the library's supported extension point, not a way around it.
type cachingKeySet struct {
	jwksURL  string
	refresh  time.Duration
	staleMax time.Duration
	now      func() time.Time

	mu          sync.Mutex
	inflight    *inflightFetch // non-nil while a fetch is in progress
	keys        []jose.JSONWebKey
	fetchedAt   time.Time // last SUCCESSFUL fetch
	attemptedAt time.Time // last attempt that reached the provider
}

// keySetAlgs is the third and innermost enforcement of the signing-algorithm
// allow-list: checkHeader rejects first, go-oidc's SupportedSigningAlgs
// rejects second, and this ParseSigned call would reject an "alg" that somehow
// reached here regardless.
var keySetAlgs = []jose.SignatureAlgorithm{jose.RS256}

func (r *cachingKeySet) VerifySignature(ctx context.Context, jwt string) ([]byte, error) {
	jws, err := jose.ParseSigned(jwt, keySetAlgs)
	if err != nil {
		return nil, fmt.Errorf("parse jws: %w", err)
	}
	if len(jws.Signatures) != 1 {
		return nil, fmt.Errorf("id token carries %d signatures, want exactly 1", len(jws.Signatures))
	}
	kid := jws.Signatures[0].Header.KeyID

	keys, err := r.currentKeys(ctx)
	if err != nil {
		return nil, err
	}
	for i := range keys {
		key := keys[i]
		// A key published for encryption must never verify a signature. Both
		// providers mark their keys "sig"; an unset Use is permitted by
		// RFC 7517 and is not treated as disqualifying.
		if key.Use != "" && key.Use != "sig" {
			continue
		}
		// A token naming a kid is verified against THAT key only, so a
		// signature cannot be laundered through some other published key. A
		// token with no kid is checked against all of them (RFC 7515 permits
		// it; neither provider emits it).
		if kid != "" && key.KeyID != kid {
			continue
		}
		if payload, err := jws.Verify(&key); err == nil {
			return payload, nil
		}
	}
	// Deliberately no refetch here. This is the line that used to be an
	// unauthenticated outbound request; see the type doc.
	return nil, fmt.Errorf("no key published at %s verifies this token (kid %q)", r.jwksURL, kid)
}

// currentKeys returns the key set, refreshing it at most once per r.refresh.
// It serves a stale set through a provider outage, but only up to r.staleMax.
// currentKeys returns the key set, refreshing it at most once per r.refresh.
// It serves a stale set through a provider outage, but only up to r.staleMax.
//
// # The fetch is detached from the caller, deliberately
//
// A JWKS fetch is shared infrastructure: every concurrent sign-in is waiting on
// the same one. Running it on the requesting caller's context — which an
// earlier version of this function did — means one caller's cancellation
// aborts a fetch everyone else depends on, and net/http cancels a request's
// context the moment the client disconnects.
//
// That was an unauthenticated denial of the entire auth front door, and a
// silent one. On a cold process (every deploy, every restart) an attacker
// sends ONE forged token that satisfies only public inputs — `iss` and `alg`
// are fixed, `exp` is theirs, `aud` is the client ID that ships inside the
// mobile app, `typ` is "JWT" — so it reaches VerifySignature, and then aborts
// the connection. The attempt slot was consumed, the fetch died on
// context.Canceled, nothing was cached, and every genuine sign-in failed for
// the next refresh window. Zero outbound requests, so the provider saw nothing
// and there was no external evidence at all. Cost: one aborted TCP connection
// per minute, forever.
//
// go-oidc protects this property on purpose — newRemoteKeySet stores
// context.WithoutCancel(ctx) and fetches on THAT, so only the *wait* is
// cancellable — and this function had noted as much in a previous revision
// before losing it in a rewrite. Hence, in order:
//
//   - the fetch runs in its own goroutine on context.WithoutCancel, so it
//     survives the departure of whichever caller happened to trigger it while
//     still inheriting that caller's context VALUES,
//   - waiting callers select on their own ctx.Done(), so a caller keeps its
//     own deadline instead of inheriting the fetch's,
//   - the attempt slot is consumed only by an attempt that actually reached
//     the provider, never by a cancellation (belt: the primary fix already
//     makes caller cancellation unreachable here).
//
// The inflight handoff also gives herd control for free: N concurrent callers
// arriving on a cold cache produce ONE request, not N.
func (r *cachingKeySet) currentKeys(ctx context.Context) ([]jose.JSONWebKey, error) {
	if keys, ok := r.freshKeys(); ok {
		return keys, nil
	}

	r.mu.Lock()
	if r.inflight == nil {
		// Rate-limit ATTEMPTS, not just successes: without this a provider
		// that is down would be hammered once per inbound request, which is
		// the same amplification bug in a different costume.
		if !r.attemptedAt.IsZero() && r.now().Sub(r.attemptedAt) < r.refresh {
			r.mu.Unlock()
			return r.staleKeys()
		}
		fl := &inflightFetch{done: make(chan struct{})}
		r.inflight = fl
		go r.fetch(context.WithoutCancel(ctx), fl)
	}
	fl := r.inflight
	r.mu.Unlock()

	select {
	case <-ctx.Done():
		// This caller gave up; the fetch continues for everyone else.
		return nil, ctx.Err()
	case <-fl.done:
	}
	if fl.err != nil {
		return r.staleKeys()
	}
	return fl.keys, nil
}

// inflightFetch lets several callers wait on one fetch. keys/err are written
// before done is closed, which is the happens-before edge that makes reading
// them after the receive safe.
type inflightFetch struct {
	done chan struct{}
	keys []jose.JSONWebKey
	err  error
}

// fetch performs one JWKS retrieval and publishes it. ctx is already detached
// from any caller (see currentKeys); the only cancellation it carries is the
// timeout applied here.
func (r *cachingKeySet) fetch(ctx context.Context, fl *inflightFetch) {
	fetchCtx, cancel := context.WithTimeout(ctx, jwksFetchTimeout)
	defer cancel()
	keys, err := fetchJWKS(fetchCtx, r.jwksURL)
	fl.keys, fl.err = keys, err

	now := r.now()
	r.mu.Lock()
	switch {
	case err == nil:
		r.keys, r.fetchedAt, r.attemptedAt = keys, now, now
	case errors.Is(err, context.Canceled):
		// Something aborted us rather than the provider failing. The primary
		// fix makes this unreachable from a caller disconnect; not consuming
		// the slot means that even if a future change reconnects the two, an
		// aborted request cannot deny the next one its attempt.
	default:
		// A real failure — refused, 5xx, unparseable, or our own timeout.
		// Consume the slot so a down provider is not hammered.
		r.attemptedAt = now
	}
	r.inflight = nil
	r.mu.Unlock()
	close(fl.done)
}

func (r *cachingKeySet) freshKeys() ([]jose.JSONWebKey, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.keys == nil {
		return nil, false
	}
	return r.keys, r.now().Sub(r.fetchedAt) < r.refresh
}

// staleKeys is the outage path: a key set we could not refresh is still used,
// because failing closed would turn a provider blip into a total sign-in
// outage — but only up to staleMax, because "the JWKS is unreachable" must not
// keep a revoked key alive indefinitely.
func (r *cachingKeySet) staleKeys() ([]jose.JSONWebKey, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.keys == nil {
		return nil, fmt.Errorf("jwks %s is unavailable and nothing is cached", r.jwksURL)
	}
	if age := r.now().Sub(r.fetchedAt); age >= r.staleMax {
		return nil, fmt.Errorf("jwks %s could not be refreshed for %s, which exceeds the %s limit",
			r.jwksURL, age, r.staleMax)
	}
	return r.keys, nil
}

// fetchJWKS retrieves and unmarshals the published key set. Unmarshalling is
// go-jose's own, so no key material is parsed by hand here.
func fetchJWKS(ctx context.Context, url string) ([]jose.JSONWebKey, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("jwks %s: %s", url, resp.Status)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, maxJWKSBytes))
	if err != nil {
		return nil, fmt.Errorf("jwks %s: %w", url, err)
	}
	var set jose.JSONWebKeySet
	if err := json.Unmarshal(body, &set); err != nil {
		return nil, fmt.Errorf("jwks %s: %w", url, err)
	}
	if len(set.Keys) == 0 {
		// An empty document must not be cached as "the provider publishes
		// nothing", which would reject every token for a full refresh window.
		return nil, fmt.Errorf("jwks %s: no keys", url)
	}
	return set.Keys, nil
}
