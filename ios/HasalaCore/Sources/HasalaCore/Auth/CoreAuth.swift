// CoreAuth (Auth/), spec 04 §2.2. Owner: WS-11. Holds WebAuthn options decoding,
// PublicKeyCredential JSON encoding, the ApprovalKeySigner protocol (spec 04 §2.7),
// step-up proof encoding and AuthClient over Transport.
//
// Filled so far: `ApprovalKeySigner.swift` (the DAK seam, landed with WS-9's
// signing messages). The rest is WS-11's.
