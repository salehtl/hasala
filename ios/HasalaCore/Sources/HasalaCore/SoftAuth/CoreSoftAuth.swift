// CoreSoftAuth (SoftAuth/), spec 04 §2.2. Owner: WS-11. Holds the Swift port of
// server/internal/authtest/softauth.go (spec 04 §19.3) and a software ApprovalKeySigner.
//
// Filled so far: `SoftwareApprovalKey.swift` (the software DAK, landed with WS-9's
// signing messages). The softauth port is WS-11's. CryptoKit is imported here for
// `P256.Signing.PrivateKey` only (imports.allow); none of the AT-C11 calls appear.
