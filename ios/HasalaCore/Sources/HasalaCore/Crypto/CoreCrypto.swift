// CoreCrypto (Crypto/), spec 04 §2.2. Owner: WS-9. Spec 01 §12.1:
//
//   Domains.swift          the D01-D43 registry (§3)
//   BIP39English.swift     the generated wordlist; Phrase.swift: entropy ↔ words (§4.3)
//   KeyDerivation.swift    RK, RWK, PWK, amk_commit, K_1, K_blob, K_pv, PRF_SALT (§4)
//   Wraps.swift            KeyBody, the recovery and PRF wraps, the phrase box, AccountUnlock (§4.5, §5)
//   Sealer.swift           Sealer, SealedFrame, FrameAEAD, Opener (R3-R9) (§6)
//   LooksSealed.swift      the plaintext-refusal predicate (§8.1)
//   SigningMessages.swift  every §10.1 message and C_reg (D01)
//   StepUp.swift           params, challenge, the 20 actions and their proof kinds (§10.2)
//   BootstrapPayload.swift the canonical payload (§10.3.1)
//   Accounts.swift         EmailNorm, NameOK, DisplayName (§4.11)
//   Password.swift         PasswordStretch, PasswordPolicy, ResetCode (§4.10, D37)
//   DeviceKeys.swift       DWK, DAK checks, HeadCheck (R2b; §12.1 places it in CoreWire, see
//                          Wire/CoreWire.swift for why it is here)
//   KeyHistoryVerifier.swift  the verified roster from GET /key-history, and the GET /writers
//                          comparison (§10.13)
//   PageReader.swift       the §6.6 reader composed, R0-R10 in order
//
// Imports only Foundation, CryptoKit, Security and zlib, and the AT-C11 calls go
// through CorePrimitives. Nothing here persists, logs or transmits a secret.
