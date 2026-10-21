// conformance/swift/: what the Swift executor writes for the other executors to
// check (spec 01 §15.1-§15.2; critic §5.5 "one writer per directory").
//
//   op-manifest-v4.json       the schema-4 registry (00 §3's proposed wire order,
//                             confirmed) and op-codec cases: input body → the
//                             bytes this encoder writes, and refusals
//   crypto-v3/frames.json     Swift-sealed frames (libz gzip, random nonces) with
//   crypto-v3/frames/*.bin    their key inputs, envelope, prev_hash, blob_hash and
//                             plaintext: Go opens them with blobtest.Open3
//   crypto-v3/wraps.json      Swift recovery and PRF wraps and phrase boxes
//                             (random salt and nonce): Go opens them with cryptoref
//   crypto-v3/signatures.json CryptoKit Ed25519 and P-256 signatures over every
//                             §10.1 message vector: Go verifies them
//   crypto-v3/password.json   CommonCrypto `S` (600,000) for the password inputs
//
// Regenerate (it rewrites every file; frames, wraps and signatures change on
// every run because nonces, salts and signatures are random):
//
//   HASALA_WRITE_SWIFT_GOLDENS=1 swift test --filter SwiftGoldenTests
//
// Without the variable, the suite checks that the committed files still hold:
// the op cases re-encode byte for byte, every frame, wrap and box opens, every
// signature verifies and every `S` is reproduced. Those checks re-read Swift's
// own outputs; the cross-check is the other executors reading them.
import CoreCrypto
import CoreJSON
import CorePrimitives
import CoreSoftAuth
import CoreWire
import Foundation
import Testing

@Suite("conformance/swift goldens", .serialized)
struct SwiftGoldenTests {
  static let root = Fixtures.conformanceRoot.appendingPathComponent("swift", isDirectory: true)
  static let writing = ProcessInfo.processInfo.environment["HASALA_WRITE_SWIFT_GOLDENS"] == "1"
  typealias A = Anchor

  // MARK: - Writing

  @Test("write the goldens (only with HASALA_WRITE_SWIFT_GOLDENS=1)", .enabled(if: SwiftGoldenTests.writing))
  func write() async throws {
    let fm = FileManager.default
    try fm.createDirectory(at: Self.root.appendingPathComponent("crypto-v3/frames"), withIntermediateDirectories: true)
    try Self.save(try Self.opManifest(), "op-manifest-v4.json")
    try Self.save(try Self.frames(), "crypto-v3/frames.json")
    try Self.save(try Self.wraps(), "crypto-v3/wraps.json")
    try Self.save(try await Self.signatures(), "crypto-v3/signatures.json")
    try Self.save(try Self.passwords(), "crypto-v3/password.json")
    try Self.save(Self.manifest(), "manifest.json")
  }

  static func save(_ v: JSONValue, _ path: String) throws {
    try Data(Pretty.text(v).utf8).write(to: root.appendingPathComponent(path))
  }

  static func manifest() -> JSONValue {
    obj([
      (
        "note",
        .string(
          "Written by the Swift executor (HasalaCore, WS-9: HasalaCoreConformanceTests/SwiftGoldenTests). Go reads these files; Swift never re-derives another executor's expectation. Frames, wraps and signatures are random per run: check them by opening and verifying, never by comparing bytes."
        )
      ),
      ("spec", .string("01-crypto-and-log-format, 2026-10-11 review 2; 00 §3 op registry")),
      ("regenerate", .string("HASALA_WRITE_SWIFT_GOLDENS=1 swift test --filter SwiftGoldenTests (in ios/HasalaCore)")),
      ("domains", .array(Domain.allCases.map { .string($0.rawValue) })),
      (
        "files",
        .array(
          ([
            "op-manifest-v4.json", "crypto-v3/frames.json", "crypto-v3/wraps.json", "crypto-v3/signatures.json",
            "crypto-v3/password.json",
          ] + FoldGoldens.sets.map(\.file)).map { JSONValue.string($0) })
      ),
    ])
  }

  // MARK: op-manifest-v4.json

  static let opInputs: [(String, String)] = [
    (
      "v4-parent-free-offset-time",
      #"{"v":4,"kind":"ops","ops":[{"v":4,"type":"merchant_named","op_id":"01J0000000000000000000000M","authored_at":"2026-06-05T14:00:00.123456+04:00","payload":{"merchant_key":"carrefour","name":"Carrefour"}}]}"#
    ),
    (
      "v4-versioned-create-and-edit",
      #"{"v":4,"kind":"ops","ops":[{"v":4,"type":"goal_defined","op_id":"01J0000000000000000000000G","authored_at":"2026-06-05T10:00:00Z","entity":{"kind":"goal","id":"01J000000000000000000000G1"},"parent_version":null,"payload":{"name":"Hajj","target_minor":"1500000"}},{"v":4,"type":"goal_defined","op_id":"01J0000000000000000000000H","authored_at":"2026-06-05T10:00:01Z","entity":{"kind":"goal","id":"01J000000000000000000000G1"},"parent_version":1,"payload":{"name":"Hajj 2027"}}]}"#
    ),
    (
      "mixed-versions-blob-v-is-the-max",
      #"{"v":3,"kind":"ops","ops":[{"v":1,"type":"txn_ingested","op_id":"01J000000000000000000000I1","authored_at":"2026-06-05T10:00:00Z","entity":{"kind":"txn","id":"T1"},"parent_version":null,"ingest_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","payload":{"amount_minor":"25000","currency":"AED"}},{"v":3,"type":"category_defined","op_id":"01J000000000000000000000C1","authored_at":"2026-06-05T10:00:00Z","parent_version":null,"payload":{"id":"groceries","name":"Groceries"}}]}"#
    ),
    (
      "js-key-order-and-number-spelling",
      #"{"v":4,"kind":"ops","ops":[{"payload":{"b":1.50,"2":"two","a":1e2,"1":[true,null,-0]},"type":"txn_annotated","v":4,"op_id":"01J0000000000000000000000A","authored_at":"2026-06-05T10:00:00Z"}]}"#
    ),
    (
      "escapes-written-literally",
      #"{"v":4,"kind":"ops","ops":[{"v":4,"type":"sender_trust_set","op_id":"01J0000000000000000000000S","authored_at":"2026-06-05T10:00:00Z","payload":{"domain":"a<b>&c  é\u0007/"}}]}"#
    ),
  ]

  /// v3 twins of the cases above: the TypeScript oracle (schema 3) reads these
  /// and must write the same bytes.
  static let v3Inputs: [(String, String)] = [
    (
      "v3-offset-time-truncated-to-ms",
      #"{"v":1,"kind":"ops","ops":[{"v":1,"type":"rate_set","op_id":"01J0000000000000000000000R","authored_at":"2026-06-05T14:00:00.123456+04:00","payload":{"currency":"USD","rate":"3.6725"}}]}"#
    ),
    (
      "v3-js-key-order-and-number-spelling",
      #"{"v":3,"kind":"ops","ops":[{"payload":{"b":1.50,"2":"two","a":1e2,"1":[true,null,-0]},"type":"budget_split_set","v":3,"op_id":"01J0000000000000000000000B","authored_at":"2026-06-05T10:00:00Z"}]}"#
    ),
    (
      "v3-escapes-written-literally",
      #"{"v":3,"kind":"ops","ops":[{"v":3,"type":"bank_declared","op_id":"01J0000000000000000000000D","authored_at":"2026-06-05T10:00:00Z","payload":{"bank":"a<b>&c\u2028\u2029\u00e9\u0007/","active":true}}]}"#
    ),
    (
      "v3-versioned-edit-with-parent",
      #"{"v":2,"kind":"ops","ops":[{"v":2,"type":"txn_duplicate_disposition","op_id":"01J000000000000000000000D1","authored_at":"2026-06-05T10:00:00.5Z","entity":{"kind":"txn","id":"T1"},"parent_version":3,"ingest_id":"","payload":{"other_txn_id":"T0","disposition":null}}]}"#
    ),
  ]

  static let refusals: [(String, String)] = [
    (
      "reserved-profile-set-sets-the-whole-blob-aside",
      #"{"v":4,"kind":"ops","ops":[{"v":4,"type":"rate_set","op_id":"r","authored_at":"2026-06-05T10:00:00Z","payload":{}},{"v":4,"type":"profile_set","op_id":"p","authored_at":"2026-06-05T10:00:00Z","payload":{}}]}"#
    ),
    (
      "v4-type-below-its-min-version",
      #"{"v":3,"kind":"ops","ops":[{"v":3,"type":"budget_set","op_id":"b","authored_at":"2026-06-05T10:00:00Z","payload":{}}]}"#
    ),
    ("blob-v5-is-the-hard-stop", #"{"v":5,"kind":"ops","ops":[]}"#),
    (
      "op-v5-is-the-hard-stop",
      #"{"v":4,"kind":"ops","ops":[{"v":5,"type":"rate_set","op_id":"r","authored_at":"2026-06-05T10:00:00Z","payload":{}}]}"#
    ),
    (
      "entity-on-a-parent-free-v4-op",
      #"{"v":4,"kind":"ops","ops":[{"v":4,"type":"account_set","op_id":"a","authored_at":"2026-06-05T10:00:00Z","entity":{"kind":"account","id":"ac_cash"},"payload":{}}]}"#
    ),
    (
      "versioned-v4-op-without-entity",
      #"{"v":4,"kind":"ops","ops":[{"v":4,"type":"bill_set","op_id":"b","authored_at":"2026-06-05T10:00:00Z","payload":{}}]}"#
    ),
  ]

  static func opManifest() throws -> JSONValue {
    var encode: [JSONValue] = []
    for (name, body) in opInputs + v3Inputs {
      let out = try OpCodec.encodeBlobOps(try OpCodec.decodeBlobOps(Array(body.utf8)))
      encode.append(
        obj([
          ("name", .string(name)), ("input_base64", .string(Base64.encode(Array(body.utf8)))),
          ("expect_body_base64", .string(Base64.encode(out))),
        ]))
    }
    var refuse: [JSONValue] = []
    for (name, body) in refusals {
      let outcome: (String, String)
      switch OpCodec.decodeR10(Array(body.utf8)) {
      case .ops: outcome = ("ok", "")
      case .hardStop: outcome = ("update_required", "")
      case .setAside(_, let m): outcome = ("set_aside", m)
      }
      refuse.append(
        obj([
          ("name", .string(name)), ("input_base64", .string(Base64.encode(Array(body.utf8)))),
          ("expect", .string(outcome.0)), ("expect_reason", .string(outcome.1)),
        ]))
    }
    return obj([
      (
        "note",
        .string(
          "The schema-4 op registry as HasalaCore decodes it (00 §3's proposed wire order, confirmed by WS-9), and the envelope codec's bytes. encode_cases: input body → decode → encode → expect_body (JSON.stringify's bytes: Go-struct envelope order, JavaScript payload key order and number spelling, authored_at canonical .sssZ). decode_refusals: the blob is the unit of decode (01 §6.6 R10, T36); expect_reason is the oracle's message, which reaches state.unreadable."
        )
      ),
      ("schema_version", .number(JSONNumber(Int64(SchemaVersion.current)))),
      ("author_version", .number(JSONNumber(Int64(SchemaVersion.author)))),
      ("types", .array(OpType.allCases.map { .string($0.rawValue) })),
      ("parent_free", .array(OpType.allCases.filter(\.isParentFree).map { .string($0.rawValue) })),
      ("min_versions", obj(OpType.allCases.map { ($0.rawValue, .number(JSONNumber(Int64($0.minVersion)))) })),
      ("entity_kinds", obj(OpType.allCases.compactMap { t in t.entityKind.map { (t.rawValue, .string($0)) } })),
      ("reserved", .array(OpType.reserved.map { .string($0) })),
      ("encode_cases", .array(encode)),
      ("decode_refusals", .array(refuse)),
    ])
  }

  // MARK: crypto-v3/frames.json

  /// A plaintext op blob of about `n` bytes of incompressible-ish payload.
  static func plaintext(_ n: Int, seed: String) throws -> Data {
    let filler = Base64.encode(try SystemRandom().bytes(max(1, n)))
    let body =
      #"{"v":4,"kind":"ops","ops":[{"v":4,"type":"txn_annotated","op_id":"01J0000000000000000000000N","authored_at":"2026-06-05T10:00:00.000Z","parent_version":null,"payload":{"txn_id":"\#(seed)","set":{"note":"\#(filler)"}}}]}"#
    return Data(body.utf8)
  }

  static func frames() throws -> JSONValue {
    let k1 = try EpochKey.first(body: try KeyBody(amk: A.amk, aakSeed: A.aakSeed), userID: A.userID)
    let sealer = Sealer(epoch: 1, key: k1)
    var out: [JSONValue] = []
    var prev = Hash32.zero
    // A chain at counters 1-4 landing in each of the four lower buckets, then
    // the AAD-length counters 9, 10 and 99999 (L = 83, 84, 87).
    let plan: [(Int64, Int)] = [(1, 600), (2, 2400), (3, 9000), (4, 40000), (9, 50), (10, 50), (99999, 50)]
    for (counter, size) in plan {
      let env = try Envelope(userID: A.userID, writerID: A.writerID, counter: counter)
      let p = try plaintext(size, seed: "c\(counter)")
      if counter > 4 { prev = Hash32.of(Data("prev \(counter)".utf8)) }
      let f = try sealer.seal(plaintextOps: p, envelope: env, prevHash: prev, random: SystemRandom())
      let file = "frames/swift-\(counter)-\(f.bytes.count).bin"
      try f.bytes.write(to: root.appendingPathComponent("crypto-v3/" + file))
      out.append(
        obj([
          ("file", .string(file)), ("user_id", .string(A.userID.string)), ("writer_id", .string(A.writerID.string)),
          ("counter", .string(String(counter))), ("epoch", .number(JSONNumber(1))),
          ("aad_len", .number(JSONNumber(Int64(env.aad.count)))), ("bucket", .number(JSONNumber(Int64(f.bytes.count)))),
          ("prev_hash", .string(prev.hex)), ("blob_hash", .string(f.blobHash.hex)),
          ("plaintext_length", .number(JSONNumber(Int64(p.count)))),
          ("expect_plaintext_sha256", .string(Hex.encode(sha256(p)))),
        ]))
      if counter <= 4 { prev = f.blobHash }
    }
    return obj([
      (
        "note",
        .string(
          "Frames sealed by CoreCrypto.Sealer (system zlib gzip level 9, nonces from the system CSPRNG) under K_1 = HKDF(AMK, uuid_raw(user_id), D10 ‖ 00 ‖ u32be(1)) with spec 01 §15.5's AMK (40..5f) and user_id. Counters 1-4 chain from 0^32 (each prev_hash is the previous blob_hash); 9, 10 and 99999 carry a synthetic prev_hash = SHA256(\"prev <counter>\"). Open each with its envelope and prev_hash; the plaintext (an op blob) has the listed length and SHA-256; check blob_hash = SHA256(prev_hash ‖ frame) and LooksSealed."
        )
      ),
      ("amk_hex", .string(Hex.encode(A.amk))),
      ("frames", .array(out)),
    ])
  }

  // MARK: crypto-v3/wraps.json

  static func wraps() throws -> JSONValue {
    let body = try KeyBody(amk: A.amk, aakSeed: A.aakSeed)
    let r = SystemRandom()
    var recovery: [JSONValue] = []
    var prf: [JSONValue] = []
    var boxes: [JSONValue] = []
    for _ in 0..<3 {
      recovery.append(
        .string(Hex.encode(try Wrap.sealRecovery(body: body, entropy: A.entropy, userID: A.userID, random: r))))
      prf.append(
        .string(
          Hex.encode(
            try Wrap.sealPRF(body: body, prfOutput: A.prfOutput, userID: A.userID, credentialID: A.credentialID, random: r))))
      boxes.append(
        .string(
          Hex.encode(
            try PhraseBox.seal(
              entropy: A.entropy, amk: A.amk, userID: A.userID,
              recoveryPublicKey: try KeyDerivation.recoveryPublicKey(entropy: A.entropy), random: r))))
    }
    return obj([
      (
        "note",
        .string(
          "Wraps and phrase boxes sealed by CoreCrypto with random salts and nonces from spec 01 §15.5's inputs: E, P, the body 01 ‖ AMK (40..5f) ‖ AAK seed (60..7f), user_id and credential_id 01..10. Each recovery wrap opens with E, each PRF wrap with P and the credential id, each box with K_pv of the AMK and recovery_pubkey(E); all open to the body or E."
        )
      ),
      ("user_id", .string(A.userID.string)),
      ("entropy_hex", .string(Hex.encode(A.entropy))),
      ("prf_output_hex", .string(Hex.encode(A.prfOutput))),
      ("credential_id_hex", .string(Hex.encode(A.credentialID))),
      ("body_hex", .string(Hex.encode(body.encoded().data))),
      ("recovery_wraps", .array(recovery)),
      ("prf_wraps", .array(prf)),
      ("phrase_boxes", .array(boxes)),
    ])
  }

  // MARK: crypto-v3/signatures.json

  static func messages() throws -> [(name: String, signer: String, message: Data)] {
    let c = try StepUp.challenge(nonce: A.stepUpNonce, params: .passkeyDelete(credentialID: A.credentialID))
    let ek = try Ed25519.publicKey(seed: A.ekSeed)
    let a10 = Hash32(hex: "cee22837f339529583565b5de892c0783314923db66a5fdf4432590bec301b3d")!
    let s = AnchorVectorTests.a19S
    return [
      (
        "A13 RegistrationMessage", "aak",
        try SigningMessage.registration(
          nonce: A.writerChallengeNonce, writerID: A.writerID, dwkPublicKey: AnchorVectorTests.dwkPub,
          dakPublicKey: AnchorVectorTests.dakPub)
      ),
      (
        "A14 BootstrapMessage", "aak",
        try SigningMessage.bootstrap(
          nonce: A.writerChallengeNonce, payload: try AnchorVectorTests.bootstrapPayload(password: false).encoded())
      ),
      (
        "A14-P BootstrapMessage", "aak",
        try SigningMessage.bootstrap(
          nonce: A.writerChallengeNonce, payload: try AnchorVectorTests.bootstrapPayload(password: true).encoded())
      ),
      (
        "A15 RevocationMessage", "dwk",
        try SigningMessage.revocation(nonce: A.stepUpNonce, writerID: A.writerID, finalCounter: 2, finalHead: a10)
      ),
      ("A15 DeletionMessage", "dwk", try SigningMessage.deletion(nonce: A.stepUpNonce, userID: A.userID)),
      ("A16 SessionBindMessage", "dwk", try SigningMessage.sessionBind(loginChallenge: A.loginChallenge, writerID: A.writerID)),
      (
        "A17 RecoverySigninMessage passkey", "rk",
        try SigningMessage.recoverySigninPasskey(
          nonce: A.recoverNonce, clientDataJSON: A.clientDataJSON, attestationObject: A.attestationObject,
          prfWrap: AnchorVectorTests.prfWrap)
      ),
      (
        "A17 RecoverySigninMessage password", "rk",
        try SigningMessage.recoverySigninPassword(nonce: A.recoverNonce, newVerifier: s)
      ),
      (
        "A18 RecoveryRotateMessage", "aak",
        try SigningMessage.recoveryRotate(
          nonce: A.stepUpNonce,
          newRecoveryPublicKey: try KeyDerivation.recoveryPublicKey(entropy: Data(repeating: 0x80, count: 16)),
          newRecoveryWrap: A.run(0x11, 0x8f),
          newPhraseBox: try PhraseBox.seal(
            entropy: Data(repeating: 0x80, count: 16), amk: A.amk, userID: A.userID,
            recoveryPublicKey: try KeyDerivation.recoveryPublicKey(entropy: Data(repeating: 0x80, count: 16)),
            nonce: A.phraseBoxNonce))
      ),
      (
        "A20 PasskeyAddMessage", "dwk",
        try SigningMessage.passkeyAdd(
          nonce: A.stepUpNonce, clientDataJSON: A.clientDataJSON, attestationObject: A.attestationObject,
          prfWrap: AnchorVectorTests.prfWrap)
      ),
      (
        "A20 WrapPutMessage", "dwk",
        try SigningMessage.wrapPut(nonce: A.stepUpNonce, credentialID: A.credentialID, wrap: AnchorVectorTests.prfWrap)
      ),
      ("A21 HeadMessage", "dwk", SigningMessage.head(userID: A.userID, counter: 2, blobHash: a10, writerID: A.writerID)),
      ("A22 DeviceStepUpMessage", "dak", try SigningMessage.deviceStepUp(challenge: c, writerID: A.writerID)),
      (
        "A24 EmailChangeMessage", "rk",
        try SigningMessage.emailChange(nonce: A.stepUpNonce, newEmailNorm: try EmailNorm.normalize(A.newAddress))
      ),
      (
        "A25 ResetApproveMessage", "dak",
        try SigningMessage.resetApprove(nonce: A.resetNonce, userID: A.userID, ephemeralPublicKey: ek, writerID: A.writerID)
      ),
      ("A25 ResetFinishMessage", "ek", try SigningMessage.resetFinish(nonce: A.resetNonce, newVerifier: s)),
      (
        "A26 DeviceFreezeMessage", "dak",
        try SigningMessage.deviceFreeze(nonce: A.stepUpNonce, userID: A.userID, writerID: A.writerID)
      ),
    ]
  }

  static func ed25519Seed(_ signer: String) throws -> Data {
    switch signer {
    case "aak": A.aakSeed
    case "dwk": A.dwkSeed
    case "rk": try KeyDerivation.recoveryKeySeed(entropy: A.entropy).data
    case "ek": A.ekSeed
    default: Data()
    }
  }

  static func publicKey(_ signer: String) throws -> Data {
    signer == "dak" ? AnchorVectorTests.dakPub : try Ed25519.publicKey(seed: try ed25519Seed(signer))
  }

  static func signatures() async throws -> JSONValue {
    let dak = try SoftDAK.signer()
    var out: [JSONValue] = []
    for m in try messages() {
      let sig: Data
      if m.signer == "dak" {
        sig = try await dak.sign(m.message, userID: A.userID, writerID: A.writerID, reason: "golden")
      } else {
        sig = try Ed25519.sign(seed: try ed25519Seed(m.signer), message: m.message)
      }
      out.append(
        obj([
          ("name", .string(m.name)), ("alg", .string(m.signer == "dak" ? "p256" : "ed25519")),
          ("signer", .string(m.signer)), ("public_key_hex", .string(Hex.encode(try publicKey(m.signer)))),
          ("message_hex", .string(Hex.encode(m.message))), ("signature_hex", .string(Hex.encode(sig))),
        ]))
    }
    return obj([
      (
        "note",
        .string(
          "CryptoKit signatures over spec 01 §15.5's message vectors: Ed25519 (randomized in CryptoKit) by the AAK (seed 60..7f), the DWK (80..9f), RK (from E) and the EK (b0..cf); P-256 (raw r ‖ s over SHA-256) by A13's DAK (scalar 01..20) through CoreSoftAuth's software approval key. Verify each under public_key_hex; never compare signature bytes."
        )
      ),
      ("signatures", .array(out)),
    ])
  }

  // MARK: crypto-v3/password.json

  static let passwordInputs: [(String, String)] = [
    (A.address, A.passwordNFD),
    (A.address, "Hasala café 2026!"),
    ("someone@example.com", "correct horse battery staple"),
    ("someone@example.com", "abcdefghijkl"),
    ("someone@example.com", String(repeating: "\u{0628}", count: 128)),
  ]

  static func passwords() throws -> JSONValue {
    var out: [JSONValue] = []
    for (address, pw) in passwordInputs {
      let norm = try EmailNorm.normalize(address)
      let sSrv = ServerKeys.serverSalt(A.saltKey, emailNorm: norm)
      let s = try PasswordStretch.stretch(password: pw, serverSalt: sSrv, emailNorm: norm)
      out.append(
        obj([
          ("address", .string(address)), ("email_norm", .string(norm)), ("s_srv_hex", .string(Hex.encode(sSrv))),
          ("password_utf8_hex", .string(Hex.encode(Array(pw.utf8)))),
          ("scalars_after_nfc", .number(JSONNumber(Int64(pw.precomposedStringWithCanonicalMapping.unicodeScalars.count)))),
          ("salt_c_hex", .string(Hex.encode(try PasswordStretch.salt(serverSalt: sSrv, emailNorm: norm)))),
          ("s_hex", .string(Hex.encode(s.data))),
        ]))
    }
    return obj([
      (
        "note",
        .string(
          "S = PBKDF2-HMAC-SHA256(utf8(NFC(password)), salt_c, 600000) by CommonCrypto (spec 01 §4.10), salt_c = \"hasala/v1/password\" ‖ 00 ‖ s_srv ‖ utf8(email_norm), s_srv from spec 01 §15.5's salt_key (11..30). The first two entries are A19's NFD password and its NFC twin: same S. The last two sit at the policy's bounds (12 and 128 scalars)."
        )
      ),
      ("iterations", .number(JSONNumber(Int64(PasswordStretch.iterations)))),
      ("cases", .array(out)),
    ])
  }

  // MARK: - Checking the committed files

  static func load(_ path: String) throws -> JSONValue { try Fixtures.json("swift/" + path) }

  @Test("op-manifest-v4.json: the registry and every case still hold")
  func checkOps() throws {
    let m = try Self.load("op-manifest-v4.json")
    #expect(try m.array("types").map { $0.stringValue ?? "" } == OpType.allCases.map(\.rawValue))
    #expect(try m.array("reserved").map { $0.stringValue ?? "" } == ["profile_set"])
    for c in try m.array("encode_cases") {
      let input = [UInt8](try c.base64("input_base64"))
      #expect(try OpCodec.encodeBlobOps(try OpCodec.decodeBlobOps(input)) == [UInt8](try c.base64("expect_body_base64")))
    }
    for c in try m.array("decode_refusals") {
      let input = [UInt8](try c.base64("input_base64"))
      switch OpCodec.decodeR10(input) {
      case .ops: Issue.record("accepted \(try c.string("name"))")
      case .hardStop: #expect(try c.string("expect") == "update_required")
      case .setAside(_, let msg):
        #expect(try c.string("expect") == "set_aside")
        #expect(try c.string("expect_reason") == msg)
      }
    }
  }

  @Test("crypto-v3/frames.json: every frame opens at its envelope and chains")
  func checkFrames() throws {
    let m = try Self.load("crypto-v3/frames.json")
    let k1 = try EpochKey.first(body: try KeyBody(amk: try Hex.decode(try m.string("amk_hex")), aakSeed: A.aakSeed), userID: A.userID)
    let frames = try m.array("frames")
    #expect(frames.count == 7)
    var buckets = Set<Int>()
    for f in frames {
      let bytes = try Fixtures.data("swift/crypto-v3/" + (try f.string("file")))
      buckets.insert(bytes.count)
      #expect(LooksSealed.check(bytes) == nil)
      let env = try Envelope(
        userID: UserID(try f.string("user_id"))!, writerID: WriterID(try f.string("writer_id"))!,
        counter: Int64(try f.string("counter"))!)
      #expect(env.aad.count == (try f.int("aad_len")))
      let prev = Hash32(hex: try f.string("prev_hash"))!
      #expect(Chain.hash(prev: prev, frame: bytes).hex == (try f.string("blob_hash")))
      guard case .opened(let p) = Opener(epochHWM: 1, keys: [k1]).open(bytes, envelope: env, prevHash: prev) else {
        Issue.record("did not open: \(try f.string("file"))")
        continue
      }
      #expect(p.count == (try f.int("plaintext_length")))
      #expect(Hex.encode(sha256(p)) == (try f.string("expect_plaintext_sha256")))
      #expect(try !OpCodec.decodeBlobOps(p).isEmpty)
    }
    #expect(buckets == [1024, 4096, 16384, 65536])
  }

  @Test("crypto-v3/wraps.json: every wrap and box opens")
  func checkWraps() throws {
    let m = try Self.load("crypto-v3/wraps.json")
    let body = try Hex.decode(try m.string("body_hex"))
    let rk = try KeyDerivation.recoveryPublicKey(entropy: A.entropy)
    for w in try m.array("recovery_wraps") {
      let b = try Wrap.openRecovery(try Hex.decode(w.stringValue ?? ""), entropy: A.entropy, userID: A.userID)
      #expect(b.encoded().data == body)
    }
    for w in try m.array("prf_wraps") {
      let b = try Wrap.openPRF(
        try Hex.decode(w.stringValue ?? ""), prfOutput: A.prfOutput, userID: A.userID, credentialID: A.credentialID)
      #expect(b.encoded().data == body)
    }
    for x in try m.array("phrase_boxes") {
      #expect(try PhraseBox.open(try Hex.decode(x.stringValue ?? ""), amk: A.amk, userID: A.userID, recoveryPublicKey: rk).data == A.entropy)
    }
  }

  @Test("crypto-v3/signatures.json: the messages are today's bytes and every signature verifies")
  func checkSignatures() throws {
    let m = try Self.load("crypto-v3/signatures.json")
    let current = try Self.messages()
    let sigs = try m.array("signatures")
    #expect(sigs.count == current.count)
    for (s, want) in zip(sigs, current) {
      let message = try Hex.decode(try s.string("message_hex"))
      #expect(message == want.message, "\(want.name)")
      let pub = try Hex.decode(try s.string("public_key_hex"))
      #expect(pub == (try Self.publicKey(want.signer)))
      let sig = try Hex.decode(try s.string("signature_hex"))
      if try s.string("alg") == "p256" {
        #expect(DAK.verify(publicKey: pub, signature: sig, message: message), "\(want.name)")
      } else {
        #expect(Ed25519.verify(publicKey: pub, signature: sig, message: message), "\(want.name)")
      }
    }
  }

  @Test("crypto-v3/password.json: every S is reproduced")
  func checkPasswords() throws {
    let m = try Self.load("crypto-v3/password.json")
    let cases = try m.array("cases")
    #expect(cases.count == Self.passwordInputs.count)
    for c in cases {
      let pw = String(decoding: try Hex.decode(try c.string("password_utf8_hex")), as: UTF8.self)
      let s = try PasswordStretch.stretch(
        password: pw, serverSalt: try Hex.decode(try c.string("s_srv_hex")), emailNorm: try c.string("email_norm"))
      #expect(Hex.encode(s.data) == (try c.string("s_hex")))
    }
    #expect(cases[0]["s_hex"] == cases[1]["s_hex"])
    #expect(cases[0]["s_hex"]?.stringValue == Hex.encode(AnchorVectorTests.a19S))
  }

  @Test("manifest.json lists the registry")
  func checkManifest() throws {
    let m = try Self.load("manifest.json")
    #expect(try m.array("domains").map { $0.stringValue ?? "" } == Domain.allCases.map(\.rawValue))
  }
}

func obj(_ pairs: [(String, JSONValue)]) -> JSONValue { .object(JSONObject(pairs)) }

/// A two-space-indented rendering for files people diff; values are written by
/// CoreJSON's canonical writer.
enum Pretty {
  static func text(_ v: JSONValue) -> String {
    var out = ""
    write(v, 0, &out)
    return out + "\n"
  }

  static func write(_ v: JSONValue, _ depth: Int, _ out: inout String) {
    let pad = String(repeating: "  ", count: depth + 1)
    let close = String(repeating: "  ", count: depth)
    switch v {
    case .array(let a) where !a.isEmpty && a.contains(where: { $0.objectValue != nil || $0.arrayValue != nil }):
      out += "[\n"
      for (i, x) in a.enumerated() {
        out += pad
        write(x, depth + 1, &out)
        out += i + 1 < a.count ? ",\n" : "\n"
      }
      out += close + "]"
    case .array(let a) where !a.isEmpty:
      out += "[\n" + a.map { pad + JSONWriter(numbers: .literal, keyOrder: .insertion).string($0) }.joined(separator: ",\n")
        + "\n" + close + "]"
    case .object(let o) where o.count > 0:
      out += "{\n"
      for (i, m) in o.members.enumerated() {
        out += pad + JSONWriter().string(.string(m.key)) + ": "
        write(m.value, depth + 1, &out)
        out += i + 1 < o.count ? ",\n" : "\n"
      }
      out += close + "}"
    default:
      out += JSONWriter(numbers: .literal, keyOrder: .insertion).string(v)
    }
  }
}
