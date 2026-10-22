// The JSON of `02` §7's auth, account, key and writer routes, field for field.
// Byte fields are strings: standard base64 (`b64`) unless the route says
// base64url (`b64url`); hashes in hex; counters and seqs as decimal strings.
// Building the bytes is CoreCrypto's (the caller's); this file only carries them.
import Foundation

// MARK: - Signup and creation (#43, #44, #3, #4, #45)

public struct SignupBeginRequest: Codable, Sendable, Hashable {
  public let invite_code: String
  public let email: String
  public let display_name: String
  public let invite_link_key: String?
  public init(inviteCode: String, email: String, displayName: String, inviteLinkKey: String?) {
    invite_code = inviteCode
    self.email = email
    display_name = displayName
    invite_link_key = inviteLinkKey
  }
}

public struct SignupBeginResponse: Codable, Sendable, Hashable {
  public let signup_id: String
  public let user_id: String
  public let email_proven: Bool
  /// `s_srv`, b64 32.
  public let salt: String
  /// The signup nonce, b64 32 (signs C1-P's bootstrap).
  public let nonce: String
  public let expires_at: String?

  public init(signup_id: String, user_id: String, email_proven: Bool, salt: String, nonce: String, expires_at: String? = nil) {
    self.signup_id = signup_id
    self.user_id = user_id
    self.email_proven = email_proven
    self.salt = salt
    self.nonce = nonce
    self.expires_at = expires_at
  }
}

public struct SignupVerifyRequest: Codable, Sendable, Hashable {
  public let signup_id: String
  public let code: String
  public init(signupID: String, code: String) {
    signup_id = signupID
    self.code = code
  }
}

public struct RegisterBeginRequest: Codable, Sendable, Hashable {
  public let signup_id: String
  public let authority_pubkey: String
  public init(signupID: String, authorityPublicKeyB64: String) {
    signup_id = signupID
    authority_pubkey = authorityPublicKeyB64
  }
}

public struct RegisterBeginResponse: Codable, Sendable, Hashable {
  public let ceremony_id: String
  public let nonce: String
  public let options: WireCreationOptions

  public init(ceremony_id: String, nonce: String, options: WireCreationOptions) {
    self.ceremony_id = ceremony_id
    self.nonce = nonce
    self.options = options
  }
}

public struct RegisterFinishRequest: Codable, Sendable, Hashable {
  public let ceremony_id: String
  public let credential: PublicKeyCredentialJSON
  public init(ceremonyID: String, credential: PublicKeyCredentialJSON) {
    ceremony_id = ceremonyID
    self.credential = credential
  }
}

/// The session a sign-in or creation route mints (#4, #6, #8, #45, #47, #54).
public struct SessionGrant: Codable, Sendable, Hashable {
  public let session_token: String
  public let user_id: String
  /// The 90-day cap (RFC 3339).
  public let expires_at: String?
  public let writer_id: String?
  public let has_keys: Bool?
  public let restricted: Bool?

  public init(
    session_token: String, user_id: String, expires_at: String?, writer_id: String?, has_keys: Bool?, restricted: Bool?
  ) {
    self.session_token = session_token
    self.user_id = user_id
    self.expires_at = expires_at
    self.writer_id = writer_id
    self.has_keys = has_keys
    self.restricted = restricted
  }
}

// MARK: - Bootstrap (#18, and inside #45)

public struct BootstrapPRFWrapJSON: Codable, Sendable, Hashable {
  public let credential_id: String  // b64url
  public let wrap: String  // b64, 127 bytes
  public let wrap_version: Int
  public init(credentialIDB64URL: String, wrapB64: String) {
    credential_id = credentialIDB64URL
    wrap = wrapB64
    wrap_version = 1
  }
}

public struct WriterJSON: Codable, Sendable, Hashable {
  public let writer_id: String
  public let alg: String
  public let pubkey: String
  public let dak_pubkey: String
  public init(writerID: String, pubkeyB64: String, dakPubkeyB64: String) {
    writer_id = writerID
    alg = "ed25519"
    pubkey = pubkeyB64
    dak_pubkey = dakPubkeyB64
  }
}

/// `02` §10.1's body. In #45 the same fields travel as `bootstrap`, without
/// `step_up`, with `auth_kind` 2 and the signup nonce.
public struct BootstrapBody: Codable, Sendable, Hashable {
  public let format_version: Int
  public let amk_commitment: String
  public let authority_pubkey: String
  public let recovery_pubkey: String
  public let recovery_wrap: String
  public let phrase_box: String
  public let email_hash: String
  public let auth_kind: Int
  public let auth_hash: String
  public let prf_wrap: BootstrapPRFWrapJSON?
  public let writer: WriterJSON
  public let nonce: String
  public let authority_sig: String
  public let registration_sig: String
  public var step_up: StepUpJSON?
  public var phrase_unseen: Bool?

  public init(
    amkCommitment: String, authorityPubkey: String, recoveryPubkey: String, recoveryWrap: String, phraseBox: String,
    emailHash: String, authKind: Int, authHash: String, prfWrap: BootstrapPRFWrapJSON?, writer: WriterJSON,
    nonce: String, authoritySig: String, registrationSig: String, stepUp: StepUpJSON? = nil
  ) {
    format_version = 1
    amk_commitment = amkCommitment
    authority_pubkey = authorityPubkey
    recovery_pubkey = recoveryPubkey
    recovery_wrap = recoveryWrap
    phrase_box = phraseBox
    email_hash = emailHash
    auth_kind = authKind
    auth_hash = authHash
    prf_wrap = prfWrap
    self.writer = writer
    self.nonce = nonce
    authority_sig = authoritySig
    registration_sig = registrationSig
    step_up = stepUp
  }
}

public struct BootstrapResponse: Codable, Sendable, Hashable {
  public let writer_id: String
  public let current_epoch: Int

  public init(writer_id: String, current_epoch: Int) {
    self.writer_id = writer_id
    self.current_epoch = current_epoch
  }
}

public struct PasswordRegisterRequest: Codable, Sendable, Hashable {
  public let signup_id: String
  public let verifier: String
  public let bootstrap: BootstrapBody
  public init(signupID: String, verifierB64: String, bootstrap: BootstrapBody) {
    signup_id = signupID
    verifier = verifierB64
    self.bootstrap = bootstrap
  }
}

// MARK: - Sign-in (#5, #6, #46, #47)

public struct DeviceBindingJSON: Codable, Sendable, Hashable {
  public let writer_id: String
  public let sig: String
  public init(writerID: String, sigB64: String) {
    writer_id = writerID
    sig = sigB64
  }
}

public struct LoginBeginResponse: Codable, Sendable, Hashable {
  public let ceremony_id: String
  public let options: WireAssertionOptions

  public init(ceremony_id: String, options: WireAssertionOptions) {
    self.ceremony_id = ceremony_id
    self.options = options
  }
}

public struct LoginFinishRequest: Codable, Sendable, Hashable {
  public let ceremony_id: String
  public let credential: PublicKeyCredentialJSON
  public let device: DeviceBindingJSON?
  public init(ceremonyID: String, credential: PublicKeyCredentialJSON, device: DeviceBindingJSON?) {
    ceremony_id = ceremonyID
    self.credential = credential
    self.device = device
  }
}

public struct EmailRequest: Codable, Sendable, Hashable {
  public let email: String
  public init(email: String) { self.email = email }
}

public struct PasswordLoginBeginResponse: Codable, Sendable, Hashable {
  public let ceremony_id: String
  public let salt: String
  public let nonce: String

  public init(ceremony_id: String, salt: String, nonce: String) {
    self.ceremony_id = ceremony_id
    self.salt = salt
    self.nonce = nonce
  }
}

public struct PasswordLoginFinishRequest: Codable, Sendable, Hashable {
  public let ceremony_id: String
  public let verifier: String
  public let device: DeviceBindingJSON?
  public init(ceremonyID: String, verifierB64: String, device: DeviceBindingJSON?) {
    ceremony_id = ceremonyID
    verifier = verifierB64
    self.device = device
  }
}

// MARK: - Step-up (#9, and the `step_up` object of every SU route)

public struct StepUpBeginRequest: Codable, Sendable, Hashable {
  public let action: String
  public let params_hash: String  // hex
  public let proof_kind: String
  public init(action: String, paramsHashHex: String, proofKind: String) {
    self.action = action
    params_hash = paramsHashHex
    proof_kind = proofKind
  }
}

public struct StepUpBeginResponse: Codable, Sendable, Hashable {
  public let nonce: String  // b64url
  public let challenge: String  // b64url
  public let expires_at: String?
  public let rp_id: String?
  public let allow_credentials: [String]?

  public init(nonce: String, challenge: String, expires_at: String? = nil, rp_id: String? = nil, allow_credentials: [String]? = nil) {
    self.nonce = nonce
    self.challenge = challenge
    self.expires_at = expires_at
    self.rp_id = rp_id
    self.allow_credentials = allow_credentials
  }
}

/// `{"nonce", "proof": {...}}` (`02` §7, "The `step_up` object").
public struct StepUpJSON: Codable, Sendable, Hashable {
  public struct Proof: Codable, Sendable, Hashable {
    public let kind: String
    public let assertion: PublicKeyCredentialJSON?
    public let writer_id: String?
    public let sig: String?
    public let verifier: String?
    public let code: String?

    public static func passkey(_ assertion: PublicKeyCredentialJSON) -> Proof {
      Proof(kind: "passkey", assertion: assertion, writer_id: nil, sig: nil, verifier: nil, code: nil)
    }
    public static func device(writerID: String, sigB64: String, verifierB64: String) -> Proof {
      Proof(kind: "device", assertion: nil, writer_id: writerID, sig: sigB64, verifier: verifierB64, code: nil)
    }
    public static func deviceCode(writerID: String, sigB64: String, code: String) -> Proof {
      Proof(kind: "device_code", assertion: nil, writer_id: writerID, sig: sigB64, verifier: nil, code: code)
    }

    public init(kind: String, assertion: PublicKeyCredentialJSON? = nil, writer_id: String? = nil, sig: String? = nil, verifier: String? = nil, code: String? = nil) {
      self.kind = kind
      self.assertion = assertion
      self.writer_id = writer_id
      self.sig = sig
      self.verifier = verifier
      self.code = code
    }
  }
  public let nonce: String
  public let proof: Proof
  public init(nonce: String, proof: Proof) {
    self.nonce = nonce
    self.proof = proof
  }
}

// MARK: - Session and account (#14, #40)

public struct SessionInfo: Codable, Sendable, Hashable {
  public let user_id: String
  public let minted_by: String?
  public let created_at: String?
  public let expires_at: String?
  public let idle_expires_at: String?
  public let writer_id: String?
  public let credential_id: String?
  public let restricted: Bool?

  public init(user_id: String, minted_by: String? = nil, created_at: String? = nil, expires_at: String? = nil, idle_expires_at: String? = nil, writer_id: String? = nil, credential_id: String? = nil, restricted: Bool? = nil) {
    self.user_id = user_id
    self.minted_by = minted_by
    self.created_at = created_at
    self.expires_at = expires_at
    self.idle_expires_at = idle_expires_at
    self.writer_id = writer_id
    self.credential_id = credential_id
    self.restricted = restricted
  }
}

public struct AccountInfo: Codable, Sendable, Hashable {
  public let user_id: String
  public let status: String?
  public let has_keys: Bool?
  public let email: String?
  public let display_name: String?
  public let has_password: Bool?
  public let password_salt: String?
  public let has_passkey: Bool?
  public let frozen: Bool?
  public let restricted: Bool?
  public let review_account: Bool?
  public let phrase_unseen_since: String?

  public init(user_id: String, status: String? = nil, has_keys: Bool? = nil, email: String? = nil, display_name: String? = nil, has_password: Bool? = nil, password_salt: String? = nil, has_passkey: Bool? = nil, frozen: Bool? = nil, restricted: Bool? = nil, review_account: Bool? = nil, phrase_unseen_since: String? = nil) {
    self.user_id = user_id
    self.status = status
    self.has_keys = has_keys
    self.email = email
    self.display_name = display_name
    self.has_password = has_password
    self.password_salt = password_salt
    self.has_passkey = has_passkey
    self.frozen = frozen
    self.restricted = restricted
    self.review_account = review_account
    self.phrase_unseen_since = phrase_unseen_since
  }
}

// MARK: - Keys and writers (#17, #19, #23, #24, #26, #27)

public struct KeysResponse: Codable, Sendable, Hashable {
  public let format_version: Int
  public let amk_commitment: String
  public let authority_pubkey: String
  public let recovery_pubkey: String
  public let recovery_wrap: String
  public let current_epoch: Int

  public init(format_version: Int, amk_commitment: String, authority_pubkey: String, recovery_pubkey: String, recovery_wrap: String, current_epoch: Int) {
    self.format_version = format_version
    self.amk_commitment = amk_commitment
    self.authority_pubkey = authority_pubkey
    self.recovery_pubkey = recovery_pubkey
    self.recovery_wrap = recovery_wrap
    self.current_epoch = current_epoch
  }
}

public struct KeyWrapsResponse: Codable, Sendable, Hashable {
  public struct Wrap: Codable, Sendable, Hashable {
    public let credential_id: String  // b64url
    public let wrap: String  // b64
    public let wrap_version: Int

    public init(credential_id: String, wrap: String, wrap_version: Int) {
      self.credential_id = credential_id
      self.wrap = wrap
      self.wrap_version = wrap_version
    }
  }
  public let wraps: [Wrap]

  public init(wraps: [Wrap]) {
    self.wraps = wraps
  }
}

public struct WriterChallengeResponse: Codable, Sendable, Hashable {
  public let nonce: String  // b64
  public let expires_at: String?

  public init(nonce: String, expires_at: String? = nil) {
    self.nonce = nonce
    self.expires_at = expires_at
  }
}

public struct WriterRegisterRequest: Codable, Sendable, Hashable {
  public let writer_id: String
  public let alg: String
  public let pubkey: String
  public let dak_pubkey: String
  public let nonce: String
  public let sig: String
  public init(writerID: String, pubkeyB64: String, dakPubkeyB64: String, nonceB64: String, sigB64: String) {
    writer_id = writerID
    alg = "ed25519"
    pubkey = pubkeyB64
    dak_pubkey = dakPubkeyB64
    nonce = nonceB64
    sig = sigB64
  }
}

public struct WriterIDResponse: Codable, Sendable, Hashable {
  public let writer_id: String

  public init(writer_id: String) {
    self.writer_id = writer_id
  }
}

public struct WritersResponse: Codable, Sendable, Hashable {
  public struct Writer: Codable, Sendable, Hashable {
    public let writer_id: String
    public let alg: String
    public let pubkey: String
    public let dak_pubkey: String?
    public let revoked_at: String?
    public let current: Bool?

    public init(writer_id: String, alg: String, pubkey: String, dak_pubkey: String? = nil, revoked_at: String? = nil, current: Bool? = nil) {
      self.writer_id = writer_id
      self.alg = alg
      self.pubkey = pubkey
      self.dak_pubkey = dak_pubkey
      self.revoked_at = revoked_at
      self.current = current
    }
  }
  public let writers: [Writer]

  public init(writers: [Writer]) {
    self.writers = writers
  }
}

public struct KeyHistoryResponse: Codable, Sendable, Hashable {
  public struct Entry: Codable, Sendable, Hashable {
    /// Decimal; Go sends a string.
    public let id: FlexibleDecimal
    public let writer_id: String
    public let alg: String
    public let pubkey: String
    public let dak_pubkey: String?
    public let event: String
    public let authorized_by: String
    public let authorizer_writer_id: String?
    public let final_counter: FlexibleDecimal?
    public let final_head: String?
    public let nonce: String
    public let signature: String

    public init(id: FlexibleDecimal, writer_id: String, alg: String, pubkey: String, dak_pubkey: String? = nil, event: String, authorized_by: String, authorizer_writer_id: String? = nil, final_counter: FlexibleDecimal? = nil, final_head: String? = nil, nonce: String, signature: String) {
      self.id = id
      self.writer_id = writer_id
      self.alg = alg
      self.pubkey = pubkey
      self.dak_pubkey = dak_pubkey
      self.event = event
      self.authorized_by = authorized_by
      self.authorizer_writer_id = authorizer_writer_id
      self.final_counter = final_counter
      self.final_head = final_head
      self.nonce = nonce
      self.signature = signature
    }
  }
  public let entries: [Entry]

  public init(entries: [Entry]) {
    self.entries = entries
  }
}

/// A decimal that arrives as a JSON string (Go's `"id":"12"`) or a number.
public struct FlexibleDecimal: Codable, Sendable, Hashable {
  public let value: Int64
  public init(_ v: Int64) { value = v }
  public init(from decoder: any Decoder) throws {
    let c = try decoder.singleValueContainer()
    if let s = try? c.decode(String.self), let v = Int64(s), s.utf8.allSatisfy({ (0x30...0x39).contains($0) }) {
      value = v
    } else {
      value = try c.decode(Int64.self)
    }
  }
  public func encode(to encoder: any Encoder) throws {
    var c = encoder.singleValueContainer()
    try c.encode(String(value))
  }
}

/// `GET /api/v1/meta` (#2).
public struct MetaResponse: Codable, Sendable, Hashable {
  public let rp_id: String?
  public let min_ios_build: Int?
  public let gmail_watch_topic: String?
  /// The Graph subscription's `notificationUrl` and `lifecycleNotificationUrl`; both null when
  /// the server relays no Outlook push.
  public let outlook_notification_url: String?
  public let outlook_lifecycle_url: String?
  public let log_generation: Int64?
  public let server_time: String?

  public init(
    rp_id: String? = nil, min_ios_build: Int? = nil, gmail_watch_topic: String? = nil,
    outlook_notification_url: String? = nil, outlook_lifecycle_url: String? = nil, log_generation: Int64? = nil,
    server_time: String? = nil
  ) {
    self.rp_id = rp_id
    self.min_ios_build = min_ios_build
    self.gmail_watch_topic = gmail_watch_topic
    self.outlook_notification_url = outlook_notification_url
    self.outlook_lifecycle_url = outlook_lifecycle_url
    self.log_generation = log_generation
    self.server_time = server_time
  }
}

// MARK: - Device removal (#25) and account deletion (#41)

public struct WriterRevokeRequest: Codable, Sendable, Hashable {
  public let writer_id: String
  public let signer_writer_id: String
  public let nonce: String  // b64
  public let final_counter: String  // decimal
  public let final_head: String  // b64 32
  public let sig: String  // b64
  public let step_up: StepUpJSON

  public init(
    writer_id: String, signer_writer_id: String, nonce: String, final_counter: String, final_head: String, sig: String,
    step_up: StepUpJSON
  ) {
    self.writer_id = writer_id
    self.signer_writer_id = signer_writer_id
    self.nonce = nonce
    self.final_counter = final_counter
    self.final_head = final_head
    self.sig = sig
    self.step_up = step_up
  }
}

public struct DeleteAccountRequest: Codable, Sendable, Hashable {
  public let step_up: StepUpJSON
  public let writer_id: String
  public let sig: String  // b64, DWK over DeletionMessage(step_up.nonce, user_id)

  public init(step_up: StepUpJSON, writer_id: String, sig: String) {
    self.step_up = step_up
    self.writer_id = writer_id
    self.sig = sig
  }
}

public struct PasskeyAddBeginRequest: Codable, Sendable, Hashable {
  public let step_up: StepUpJSON

  public init(step_up: StepUpJSON) { self.step_up = step_up }
}

public struct PasskeyAddBeginResponse: Codable, Sendable, Hashable {
  public let ceremony_id: String
  public let options: WireCreationOptions

  public init(ceremony_id: String, options: WireCreationOptions) {
    self.ceremony_id = ceremony_id
    self.options = options
  }
}

public struct PasskeyAddFinishRequest: Codable, Sendable, Hashable {
  public let ceremony_id: String
  public let credential: PublicKeyCredentialJSON
  public let prf_wrap: BootstrapPRFWrapJSON?
  public let dwk_sig: String

  public init(ceremonyID: String, credential: PublicKeyCredentialJSON, prfWrap: BootstrapPRFWrapJSON?, dwkSigB64: String) {
    ceremony_id = ceremonyID
    self.credential = credential
    prf_wrap = prfWrap
    dwk_sig = dwkSigB64
  }
}

public struct PasskeyAddResponse: Codable, Sendable, Hashable {
  public let credential_id: String

  public init(credential_id: String) { self.credential_id = credential_id }
}
