package gmailpush

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"strings"
	"testing"
)

// AT-GM-8 (the bytes): the address HMAC and the key id, recomputed here from
// spec 02 §13.3's definition with the standard library alone.
func TestRouteKeyBytes(t *testing.T) {
	raw := bytes.Repeat([]byte{0x42}, 32)
	rk, err := ParseRouteKey(hex.EncodeToString(raw) + "\n")
	if err != nil {
		t.Fatal(err)
	}
	want := func(addr string) []byte {
		m := hmac.New(sha256.New, raw)
		m.Write([]byte("hasala/v1/mailbox-route\x00gmail\x00" + addr))
		return m.Sum(nil)
	}
	for in, norm := range map[string]string{
		"User@Gmail.com":          "user@gmail.com",
		"  user@gmail.com ":       "user@gmail.com",
		"user.name+tag@gmail.com": "user.name+tag@gmail.com",
		"Ünï@Gmail.com":           "Ünï@gmail.com",
	} {
		if NormalizeAddress(in) != norm {
			t.Errorf("NormalizeAddress(%q) = %q, want %q", in, NormalizeAddress(in), norm)
		}
		if !bytes.Equal(rk.AddressHMAC(in), want(norm)) {
			t.Errorf("AddressHMAC(%q) differs from the definition", in)
		}
	}
	// The Gmail value is pinned to the bytes stored before Outlook existed, so
	// no existing link is orphaned; Outlook's is separated by its provider.
	const gmailVector = "61a572e6e3168bc9da3c4deac927ce5a40edb50ce0c38bf94c70603c7a471982"
	for _, got := range [][]byte{rk.AddressHMAC("User@Gmail.com"), rk.AddressHMACFor(ProviderGmail, "user@gmail.com")} {
		if hex.EncodeToString(got) != gmailVector {
			t.Errorf("the Gmail address HMAC is %x, want %s", got, gmailVector)
		}
	}
	outlook := hmac.New(sha256.New, raw)
	outlook.Write([]byte("hasala/v1/mailbox-route\x00outlook\x00user@outlook.com"))
	if !bytes.Equal(rk.AddressHMACFor(ProviderOutlook, " User@Outlook.com"), outlook.Sum(nil)) {
		t.Error("AddressHMACFor(outlook) differs from the definition")
	}
	if bytes.Equal(rk.SubjectHMACFor(ProviderOutlook, "user@outlook.com"), rk.AddressHMACFor(ProviderOutlook, "user@outlook.com")) ||
		bytes.Equal(rk.SubjectHMACFor(ProviderOutlook, "AbC"), rk.SubjectHMACFor(ProviderOutlook, "abc")) {
		t.Error("the subject key is not separated from the address key, or folds case")
	}
	if bytes.Equal(rk.AddressHMACFor(ProviderOutlook, "user@gmail.com"), rk.AddressHMAC("user@gmail.com")) {
		t.Error("one address under two providers gives one value")
	}
	m := hmac.New(sha256.New, raw)
	m.Write([]byte("hasala/v1/mailbox-route-key-id"))
	if !bytes.Equal(rk.KeyID(), m.Sum(nil)[:8]) {
		t.Fatal("KeyID differs from the definition")
	}
	for _, bad := range []string{"", strings.Repeat("0", 63), strings.Repeat("z", 64), hex.EncodeToString(raw) + "\n\n"} {
		if _, err := ParseRouteKey(bad); !errors.Is(err, ErrRouteKey) {
			t.Errorf("ParseRouteKey(%q) accepted", bad)
		}
	}
}

func TestParseEnvelope(t *testing.T) {
	sub := "projects/p/subscriptions/s"
	env := func(data, s string) []byte {
		return []byte(`{"message":{"data":"` + data + `","messageId":"1","attributes":{}},"subscription":"` + s + `","extra":1}`)
	}
	b64 := func(s string) string { return base64.StdEncoding.EncodeToString([]byte(s)) }
	n, err := ParseEnvelope(env(b64(`{"emailAddress":"a@gmail.com","historyId":"123"}`), sub), sub)
	if err != nil || n.EmailAddress != "a@gmail.com" {
		t.Fatalf("%+v %v", n, err)
	}
	if _, err := ParseEnvelope(env(b64(`{"emailAddress":"a@gmail.com","historyId":123}`), sub), sub); err != nil {
		t.Fatalf("numeric history id: %v", err)
	}
	if _, err := ParseEnvelope(env(b64(`{"emailAddress":"a@gmail.com","historyId":1}`), "other"), sub); !errors.Is(err, ErrForeignSubscription) {
		t.Fatalf("foreign subscription: %v", err)
	}
	for _, data := range []string{
		"!!!",
		b64(`{"historyId":"1"}`),
		b64(`{"emailAddress":"a@gmail.com"}`),
		b64(`{"emailAddress":"a@gmail.com","historyId":"-1"}`),
		b64(`{"emailAddress":"a@gmail.com","historyId":1.5}`),
		b64(`{"emailAddress":"a@gmail.com","historyId":"1","pad":"` + strings.Repeat("x", 1100) + `"}`),
	} {
		if _, err := ParseEnvelope(env(data, sub), sub); !errors.Is(err, ErrMalformed) {
			t.Errorf("data %.40q: %v, want malformed", data, err)
		}
	}
	if _, err := ParseEnvelope([]byte(`{"subscription":"`+sub+`"}`), sub); !errors.Is(err, ErrMalformed) {
		t.Fatal("an envelope without a message")
	}
}
