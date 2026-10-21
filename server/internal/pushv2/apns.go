package pushv2

// apns.go is the APNs transport (spec 02 §12.2, §12.3): token-based auth with
// the team's .p8 key, one HTTP/2 client, the pinned header set and the pinned
// 31-byte body, chosen per token between the production and sandbox gateways.
//
// # Signing
//
// The provider token is an ES256 JWT. It is signed through the key's
// crypto.Signer method, never through the package functions ecdsa.Sign or
// ecdsa.SignASN1 (spec 02 §4.4 fence 3(d) refuses those by name); the
// DER signature is re-encoded as the raw r ‖ s JWS wants. This is the only
// signature the server makes with an EC key, and what it signs is the team id
// and a timestamp — never user data.

import (
	"bytes"
	"context"
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/asn1"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"strconv"
	"sync"
	"time"
)

// Payload is the one body every wake carries, whatever its reason (spec 02
// §12.2): a background push with no alert, no badge, no sound and no content.
const Payload = `{"aps":{"content-available":1}}`

// Gateways (spec 02 §12.2), chosen per token from apns_tokens.environment.
const (
	ProductionHost = "https://api.push.apple.com"
	SandboxHost    = "https://api.sandbox.push.apple.com"
)

// Environments a token may carry.
const (
	EnvProduction = "production"
	EnvSandbox    = "sandbox"
)

// JWT lifetimes (spec 02 §12.2): Apple refuses a token older than an hour and
// throttles one regenerated more often than every 20 minutes.
const (
	jwtMaxAge         = 40 * time.Minute
	jwtRegenerateFrom = 20 * time.Minute
	sendTimeout       = 10 * time.Second
	expirationWindow  = time.Hour
)

// Result classifies one send for the dispatcher (spec 02 §12.3).
type Result uint8

const (
	// ResultSent is a 200.
	ResultSent Result = iota + 1
	// ResultGone is 400 BadDeviceToken / DeviceTokenNotForTopic or 410
	// Unregistered: the token row is deleted, the device re-registers.
	ResultGone
	// ResultCooldown is a 429: the token rests 60 s.
	ResultCooldown
	// ResultConfig is a 403 that no retry fixes (bad key, topic): sending
	// stops for 5 minutes and an ERROR is logged.
	ResultConfig
	ResultEnvironment
	// ResultTransient is a 5xx, a network error or anything unexpected: no
	// retry, the app catches up on open.
	ResultTransient
)

func (r Result) String() string {
	switch r {
	case ResultSent:
		return "sent"
	case ResultGone:
		return "gone"
	case ResultCooldown:
		return "cooldown"
	case ResultConfig:
		return "config"
	case ResultEnvironment:
		return "environment"
	case ResultTransient:
		return "transient"
	}
	return "unknown"
}

// ErrKeyType is a .p8 that is not a PKCS#8 EC P-256 private key.
var ErrKeyType = errors.New("pushv2: the APNs key must be a PKCS#8 PEM EC P-256 private key")

// ParseP8 reads an App Store Connect .p8 (PKCS#8 PEM, EC P-256) and refuses any
// other key type (spec 02 §12.2: refuse at startup).
func ParseP8(pemBytes []byte) (*ecdsa.PrivateKey, error) {
	block, rest := pem.Decode(pemBytes)
	if block == nil || block.Type != "PRIVATE KEY" || len(bytes.TrimSpace(rest)) != 0 {
		return nil, ErrKeyType
	}
	k, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, ErrKeyType
	}
	ec, ok := k.(*ecdsa.PrivateKey)
	if !ok || ec.Curve != elliptic.P256() {
		return nil, ErrKeyType
	}
	return ec, nil
}

// Client sends wakes to APNs. Build it with NewClient.
type Client struct {
	teamID, keyID, topic string
	key                  *ecdsa.PrivateKey
	http                 *http.Client
	hosts                map[string]string
	now                  func() time.Time

	mu       sync.Mutex
	jwt      string
	jwtIssue time.Time
}

// ClientConfig configures NewClient. HTTP and Hosts exist for tests (a fake
// APNs over TLS); production leaves both nil.
type ClientConfig struct {
	TeamID, KeyID, Topic string
	Key                  *ecdsa.PrivateKey
	HTTP                 *http.Client
	Hosts                map[string]string // environment → base URL
	Now                  func() time.Time
}

// NewClient validates cfg and builds the one client (spec 02 §12.2: net/http,
// h2 negotiated, timeout 10 s, 4 idle connections per host).
func NewClient(cfg ClientConfig) (*Client, error) {
	if cfg.Key == nil || cfg.Key.Curve != elliptic.P256() {
		return nil, ErrKeyType
	}
	if cfg.TeamID == "" || cfg.KeyID == "" || cfg.Topic == "" {
		return nil, errors.New("pushv2: APNs team id, key id and topic are required")
	}
	c := &Client{teamID: cfg.TeamID, keyID: cfg.KeyID, topic: cfg.Topic, key: cfg.Key, http: cfg.HTTP,
		hosts: cfg.Hosts, now: cfg.Now}
	if c.now == nil {
		c.now = time.Now
	}
	if c.http == nil {
		c.http = &http.Client{
			Timeout: sendTimeout,
			Transport: &http.Transport{
				ForceAttemptHTTP2:   true,
				MaxIdleConnsPerHost: 4,
				// No Accept-Encoding: the header set is pinned (spec 02 §12.2).
				DisableCompression: true,
			},
			// APNs never redirects; a redirect is not followed with the token.
			CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
		}
	}
	if c.hosts == nil {
		c.hosts = map[string]string{EnvProduction: ProductionHost, EnvSandbox: SandboxHost}
	}
	return c, nil
}

// providerToken returns the cached JWT, regenerating it when it is older than
// 40 minutes, or (force) when Apple called it expired and it is older than 20.
func (c *Client) providerToken(force bool) (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	now := c.now()
	age := now.Sub(c.jwtIssue)
	if c.jwt != "" && age < jwtMaxAge && !(force && age >= jwtRegenerateFrom) {
		return c.jwt, nil
	}
	tok, err := SignJWT(c.key, c.keyID, c.teamID, now)
	if err != nil {
		return "", err
	}
	c.jwt, c.jwtIssue = tok, now
	return tok, nil
}

// SignJWT is the APNs provider token: header {"alg":"ES256","kid":<kid>},
// claims {"iss":<team>,"iat":<unix>}, ES256 over the signing input, raw r ‖ s.
func SignJWT(key *ecdsa.PrivateKey, kid, team string, iat time.Time) (string, error) {
	hdr, _ := json.Marshal(struct {
		Alg string `json:"alg"`
		Kid string `json:"kid"`
	}{"ES256", kid})
	claims, _ := json.Marshal(struct {
		Iss string `json:"iss"`
		Iat int64  `json:"iat"`
	}{team, iat.Unix()})
	enc := base64.RawURLEncoding
	input := enc.EncodeToString(hdr) + "." + enc.EncodeToString(claims)
	digest := sha256.Sum256([]byte(input))
	der, err := crypto.Signer(key).Sign(rand.Reader, digest[:], crypto.SHA256)
	if err != nil {
		return "", fmt.Errorf("pushv2: sign provider token: %w", err)
	}
	var sig struct{ R, S *big.Int }
	if rest, err := asn1.Unmarshal(der, &sig); err != nil || len(rest) != 0 {
		return "", errors.New("pushv2: provider token signature is not DER")
	}
	raw := make([]byte, 64)
	sig.R.FillBytes(raw[:32])
	sig.S.FillBytes(raw[32:])
	return input + "." + enc.EncodeToString(raw), nil
}

// Send delivers the payload to one token and classifies the answer. It retries
// exactly once, on 403 ExpiredProviderToken, with a regenerated JWT.
func (c *Client) Send(ctx context.Context, t Target) Result {
	r, reason := c.send(ctx, t, false)
	if reason == "ExpiredProviderToken" {
		r, _ = c.send(ctx, t, true)
	}
	return r
}

func (c *Client) send(ctx context.Context, t Target, forceJWT bool) (Result, string) {
	base, ok := c.hosts[t.Environment]
	if !ok || !validTokenHex(t.TokenHex) {
		return ResultGone, "BadDeviceToken"
	}
	jwt, err := c.providerToken(forceJWT)
	if err != nil {
		return ResultConfig, "sign"
	}
	ctx, cancel := context.WithTimeout(ctx, sendTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, base+"/3/device/"+t.TokenHex,
		bytes.NewReader([]byte(Payload)))
	if err != nil {
		return ResultTransient, ""
	}
	// The pinned set, nothing else (spec 02 §12.2). Go adds Content-Length
	// itself; the User-Agent is suppressed with an explicit empty value.
	h := req.Header
	h["User-Agent"] = []string{""}
	h.Set("authorization", "bearer "+jwt)
	h.Set("apns-topic", c.topic)
	h.Set("apns-push-type", "background")
	h.Set("apns-priority", "5")
	h.Set("apns-expiration", strconv.FormatInt(c.now().Add(expirationWindow).Unix(), 10))
	h.Set("content-type", "application/json")
	resp, err := c.http.Do(req)
	if err != nil {
		return ResultTransient, ""
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	var apnsErr struct {
		Reason string `json:"reason"`
	}
	_ = json.Unmarshal(body, &apnsErr)
	return classify(resp.StatusCode, apnsErr.Reason), apnsErr.Reason
}

// classify is spec 02 §12.3's table.
func classify(status int, reason string) Result {
	switch {
	case status == http.StatusOK:
		return ResultSent
	case status == http.StatusGone,
		status == http.StatusBadRequest && (reason == "BadDeviceToken" || reason == "DeviceTokenNotForTopic"):
		return ResultGone
	case status == http.StatusTooManyRequests:
		return ResultCooldown
	case status == http.StatusForbidden && (reason == "BadEnvironmentKeyIdInToken" || reason == "BadEnvironmentKeyInToken" ||
		reason == "BadCertificateEnvironment"):
		return ResultEnvironment
	case status == http.StatusForbidden && reason != "ExpiredProviderToken":
		return ResultConfig
	}
	return ResultTransient
}

// validTokenHex is apns_tokens_token_is_hex: 32 to 100 lowercase hex bytes.
func validTokenHex(s string) bool {
	if len(s) < 64 || len(s) > 200 || len(s)%2 != 0 {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

// ValidTokenHex reports whether s is a token the API accepts.
func ValidTokenHex(s string) bool { return validTokenHex(s) }
