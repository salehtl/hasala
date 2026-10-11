// CoreAuth (Auth/), spec 04 §2.2. Owner: WS-11.
//
//   Transport.swift            the HTTP seam (spec 04 §2.7), kept here so the L1 client can use it
//   URLSessionTransport.swift  the production transport (Hasala-Client, Bearer, ephemeral session)
//   APIClient.swift            JSON calls and `02` §6.2 refusals
//   AuthWire.swift             the JSON of `02` §7's auth, account, key and writer routes
//   AuthClient.swift           one method per route
//   WebAuthn.swift             go-webauthn options in, PublicKeyCredential JSON out; the passkey seam
//   ApprovalKeySigner.swift    the DAK seam (spec 04 §2.7)
