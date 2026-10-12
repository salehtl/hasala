# Export compliance: the encryption answer for App Store Connect

**Status: DRAFT, waiting for the owner's sign-off.** This is a legal self-classification,
not an engineering decision. Engineering drafted the facts below; the owner (ideally with
counsel) decides and signs. Until then the build ships with the default answer in this
file, so no TestFlight build waits in "Missing Compliance".

## Proposed answer

- `ITSAppUsesNonExemptEncryption = NO` in `ios/Hasala/Info.plist`.
- Basis: the app uses only the encryption built into Apple's operating system, and its
  primary function is personal budgeting, not information security.

With the key present, App Store Connect does not ask the encryption questions for each
build.

## Facts the answer rests on

1. **Every cryptographic operation runs on Apple's own implementations.** The app calls:
   - CryptoKit: AES-256-GCM (the op log and keys at rest), HKDF-SHA256 (key derivation),
     SHA-256 and HMAC-SHA256 (hashing and integrity), Ed25519 (signing writes and batch
     heads).
   - The Secure Enclave, through CryptoKit's `SecureEnclave.P256`: the per-device approval
     key (P-256 ECDSA), which never leaves the iPhone.
   - CommonCrypto's PBKDF2-HMAC-SHA256 (`CCKeyDerivationPBKDF`), which stretches a password
     on the device before anything derived from it is sent.
   - The Security framework (the Keychain and `SecRandomCopyBytes`), AuthenticationServices
     (passkeys), and URLSession's TLS for every network call.
2. **No other cryptography ships in the app.** The third-party code in the binary is GRDB
   (database access over the system SQLite, without its encryption extensions) and
   swift-collections (data structures). The predecessor's only third-party cryptography,
   Argon2, was removed from the design. The app's use of the system zlib is compression,
   not encryption.
3. **No proprietary or non-standard algorithms.** Every primitive above is a published
   standard used as published.
4. **What the encryption is for.** It keeps the user's own budget, transactions and keys
   private: the phone encrypts data before it reaches Hasala's server, and the server
   cannot read it. The app's primary function is budgeting. It is not a security product,
   a messaging or communications tool, or a storage service for other content.
5. **Distribution.** TestFlight today, the App Store later, in every territory unless the
   owner restricts it.

The server's cryptography (Go's standard library) is not part of the distributed app and
does not enter this answer.

## How the build is held to this answer

- `ios/scripts/archive.sh` carries the answer as `NON_EXEMPT_ENCRYPTION=false`, and
  `ios/scripts/inspect-ipa.sh` check I4 refuses an exported `.ipa` whose Info.plist
  disagrees. `ios/HasalaTests/BuildInfoTests.swift` checks the app's own Info.plist too.
  The three change together.
- `inspect-ipa.sh` check I9 (spec check AT-11) refuses an `.ipa` in which any Mach-O
  exports or imports a symbol of a third-party crypto library (Argon2, libsodium, OpenSSL
  or BoringSSL, mbedTLS, wolfSSL, scrypt, bcrypt). Such a symbol would contradict fact 1
  and reopen this decision. The check reads symbol tables, so it sees what a binary
  exports or imports, not code linked in statically and stripped; the dependency rule
  below covers that.
- Adding any dependency that ships cryptography reopens this decision before it merges.

## If the answer becomes YES

If the owner or counsel concludes that the end-to-end encryption is not exempt:

1. Set `ITSAppUsesNonExemptEncryption` to `YES` in `ios/Hasala/Info.plist` and
   `NON_EXEMPT_ENCRYPTION=true` in `ios/scripts/archive.sh`, and update `BuildInfoTests`.
2. In App Store Connect › App Information › App Encryption Documentation, answer that the
   app uses encryption, and choose the option for encryption that is only within Apple's
   operating system (fact 1), unless a non-Apple crypto library has been added since.
3. Answer "No" to distribution on the App Store in France unless French distribution is
   intended (that needs a separate declaration).
4. If App Store Connect issues a compliance code, add it to Info.plist as
   `ITSEncryptionExportComplianceCode`.
5. Record the exact questions and answers below, with the date: the questionnaire's
   wording changes over time.

## Sign-off

| | |
| --- | --- |
| Decision | `ITSAppUsesNonExemptEncryption = NO` (proposed) |
| Decided by | _the owner_ |
| Reviewed with counsel | _yes / no_ |
| Date | _YYYY-MM-DD_ |
| App Store Connect answers recorded | _n/a while the key is NO_ |
