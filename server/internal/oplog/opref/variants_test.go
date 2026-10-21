package opref

import (
	"encoding/base64"
	"errors"
	"reflect"
	"strconv"
	"strings"
	"testing"
)

type setAsideBlob struct {
	Name       string `json:"name"`
	Kind       string `json:"kind"`
	BodyBase64 string `json:"body_base64"`
}

type acceptedVariant struct {
	Name       string     `json:"name"`
	BodyBase64 string     `json:"body_base64"`
	ExpectOps  []opExpect `json:"expect_ops"`
}

const (
	variantConfigFields = `"v":3,"authored_at":"2026-06-05T10:00:00Z","payload":{"bank":"dib","active":true}`
	variantIngestFields = `"v":2,"type":"txn_ingested","op_id":"01J000000000000000000000O1","authored_at":"2026-06-05T10:00:00Z","parent_version":null`
	variantHex          = `"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"`
	variantPayload      = `"amount_minor":"1","currency":"AED","direction":"debit","posted_at":"2026-06-05T10:00:00Z","last4":"","needs_review":false,"unparsed":false,"tier":"template"`
)

func variantBlob(ops ...string) string {
	return `{"v":3,"kind":"ops","ops":[` + strings.Join(ops, ",") + `]}`
}

func variantIngest(entity, ingestID, merchant string) string {
	return `{` + variantIngestFields + `,"entity":` + entity + `,"ingest_id":` + ingestID +
		`,"payload":{` + variantPayload + `,"merchant_raw":"` + merchant + `"}}`
}

func setAsideCases() []setAsideBlob {
	entity := `{"kind":"txn","id":"T2"}`
	cases := []struct{ name, kind, body string }{
		{"ingest-id-null-on-a-config-op", KindOps,
			variantBlob(`{"type":"bank_declared","op_id":"01J000000000000000000000B1",` + variantConfigFields + `,"ingest_id":null}`)},
		{"ingest-id-null-on-an-ingest", KindOps, variantBlob(variantIngest(entity, "null", "BANK"))},
		{"type-key-in-another-case", KindOps,
			variantBlob(`{"Type":"bank_declared","op_id":"01J000000000000000000000B1",` + variantConfigFields + `}`)},
		{"op-id-key-in-another-case", KindOps,
			variantBlob(`{"type":"bank_declared","OP_ID":"01J000000000000000000000B1",` + variantConfigFields + `}`)},
		{"entity-key-in-another-case", KindOps, variantBlob(variantIngest(`{"Kind":"txn","id":"T2"}`, variantHex, "BANK"))},
		{"lone-high-surrogate-in-a-payload-value", KindOps, variantBlob(variantIngest(entity, variantHex, `CAF\ud800`))},
		{"lone-low-surrogate-in-a-payload-value", KindOps, variantBlob(variantIngest(entity, variantHex, `\udc00CAFE`))},
		{"high-surrogate-before-a-non-low-escape", KindOps, variantBlob(variantIngest(entity, variantHex, `\ud83dA`))},
		{"lone-surrogate-in-a-payload-key", KindOps,
			variantBlob(`{"type":"bank_declared","op_id":"01J000000000000000000000B1","v":3,"authored_at":"2026-06-05T10:00:00Z","payload":{"bank":"dib","active":true,"\udbff":1}}`)},
		{"lone-surrogate-in-an-unread-raw-body-field", KindRawBody,
			`{"v":1,"kind":"raw_body","ingest_id":` + variantHex + `,"received_at":"2026-06-05T10:00:00Z","raw_base64":"aGk=","note":"\udfff"}`},
		{"raw-body-ingest-id-key-in-another-case", KindRawBody,
			`{"v":1,"kind":"raw_body","INGEST_ID":` + variantHex + `,"received_at":"2026-06-05T10:00:00Z","raw_base64":"aGk="}`},
	}
	out := make([]setAsideBlob, 0, len(cases))
	for _, c := range cases {
		out = append(out, setAsideBlob{Name: c.name, Kind: c.kind, BodyBase64: base64.StdEncoding.EncodeToString([]byte(c.body))})
	}
	return out
}

func acceptedVariantBodies() []struct{ name, body string } {
	config := `{"type":"bank_declared","op_id":"01J000000000000000000000B1",` + variantConfigFields
	return []struct{ name, body string }{
		{"ops-key-in-another-case-is-zero-ops", `{"v":3,"kind":"ops","OPS":[` + config + `}]}`},
		{"case-variant-keys-are-ignored",
			variantBlob(config + `,"TYPE":"rate_set","Op_Id":"01J000000000000000000000B9","INGEST_ID":` + variantHex + `}`)},
		{"surrogate-pair-escape-is-read", variantBlob(variantIngest(`{"kind":"txn","id":"T2"}`, variantHex, `CAF😀`))},
	}
}

func expectOf(o Op) opExpect {
	e := opExpect{
		Type:             string(o.Type),
		OpID:             o.OpID,
		AuthoredAtUnixMs: strconv.FormatInt(o.AuthoredAt.UnixMilli(), 10),
		HasEntity:        o.Entity != nil,
		IngestID:         o.IngestID,
	}
	if o.ParentVersion != nil {
		s := strconv.FormatInt(*o.ParentVersion, 10)
		e.ParentVersion = &s
	}
	return e
}

func decodeByKind(kind string, b []byte) error {
	if kind == KindRawBody {
		_, err := DecodeRawBody(b)
		return err
	}
	_, err := DecodeBlob(b)
	return err
}

func wireVariants(t *testing.T) ([]setAsideBlob, []acceptedVariant) {
	t.Helper()
	setAside := setAsideCases()
	for _, c := range setAside {
		b, _ := base64.StdEncoding.DecodeString(c.BodyBase64)
		if err := decodeByKind(c.Kind, b); err == nil {
			t.Fatalf("set-aside case %s must be refused before it is written", c.Name)
		}
	}
	var accepted []acceptedVariant
	for _, c := range acceptedVariantBodies() {
		ops, err := DecodeBlob([]byte(c.body))
		if err != nil {
			t.Fatalf("accepted variant %s: %v", c.name, err)
		}
		v := acceptedVariant{Name: c.name, BodyBase64: base64.StdEncoding.EncodeToString([]byte(c.body)), ExpectOps: []opExpect{}}
		for _, o := range ops {
			v.ExpectOps = append(v.ExpectOps, expectOf(o))
		}
		accepted = append(accepted, v)
	}
	return setAside, accepted
}

func TestOpManifestWireVariants(t *testing.T) {
	man := readOpManifest(t)
	setAside, accepted := wireVariants(t)
	if !reflect.DeepEqual(man.SetAsideBlobs, setAside) || !reflect.DeepEqual(man.AcceptedVariants, accepted) {
		t.Fatalf("set_aside_blobs or accepted_variants differ from this build's; regenerate with %s=1", writeFixturesEnv)
	}
	for _, c := range man.SetAsideBlobs {
		b, err := base64.StdEncoding.DecodeString(c.BodyBase64)
		if err != nil {
			t.Fatal(err)
		}
		if err := decodeByKind(c.Kind, b); errors.Is(err, ErrUnknownNewerVersion) {
			t.Errorf("%s: hard-stopped where the body must be set aside: %v", c.Name, err)
		}
	}
}
