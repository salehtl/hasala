// Package keyproto holds the byte definitions the server shares with the
// device (spec 01 §3, §5.1, §5.5, §10.1–§10.3, §12.2): the domain-string
// registry, every signed-message builder, the step-up params hash and
// challenge, the account-creation challenge, the canonical BootstrapPayload,
// the wrap and phrase-box shape checks, the Ed25519 and P-256 key checks, the
// address normalization and the display-name floor.
//
// Nothing here holds or derives a data key. The server verifies signatures over
// these bytes and stores opaque wraps; it never opens a wrap, a phrase box or a
// frame (spec 02 §4.4 fence 3, spec 01 §12.2). The derivations that need the
// account master key or the phrase live in internal/cryptoref, which only the
// vector generator and tests import.
//
// Every builder writes exactly the bytes spec 01 §10.1 prints, and the anchor
// vectors of spec 01 §15.5 (A11–A26) pin them in this package's tests and in
// conformance/api-v1/, which the Swift client reads.
package keyproto

// Domain strings, spec 01 §3. One constant per registry row; the IDs are the
// spec's. Where a domain prefixes other fields it is followed by exactly one
// 0x00, written out in each builder; where it is the whole input (D08, D25,
// D35, D41) nothing is appended.
const (
	DomainRegister            = "hasala/v1/register"               // D01
	DomainStepUp              = "hasala/v1/step-up"                // D02
	DomainStepUpParams        = "hasala/v1/step-up-params"         // D03
	DomainRecoveryKey         = "hasala/v1/recovery-key"           // D04
	DomainWrapRecovery        = "hasala/v1/wrap/recovery"          // D05
	DomainWrapPRF             = "hasala/v1/wrap/prf"               // D06
	DomainWrap                = "hasala/v1/wrap"                   // D07
	DomainPRFSaltUnlock       = "hasala/v1/prf-salt/unlock"        // D08
	DomainAMKCommitment       = "hasala/v1/amk-commitment"         // D09
	DomainEpochKey            = "hasala/v1/epoch-key"              // D10
	DomainBlobKey             = "hasala/v1/blob-key"               // D11
	DomainBlob                = "hasala/v1/blob"                   // D12
	DomainWriterRegistration  = "hasala/v1/writer-registration"    // D13
	DomainWriterRevocation    = "hasala/v1/writer-revocation"      // D14
	DomainSessionBind         = "hasala/v1/session-bind"           // D15
	DomainAccountDelete       = "hasala/v1/account-delete"         // D16
	DomainBootstrap           = "hasala/v1/bootstrap"              // D17
	DomainRecoverySignin      = "hasala/v1/recovery-signin"        // D18
	DomainRecoveryRotate      = "hasala/v1/recovery-rotate"        // D19
	DomainEpochRotate         = "hasala/v1/epoch-rotate"           // D20
	DomainKeyringKey          = "hasala/v1/keyring-key"            // D21
	DomainKeyring             = "hasala/v1/keyring"                // D22
	DomainDeviceComparison    = "hasala/v1/device-comparison"      // D23
	DomainMailboxRoute        = "hasala/v1/mailbox-route"          // D24
	DomainMailboxRouteKeyID   = "hasala/v1/mailbox-route-key-id"   // D25
	DomainPassword            = "hasala/v1/password"               // D26
	DomainServerPasswordSalt  = "hasala/v1/server/password-salt"   // D27
	DomainServerPasswordPeppr = "hasala/v1/server/password-pepper" // D28
	DomainServerEmailCode     = "hasala/v1/server/email-code"      // D29
	DomainServerEmailTag      = "hasala/v1/server/email-tag"       // D30
	DomainStepUpDevice        = "hasala/v1/step-up-device"         // D31
	DomainWriterHead          = "hasala/v1/writer-head"            // D32
	DomainPasskeyAdd          = "hasala/v1/passkey-add"            // D33
	DomainWrapPut             = "hasala/v1/wrap-put"               // D34
	DomainPhraseBoxKey        = "hasala/v1/phrase-box-key"         // D35
	DomainPhraseBox           = "hasala/v1/phrase-box"             // D36
	DomainResetCode           = "hasala/v1/reset-code"             // D37
	DomainResetApprove        = "hasala/v1/reset-approve"          // D38
	DomainResetFinish         = "hasala/v1/reset-finish"           // D39
	DomainEmailChange         = "hasala/v1/email-change"           // D40
	DomainServerAuthKeyID     = "hasala/v1/server/auth-key-id"     // D41
	DomainDeviceFreeze        = "hasala/v1/device-freeze"          // D42
)

// Domain is one row of spec 01 §3's registry.
type Domain struct {
	ID     string `json:"id"`
	String string `json:"string"`
}

// Registry is spec 01 §3's first table, in ID order: 42 strings. The vector
// generator writes it into conformance/crypto-v3/manifest.json and both
// implementations assert their constants equal it (AT-X3). The non-crypto
// hasala/v1/* strings of the second table are not here, on purpose.
func Registry() []Domain {
	return []Domain{
		{"D01", DomainRegister},
		{"D02", DomainStepUp},
		{"D03", DomainStepUpParams},
		{"D04", DomainRecoveryKey},
		{"D05", DomainWrapRecovery},
		{"D06", DomainWrapPRF},
		{"D07", DomainWrap},
		{"D08", DomainPRFSaltUnlock},
		{"D09", DomainAMKCommitment},
		{"D10", DomainEpochKey},
		{"D11", DomainBlobKey},
		{"D12", DomainBlob},
		{"D13", DomainWriterRegistration},
		{"D14", DomainWriterRevocation},
		{"D15", DomainSessionBind},
		{"D16", DomainAccountDelete},
		{"D17", DomainBootstrap},
		{"D18", DomainRecoverySignin},
		{"D19", DomainRecoveryRotate},
		{"D20", DomainEpochRotate},
		{"D21", DomainKeyringKey},
		{"D22", DomainKeyring},
		{"D23", DomainDeviceComparison},
		{"D24", DomainMailboxRoute},
		{"D25", DomainMailboxRouteKeyID},
		{"D26", DomainPassword},
		{"D27", DomainServerPasswordSalt},
		{"D28", DomainServerPasswordPeppr},
		{"D29", DomainServerEmailCode},
		{"D30", DomainServerEmailTag},
		{"D31", DomainStepUpDevice},
		{"D32", DomainWriterHead},
		{"D33", DomainPasskeyAdd},
		{"D34", DomainWrapPut},
		{"D35", DomainPhraseBoxKey},
		{"D36", DomainPhraseBox},
		{"D37", DomainResetCode},
		{"D38", DomainResetApprove},
		{"D39", DomainResetFinish},
		{"D40", DomainEmailChange},
		{"D41", DomainServerAuthKeyID},
		{"D42", DomainDeviceFreeze},
	}
}
