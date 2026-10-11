// CoreSoftAuth (SoftAuth/), spec 04 §2.2. Owner: WS-11. Test support only; never linked by the app.
//
//   SoftwareApprovalKey.swift  a software DAK with the Secure Enclave key's byte formats
//   SoftPasskey.swift          a software platform passkey (ES256, `none` attestation, UV, the
//                              deterministic PRF of 01 §12.1) and the CBOR it writes
//
// CryptoKit is imported for P-256 signing, SHA-256 and HMAC (imports.allow); none of the
// AT-C11 calls (AES.GCM, HKDF, Curve25519.Signing, SecRandomCopyBytes) appear here.
