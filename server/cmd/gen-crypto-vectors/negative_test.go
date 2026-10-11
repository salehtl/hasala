package main

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/salehtl/hasala/server/internal/authtest"
	"github.com/salehtl/hasala/server/internal/keyproto"
)

// TestEverySignedMessageRefusesItsNegativeCases is spec 01 §15.3's
// "message and step-up cases", run over the committed
// conformance/api-v1/messages.json as a reader would see it: for every signed
// message, the committed signature verifies under the committed key, and
// flipping any byte of the message or the signature, a signature by another
// key, and (Ed25519) the identity point with the all-zero signature are all
// refused. P-256 also refuses r = 0 and s = 0.
func TestEverySignedMessageRefusesItsNegativeCases(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "conformance", "api-v1", "messages.json"))
	if err != nil {
		t.Fatal(err)
	}
	var file struct {
		Messages []struct {
			Name      string `json:"name"`
			Alg       string `json:"alg"`
			Bytes     string `json:"bytes"`
			Pubkey    string `json:"pubkey"`
			Signature string `json:"signature"`
		} `json:"messages"`
	}
	if err := json.Unmarshal(raw, &file); err != nil {
		t.Fatal(err)
	}
	dec := func(name, s string) []byte {
		b, err := hex.DecodeString(s)
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		return b
	}
	otherEd := func() []byte {
		_, priv, err := ed25519.GenerateKey(rand.Reader)
		if err != nil {
			t.Fatal(err)
		}
		return priv
	}
	otherDevice := authtest.NewDevice(t)
	identity := append([]byte{1}, make([]byte, 31)...)
	if keyproto.CheckEd25519PublicKey(identity) == nil {
		t.Fatal("the identity point passes the small-order check")
	}

	signed := map[string]int{}
	for _, m := range file.Messages {
		if m.Signature == "" {
			continue // C_reg is a challenge, not a signature
		}
		msg, pub, sig := dec(m.Name, m.Bytes), dec(m.Name, m.Pubkey), dec(m.Name, m.Signature)
		var verify func(pub, msg, sig []byte) bool
		var other func(msg []byte) (pub, sig []byte)
		switch m.Alg {
		case "ed25519":
			verify = keyproto.VerifyEd25519
			other = func(msg []byte) ([]byte, []byte) {
				k := otherEd()
				return k[32:], ed25519.Sign(ed25519.PrivateKey(k), msg)
			}
		case "p256":
			verify = keyproto.VerifyDAKBytes
			other = func(msg []byte) ([]byte, []byte) {
				return otherDevice.DAKPub(), otherDevice.SignDAK(t, msg)
			}
		default:
			t.Fatalf("%s: alg %q", m.Name, m.Alg)
		}
		signed[m.Alg]++
		if !verify(pub, msg, sig) {
			t.Fatalf("%s: the committed signature does not verify", m.Name)
		}
		for i := range msg {
			flipped := bytes.Clone(msg)
			flipped[i] ^= 0x01
			if verify(pub, flipped, sig) {
				t.Fatalf("%s: verifies with message byte %d flipped", m.Name, i)
			}
		}
		for i := range sig {
			flipped := bytes.Clone(sig)
			flipped[i] ^= 0x01
			if verify(pub, msg, flipped) {
				t.Fatalf("%s: verifies with signature byte %d flipped", m.Name, i)
			}
		}
		opub, osig := other(msg)
		if verify(pub, msg, osig) {
			t.Fatalf("%s: verifies a signature by another key", m.Name)
		}
		if !verify(opub, msg, osig) {
			t.Fatalf("%s: the control signature by another key does not verify under it", m.Name)
		}
		switch m.Alg {
		case "ed25519":
			if verify(identity, msg, make([]byte, ed25519.SignatureSize)) {
				t.Fatalf("%s: the identity point with a zero signature verifies", m.Name)
			}
		case "p256":
			zeroR := append(make([]byte, 32), sig[32:]...)
			zeroS := append(bytes.Clone(sig[:32]), make([]byte, 32)...)
			if verify(pub, msg, zeroR) || verify(pub, msg, zeroS) {
				t.Fatalf("%s: a DAK signature with r or s = 0 verifies", m.Name)
			}
		}
	}
	if signed["ed25519"] < 15 || signed["p256"] < 3 {
		t.Fatalf("checked %v signed messages; the file lost some", signed)
	}
}
