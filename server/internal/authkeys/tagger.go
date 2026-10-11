package authkeys

import "github.com/salehtl/hasala/server/internal/keyproto"

// EmailTagger computes email_tag = HMAC(K_tag, email_norm) from the current
// auth_key alone (spec 01 §4.11). It is what the waitlist and the email queue
// need from the key file, without the password salt key the full Keys set
// requires; both derive K_tag identically, so the tags agree.
type EmailTagger struct{ kTag []byte }

// NewEmailTagger derives K_tag from a 32-byte auth_key.
func NewEmailTagger(authKey []byte) (*EmailTagger, error) {
	if len(authKey) != KeySize {
		return nil, ErrKeyFile
	}
	k, err := subkey(authKey, keyproto.DomainServerEmailTag)
	if err != nil {
		return nil, err
	}
	return &EmailTagger{kTag: k}, nil
}

// EmailTag is HMAC(K_tag, utf8(email_norm)).
func (t *EmailTagger) EmailTag(emailNorm string) []byte { return mac(t.kTag, []byte(emailNorm)) }
