// Unit tests for CoreCrypto: the registry, the wordlist and phrase, the
// predicate, accounts and passwords, step-up, DAK checks. The seal/open tamper
// suite is in TamperSuiteTests.swift, the wrap cases in WrapTests.swift.
import CorePrimitives
import CoreWire
import CryptoKit
import Foundation
import Synchronization
import Testing

@testable import CoreCrypto

/// A deterministic `RandomSource`: SHA-256 of (seed, block counter), streamed.
final class StreamRandom: RandomSource {
  private let state: Mutex<(block: UInt64, buffer: [UInt8])>
  private let seed: Data

  init(seed: String) {
    self.seed = Data(seed.utf8)
    state = Mutex((0, []))
  }

  func fill(_ buffer: UnsafeMutableRawBufferPointer) throws(PrimitivesError) {
    state.withLock { s in
      for i in 0..<buffer.count {
        if s.buffer.isEmpty {
          var b = s.block.bigEndian
          s.buffer = [UInt8](sha256(seed + Data(bytes: &b, count: 8)))
          s.block += 1
        }
        buffer[i] = s.buffer.removeFirst()
      }
    }
  }
}

let testUser = UserID("6f1c2b9e-4d3a-4f5b-8c7d-0e1f2a3b4c5d")!
let testWriter = WriterID("ios-0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d")!

@Suite("CoreCrypto: registry and wordlist")
struct RegistryAndWordlistTests {
  @Test("42 domain strings, D01-D42, unique, all hasala/v1/")
  func domains() {
    #expect(Domain.allCases.count == 42)
    #expect(Set(Domain.allCases.map(\.rawValue)).count == 42)
    #expect(Domain.allCases.allSatisfy { $0.rawValue.hasPrefix("hasala/v1/") })
    #expect(Domain.allCases.first == .register && Domain.allCases.last == .deviceFreeze)
    #expect(Domain.writerHead.prefix == Data("hasala/v1/writer-head".utf8) + [0])
    // No retired string survives in the registry.
    #expect(!Domain.allCases.contains { $0.rawValue.contains("ledger") })
  }

  @Test("the wordlist digest (V-C), 2048 words, unique in four letters")
  func wordlist() {
    let joined = BIP39English.words.joined(separator: "\n") + "\n"
    #expect(Hex.encode(sha256(Data(joined.utf8))) == "2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda")
    #expect(BIP39English.words.count == 2048)
    #expect(Set(BIP39English.words.map { String($0.prefix(4)) }).count == 2048)
  }
}

@Suite("CoreCrypto: phrase")
struct PhraseTests {
  // BIP-39's published English vectors (entropy → mnemonic), 128-bit ones.
  static let published: [(String, String)] = [
    (
      "00000000000000000000000000000000",
      "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
    ),
    ("7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f", "legal winner thank year wave sausage worth useful legal winner thank yellow"),
    ("80808080808080808080808080808080", "letter advice cage absurd amount doctor acoustic avoid letter advice cage above"),
    ("ffffffffffffffffffffffffffffffff", "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong"),
    ("9e885d952ad362caeb4efe34a8e91bd2", "ozone drill grab fiber curtain grace pudding thank cruise elder eight picnic"),
  ]

  @Test("published vectors, both directions", arguments: published)
  func vectors(_ entropy: String, _ words: String) throws {
    let e = try Hex.decode(entropy)
    #expect(try Phrase.words(entropy: e).joined(separator: " ") == words)
    #expect(try Phrase.entropy(typed: words).withUnsafeBytes { Data($0) } == e)
  }

  @Test("random entropies round-trip")
  func roundTrip() throws {
    let r = StreamRandom(seed: "phrase")
    for _ in 0..<50 {
      let e = try Phrase.generate(random: r)
      let w = try Phrase.words(entropy: e)
      #expect(try Phrase.entropy(words: w).withUnsafeBytes { Data($0) } == e.withUnsafeBytes { Data($0) })
    }
  }

  @Test(
    "normalization: case, NBSP, U+202F, full-width, tabs, newlines, BOM, outer space",
    arguments: [
      "OZONE drill grab fiber curtain grace pudding thank cruise elder eight picnic",
      "  ozone\u{00A0}drill\u{202F}grab\tfiber\ncurtain\r\ngrace  pudding\u{3000}thank cruise elder eight picnic \u{FEFF}",
      "\u{FF4F}\u{FF5A}\u{FF4F}\u{FF4E}\u{FF45} drill grab fiber curtain grace pudding thank cruise elder eight picnic",
    ])
  func normalization(_ typed: String) throws {
    #expect(
      Phrase.normalize(typed) == "ozone drill grab fiber curtain grace pudding thank cruise elder eight picnic".split(
        separator: " "
      ).map(String.init))
    #expect(try Phrase.entropy(typed: typed).withUnsafeBytes { Data($0) } == (try Hex.decode("9e885d952ad362caeb4efe34a8e91bd2")))
  }

  @Test("errors: length, unknown word (no prefix, no accent), checksum")
  func errors() {
    let good = "ozone drill grab fiber curtain grace pudding thank cruise elder eight picnic"
    #expect(throws: PhraseError.length(count: 11)) { try Phrase.entropy(typed: "ozone drill grab fiber curtain grace pudding thank cruise elder eight") }
    #expect(throws: PhraseError.length(count: 13)) { try Phrase.entropy(typed: good + " picnic") }
    #expect(throws: PhraseError.length(count: 0)) { try Phrase.entropy(typed: "  ") }
    #expect(throws: PhraseError.length(count: 1)) { try Phrase.entropy(typed: "ozone\u{200B}drill") }
    #expect(throws: PhraseError.unknownWord(index: 0, word: "ozon")) { try Phrase.entropy(typed: "ozon" + good.dropFirst(5)) }
    #expect(throws: PhraseError.unknownWord(index: 11, word: "pi\u{301}cnic")) {
      try Phrase.entropy(typed: good.replacingOccurrences(of: "picnic", with: "pícnic"))
    }
    #expect(throws: PhraseError.checksum) { try Phrase.entropy(typed: good.replacingOccurrences(of: "picnic", with: "pig")) }
  }

  @Test("four distinct confirmation positions")
  func confirmation() throws {
    let p = try Phrase.confirmationPositions(random: StreamRandom(seed: "c"))
    #expect(p.count == 4 && Set(p).count == 4 && p.allSatisfy { (0..<12).contains($0) } && p == p.sorted())
  }
}

@Suite("CoreCrypto: LooksSealed")
struct PredicateTests {
  /// A frame of `n` bytes with `L` = 83 that passes every check.
  static func passing(_ n: Int = 1024, aadLength l: Int = 83) -> [UInt8] {
    var b = [UInt8](repeating: 0x5a, count: n)
    b[0] = 3
    b[1] = 0; b[2] = 0; b[3] = 0; b[4] = 1
    b[5] = UInt8(l >> 8); b[6] = UInt8(l & 0xff)
    return b
  }

  @Test("every bucket passes; every other size is `bucket`", arguments: FrameV3.buckets)
  func buckets(_ n: Int) {
    #expect(LooksSealed.check(Self.passing(n)) == nil)
    #expect(LooksSealed.check(Self.passing(n)[0..<(n - 1)]) == .bucket)
    #expect(LooksSealed.check(Self.passing(n) + [0]) == .bucket)
  }

  @Test("each check, in order")
  func checks() {
    var b = Self.passing()
    #expect(LooksSealed.check([UInt8]()) == .bucket)
    for v: UInt8 in [0, 1, 2, 4, 0xff] { b[0] = v; #expect(LooksSealed.check(b) == .version) }
    b = Self.passing()
    b[1] = 0; b[2] = 0; b[3] = 0; b[4] = 0
    #expect(LooksSealed.check(b) == .epoch)
    b[1] = 0x80; b[4] = 0
    #expect(LooksSealed.check(b) == .epoch)
    b[1] = 0x7f; b[2] = 0xff; b[3] = 0xff; b[4] = 0xff
    #expect(LooksSealed.check(b) == nil)
    // L + 67 = n passes, one more is refused.
    #expect(LooksSealed.check(Self.passing(1024, aadLength: 957)) == nil)
    #expect(LooksSealed.check(Self.passing(1024, aadLength: 958)) == .aadLen)
    #expect(LooksSealed.check(Self.passing(1024, aadLength: 0xffff)) == .aadLen)
    b = Self.passing()
    for i in 90..<102 { b[i] = 0 }
    #expect(LooksSealed.check(b) == .nonce)
    b = Self.passing()
    for i in 1008..<1024 { b[i] = 0 }
    #expect(LooksSealed.check(b) == .tag)
    b = Self.passing()
    for i in 976..<1008 { b[i] = 0 }
    #expect(LooksSealed.check(b) == .tail)
    b = Self.passing()
    b[106] = 0x1f; b[107] = 0x8b; b[108] = 0x08
    #expect(LooksSealed.check(b) == .gzip)
    b[108] = 0x09
    #expect(LooksSealed.check(b) == nil)
  }

  @Test("the check names are the Go/SQL names")
  func names() {
    #expect(LooksSealedCheck.allCases.map(\.rawValue) == ["bucket", "version", "epoch", "aad_len", "nonce", "tag", "tail", "gzip"])
  }
}

@Suite("CoreCrypto: accounts")
struct AccountTests {
  @Test("email_norm accepts", arguments: [
    ("  Maya.Rahman+Hasala@Gmail.COM ", "maya.rahman+hasala@gmail.com"),
    ("\tA@B.C\t", "a@b.c"),
    ("x@a..b", "x@a..b"),
    ("first.last@sub.example.ae", "first.last@sub.example.ae"),
  ])
  func emailAccepts(_ input: String, _ want: String) throws {
    #expect(try EmailNorm.normalize(input) == want)
  }

  @Test("email_norm refuses", arguments: [
    "maya@exämple.ae", "a@@b.c", "a@b@c.d", "a@bc", "a@.bc", "a@bc.", "a b@c.d", "@b.c", "a@", "",
    String(repeating: "a", count: 65) + "@b.c", "a@" + String(repeating: "b", count: 250) + ".cd", "a\u{0}@b.c",
  ])
  func emailRefuses(_ input: String) {
    #expect(throws: EmailNormError.badEmail) { try EmailNorm.normalize(input) }
  }

  @Test("name_ok accepts ASCII, Arabic and 64 scalars")
  func nameAccepts() {
    #expect(NameOK.check("Maya Rahman"))
    #expect(NameOK.check("مايا رحمن"))
    #expect(NameOK.check(String(repeating: "a", count: 64)))
    #expect(NameOK.check("J. O'Neil-Smith 3rd"))
  }

  @Test("name_ok refuses", arguments: [
    "", String(repeating: "a", count: 65), " Maya", "Maya ", "Maya  R", "Maya\u{202E}R", "Ma\u{200B}ya", "Maya\u{00A0}R",
    "Maya\tR",
  ])
  func nameRefuses(_ name: String) { #expect(!NameOK.check(name)) }

  @Test("the device fold, then 02's DisplayName rule")
  func displayName() throws {
    #expect(NameOK.fold("  Maya \u{00A0}\t Rahman \n") == "Maya Rahman")
    #expect(try DisplayName.validate("  Maya   R. ").get() == "Maya R.")
    #expect(try DisplayName.validate("J. Smith").get() == "J. Smith")
    #expect(try DisplayName.validate("Seán O’Brien").get() == "Seán O’Brien")
    for bad in ["maya.example", "Maya2", "a@b", "http://x", "Maya:", "'-", "Maya!"] {
      #expect(DisplayName.validate(bad) == .failure(.characters), "\(bad)")
    }
    #expect(DisplayName.validate(String(repeating: "a", count: 65)) == .failure(.length))
    #expect(DisplayName.validate("   ") == .failure(.length))
  }
}

@Suite("CoreCrypto: passwords and the reset code")
struct PasswordTests {
  static let list = PasswordPolicy.Blocklist(text: "password\r\nhasalabudgeting\n\nqwertyuiopas\n")

  @Test("length first, then the list through c and r")
  func policy() {
    #expect(PasswordPolicy.check("short", blocklist: Self.list) == .tooShort)
    #expect(PasswordPolicy.check(String(repeating: "x", count: 129), blocklist: Self.list) == .tooLong)
    #expect(PasswordPolicy.check(String(repeating: "x", count: 128), blocklist: Self.list) == nil)
    #expect(PasswordPolicy.check("Password2026!!!", blocklist: Self.list) == .tooCommon)
    #expect(PasswordPolicy.check("HasalaBudgeting1", blocklist: Self.list) == .tooCommon)
    #expect(PasswordPolicy.check("QWERTYUIOPAS", blocklist: Self.list) == .tooCommon)
    #expect(PasswordPolicy.check("password2026x", blocklist: Self.list) == nil)
    #expect(PasswordPolicy.check("correct horse battery", blocklist: Self.list) == nil)
    #expect(Self.list.count == 3)
  }

  @Test("scalars, not characters: an emoji sequence counts each scalar")
  func scalars() {
    let family = "👨‍👩‍👧‍👦"  // 7 scalars, 1 Character
    #expect(PasswordPolicy.check(family + "abcde", blocklist: Self.list) == nil)
    #expect(PasswordPolicy.check(family + "abcd", blocklist: Self.list) == .tooShort)
  }

  @Test("the stretch refuses a bad salt and an address that is not email_norm")
  func stretchGuards() {
    #expect(throws: PasswordStretch.Failure.badSalt) {
      try PasswordStretch.stretch(password: "x", serverSalt: Data(count: 31), emailNorm: "a@b.c")
    }
    #expect(throws: PasswordStretch.Failure.addressNotNormalized) {
      try PasswordStretch.stretch(password: "x", serverSalt: Data(count: 32), emailNorm: "A@b.c")
    }
  }

  @Test("NFC and NFD spellings stretch to the same S")
  func nfc() throws {
    let a = try PasswordStretch.stretch(password: "café passw0rd!", serverSalt: Data(count: 32), emailNorm: "a@b.c")
    let b = try PasswordStretch.stretch(password: "cafe\u{301} passw0rd!", serverSalt: Data(count: 32), emailNorm: "a@b.c")
    #expect(a.withUnsafeBytes { Data($0) } == b.withUnsafeBytes { Data($0) })
  }
}

@Suite("CoreCrypto: step-up")
struct StepUpTests {
  @Test("20 actions, matching the grammar, ≤ 48 bytes; the binding proof kinds")
  func actions() {
    #expect(StepUpParams.actions.count == 20 && Set(StepUpParams.actions).count == 20)
    for a in StepUpParams.actions {
      #expect(a.utf8.count <= 48)
      let parts = a.split(separator: ".", omittingEmptySubsequences: false)
      #expect(parts.count >= 2 && parts.allSatisfy { p in
        guard let f = p.utf8.first, (0x61...0x7a).contains(f) else { return false }
        return p.utf8.allSatisfy { (0x61...0x7a).contains($0) || (0x30...0x39).contains($0) || $0 == 0x5f }
      }, "\(a)")
    }
    #expect(StepUpParams.passwordReset(newVerifierHash: Data(count: 32)).proofKinds == [.deviceCode])
    #expect(StepUpParams.phraseView.proofKinds == [.passkey])
    #expect(StepUpParams.keysWrapPut(credentialID: Data(count: 16)).proofKinds == [.passkey])
    #expect(StepUpParams.writerRevoke(testWriter).proofKinds == [.passkey, .device])
  }

  @Test("the empty tuple encodes to zero bytes; the email tuple's empty field is a zero length")
  func tuples() {
    #expect(StepUp.encode([]).isEmpty)
    let t = StepUpParams.emailChange(newEmailNorm: "a@b.c", newVerifierHash: nil).tuple
    #expect(StepUp.encode(t).suffix(4) == Data([0, 0, 0, 0]))
  }

  @Test("a challenge for another action, params or nonce does not match (AT-C9)")
  func mismatch() throws {
    let n = Data(repeating: 7, count: 32)
    let c = try StepUp.challenge(nonce: n, params: .sessionLogoutAll)
    #expect(StepUp.serverChallengeMatches(c, nonce: n, params: .sessionLogoutAll))
    #expect(!StepUp.serverChallengeMatches(c, nonce: n, params: .mailboxUnlink))
    #expect(!StepUp.serverChallengeMatches(c, nonce: Data(repeating: 8, count: 32), params: .sessionLogoutAll))
    #expect(throws: SigningMessageError.self) { try StepUp.challenge(nonce: Data(count: 31), params: .phraseView) }
    // The 32-byte tuple fields are length-checked before C is computed.
    for p: StepUpParams in [
      .keysBootstrap(authorityPublicKey: Data(count: 31)), .keysRecoveryRotate(newRecoveryPublicKey: Data(count: 33)),
      .passwordSet(newVerifierHash: Data()), .passwordChange(newVerifierHash: Data(count: 31)),
      .passwordReset(newVerifierHash: Data(count: 64)), .emailChange(newEmailNorm: "a@example.com", newVerifierHash: Data(count: 1)),
    ] {
      #expect(throws: SigningMessageError.self, "\(p.action)") { try StepUp.challenge(nonce: n, params: p) }
      #expect(!StepUp.serverChallengeMatches(c, nonce: n, params: p))
    }
    _ = try StepUp.challenge(nonce: n, params: .emailChange(newEmailNorm: "a@example.com", newVerifierHash: nil))
    _ = try StepUp.challenge(nonce: n, params: .passwordSet(newVerifierHash: Data(count: 32)))
  }
}

@Suite("CoreCrypto: DAK checks")
struct DAKTests {
  @Test("software P-256 signatures verify; r or s of 0 or ≥ n, other messages and other keys do not")
  func verify() throws {
    let k = P256.Signing.PrivateKey()
    let pub = k.publicKey.x963Representation
    let m = try SigningMessage.deviceStepUp(challenge: Data(repeating: 1, count: 32), writerID: testWriter)
    let sig = try k.signature(for: m).rawRepresentation
    #expect(DAK.verify(publicKey: pub, signature: sig, message: m))
    #expect(!DAK.verify(publicKey: pub, signature: sig, message: m + [0]))
    #expect(!DAK.verify(publicKey: P256.Signing.PrivateKey().publicKey.x963Representation, signature: sig, message: m))
    var zeroR = sig
    zeroR.replaceSubrange(0..<32, with: Data(count: 32))
    #expect(!DAK.verify(publicKey: pub, signature: zeroR, message: m))
    var bigS = sig
    bigS.replaceSubrange(32..<64, with: Data(DAK.order))
    #expect(!DAK.verify(publicKey: pub, signature: bigS, message: m))
    #expect(DAK.inRange(DAK.order.enumerated().map { $0.offset == 31 ? $0.element - 1 : $0.element }))
  }

  @Test("public keys: compressed, off-curve and (0,0) are refused")
  func keys() {
    let k = P256.Signing.PrivateKey().publicKey
    #expect(DAK.isValidPublicKey(k.x963Representation))
    #expect(!DAK.isValidPublicKey(k.compressedRepresentation))
    #expect(!DAK.isValidPublicKey(Data([4]) + Data(count: 64)))
    var off = k.x963Representation
    off[64] ^= 1
    #expect(!DAK.isValidPublicKey(off))
  }
}
