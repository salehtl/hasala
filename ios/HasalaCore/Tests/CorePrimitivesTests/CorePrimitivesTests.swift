// CorePrimitives against published vectors and the TypeScript seam's contract
// tables (reference/ledgerd-client/src/platform.test.ts), ported case for case
// where the case is a property of the primitive rather than of Node or Bun.
import CryptoKit
import Foundation
import Testing

@testable import CorePrimitives

private func hex(_ s: String) -> Data { try! Hex.decode(s) }
private func utf8(_ s: String) -> Data { Data(s.utf8) }

@Suite("sha256 and hmac")
struct HashingTests {
  @Test("FIPS 180-2 vectors, including a million 'a'")
  func sha256Vectors() {
    #expect(Hex.encode(sha256(Data())) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    #expect(Hex.encode(sha256(utf8("abc"))) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    #expect(
      Hex.encode(sha256(Data(repeating: 0x61, count: 1_000_000)))
        == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    #expect(sha256(utf8("abc")).count == 32)
  }

  @Test("RFC 4231 HMAC-SHA-256 test cases 1 and 2")
  func hmacVectors() {
    #expect(
      Hex.encode(hmacSHA256(key: Data(repeating: 0x0b, count: 20), message: utf8("Hi There")))
        == "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
    #expect(
      Hex.encode(hmacSHA256(key: utf8("Jefe"), message: utf8("what do ya want for nothing?")))
        == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
  }

  @Test("RFC 5869 HKDF-SHA-256 test case 1, and the output bound")
  func hkdfVectors() throws {
    let okm = try hkdfSHA256(
      inputKeyMaterial: Data(repeating: 0x0b, count: 22), salt: Data(0x00...0x0c), info: Data(0xf0...0xf9),
      outputByteCount: 42)
    #expect(
      Hex.encode(okm)
        == "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865")
    #expect(throws: PrimitivesError.self) {
      try hkdfSHA256(inputKeyMaterial: Data(count: 32), salt: Data(), info: Data(), outputByteCount: 0)
    }
    #expect(throws: PrimitivesError.self) {
      try hkdfSHA256(inputKeyMaterial: Data(count: 32), salt: Data(), info: Data(), outputByteCount: 255 * 32 + 1)
    }
  }

  @Test("PBKDF2-HMAC-SHA256 (RFC 7914 §11 vectors, and 32-byte output)")
  func pbkdf2Vectors() throws {
    let a = try PBKDF2.sha256(password: utf8("passwd"), salt: utf8("salt"), iterations: 1, outputByteCount: 64)
    #expect(
      a.withUnsafeBytes { Hex.encode($0) }
        == "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783"
    )
    let b = try PBKDF2.sha256(password: utf8("password"), salt: utf8("salt"), iterations: 4096)
    #expect(b.count == 32)
    #expect(b.withUnsafeBytes { Hex.encode($0) } == "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a")
    #expect(throws: PrimitivesError.self) { try PBKDF2.sha256(password: utf8("p"), salt: utf8("s"), iterations: 0) }
  }
}

@Suite("aes-256-gcm")
struct AESGCMTests {
  @Test("the published all-zero AES-256 cases; output is ciphertext ‖ tag")
  func zeroVectors() throws {
    let zeroKey = Data(count: 32)
    let zeroIV = Data(count: 12)
    #expect(
      Hex.encode(try AESGCM.seal(key: zeroKey, nonce: zeroIV, aad: Data(), plaintext: Data()))
        == "530f8afbc74536b9a963b4f1c4cb738b")
    #expect(
      Hex.encode(try AESGCM.seal(key: zeroKey, nonce: zeroIV, aad: Data(), plaintext: Data(count: 16)))
        == "cea7403d4d606b6e074ec5d3baf39d18d0d1c8a799996bf0265b98b5d48ab919")
  }

  @Test("round-trips with associated data")
  func roundTrip() throws {
    let key = try SystemRandom().bytes(32)
    let nonce = try SystemRandom().bytes(12)
    let sealed = try AESGCM.seal(key: key, nonce: nonce, aad: utf8("hasala-aad"), plaintext: utf8("the private half"))
    #expect(sealed.count == 16 + 16)
    #expect(try AESGCM.open(key: key, nonce: nonce, aad: utf8("hasala-aad"), sealed: sealed) == utf8("the private half"))
  }

  @Test("a wrong key, nonce, aad or tag is one rejection, never a wrong plaintext")
  func rejections() throws {
    let r = SystemRandom()
    let key = try r.bytes(32)
    let nonce = try r.bytes(12)
    let sealed = try AESGCM.seal(key: key, nonce: nonce, aad: utf8("aad"), plaintext: utf8("secret"))
    var flipped = sealed
    flipped[flipped.count - 1] ^= 1
    for attempt: () throws -> Data in [
      { try AESGCM.open(key: try r.bytes(32), nonce: nonce, aad: utf8("aad"), sealed: sealed) },
      { try AESGCM.open(key: key, nonce: try r.bytes(12), aad: utf8("aad"), sealed: sealed) },
      { try AESGCM.open(key: key, nonce: nonce, aad: utf8("aad!"), sealed: sealed) },
      { try AESGCM.open(key: key, nonce: nonce, aad: utf8("aad"), sealed: flipped) },
      { try AESGCM.open(key: key, nonce: nonce, aad: utf8("aad"), sealed: Data(count: 15)) },
    ] {
      #expect(throws: PrimitivesError.authenticationFailed) { try attempt() }
    }
  }

  @Test("a key that is not 32 bytes, or a nonce that is not 12, is refused")
  func lengths() {
    #expect(throws: PrimitivesError.self) {
      try AESGCM.seal(key: Data(count: 16), nonce: Data(count: 12), aad: Data(), plaintext: Data())
    }
    #expect(throws: PrimitivesError.self) {
      try AESGCM.seal(key: Data(count: 32), nonce: Data(count: 16), aad: Data(), plaintext: Data())
    }
    #expect(throws: PrimitivesError.self) {
      try AESGCM.open(key: Data(count: 24), nonce: Data(count: 12), aad: Data(), sealed: Data(count: 32))
    }
  }
}

@Suite("ed25519 and p-256")
struct SignatureTests {
  // RFC 8032 §7.1 TEST 1 and TEST 2: published seeds, public keys and signatures.
  let rfc8032Test1Seed = hex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
  let rfc8032Test1Public = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"
  let rfc8032Test1Signature = hex(
    "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155"
      + "5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b")
  let rfc8032Test2Seed = hex("4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb")
  let rfc8032Test2Public = "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c"
  let rfc8032Test2Signature = hex(
    "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da"
      + "085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00")

  @Test("derives the RFC 8032 public keys from their seeds")
  func publicKeys() throws {
    #expect(Hex.encode(try Ed25519.publicKey(seed: rfc8032Test1Seed)) == rfc8032Test1Public)
    #expect(Hex.encode(try Ed25519.publicKey(seed: rfc8032Test2Seed)) == rfc8032Test2Public)
  }

  @Test("the published (deterministic) RFC 8032 signatures verify")
  func publishedSignaturesVerify() {
    #expect(Ed25519.verify(publicKey: hex(rfc8032Test1Public), signature: rfc8032Test1Signature, message: Data()))
    #expect(Ed25519.verify(publicKey: hex(rfc8032Test2Public), signature: rfc8032Test2Signature, message: hex("72")))
    #expect(!Ed25519.verify(publicKey: hex(rfc8032Test2Public), signature: rfc8032Test2Signature, message: hex("73")))
  }

  // CryptoKit signs with randomness: never compare signature bytes (spec 01
  // §1). What is pinned is that every signature verifies, under the RFC key.
  @Test("CryptoKit's signatures verify, and are not compared byte for byte")
  func signThenVerify() throws {
    let msg = utf8("hasala-writer-registration")
    let a = try Ed25519.sign(seed: rfc8032Test1Seed, message: msg)
    let b = try Ed25519.sign(seed: rfc8032Test1Seed, message: msg)
    #expect(a.count == 64 && b.count == 64)
    #expect(Ed25519.verify(publicKey: hex(rfc8032Test1Public), signature: a, message: msg))
    #expect(Ed25519.verify(publicKey: hex(rfc8032Test1Public), signature: b, message: msg))
    #expect(!Ed25519.verify(publicKey: hex(rfc8032Test2Public), signature: a, message: msg))
    var tampered = a
    tampered[0] ^= 1
    #expect(!Ed25519.verify(publicKey: hex(rfc8032Test1Public), signature: tampered, message: msg))
  }

  @Test("a generated pair is consistent, and two pairs differ")
  func generated() throws {
    let (seed, pub) = Ed25519.generate()
    #expect(seed.count == 32 && pub.count == 32)
    #expect(try Ed25519.publicKey(seed: seed) == pub)
    #expect(Ed25519.generate().publicKey != pub)
  }

  @Test("a seed that is not 32 bytes is refused; malformed keys verify false")
  func lengths() {
    #expect(throws: PrimitivesError.self) { try Ed25519.publicKey(seed: Data(count: 31)) }
    #expect(throws: PrimitivesError.self) { try Ed25519.sign(seed: Data(count: 33), message: Data()) }
    #expect(!Ed25519.verify(publicKey: Data(count: 31), signature: rfc8032Test1Signature, message: Data()))
    #expect(!Ed25519.verify(publicKey: hex(rfc8032Test1Public), signature: Data(count: 63), message: Data()))
  }

  @Test("P-256 verify-only: a fresh CryptoKit signature verifies; a wrong message does not")
  func p256() throws {
    // Key generation here stands in for the Secure Enclave / CoreSoftAuth signer.
    let signer = P256Testing.newSigner()
    let msg = utf8("hasala/v1/reset-approve")
    let sig = try signer.sign(msg)
    #expect(P256Verify.verify(publicKeyX963: signer.publicKeyX963, signatureRaw: sig, message: msg))
    #expect(!P256Verify.verify(publicKeyX963: signer.publicKeyX963, signatureRaw: sig, message: utf8("other")))
    #expect(!P256Verify.verify(publicKeyX963: signer.publicKeyX963.dropLast(), signatureRaw: sig, message: msg))
  }
}

@Suite("hex, base64, base64url, base32")
struct CodecTests {
  @Test("hex: leading zero survives, lower case, full byte range, empty")
  func hexRoundTrip() throws {
    #expect(Hex.encode([0x00, 0x0f, 0xff]) == "000fff")
    #expect(Hex.encode([0xab, 0xcd, 0xef]) == "abcdef")
    let all = Data(0...255)
    let s = Hex.encode(all)
    #expect(s.utf8.count == 512 && s.hasPrefix("000102") && s.hasSuffix("fdfeff"))
    #expect(try Hex.decode(s) == all)
    #expect(Hex.encode([]) == "")
    #expect(try Hex.decode("") == Data())
  }

  @Test("hex: odd length, non-hex, whitespace and upper case are refused, never truncated", arguments: [
    "abc", "00zz11", "0011 22", "AABB", "0g", "\u{0660}\u{0661}",
  ])
  func hexRefusals(_ s: String) {
    #expect(throws: CodecError.notHex) { try Hex.decode(s) }
  }

  @Test("base64: padding lengths, the + and / characters, full range, empty")
  func base64RoundTrip() throws {
    #expect(Base64.encode([0x00, 0xff]) == "AP8=")
    #expect(try Base64.decode("AP8=") == Data([0x00, 0xff]))
    #expect(Base64.encode(utf8("a")) == "YQ==" && Base64.encode(utf8("ab")) == "YWI=" && Base64.encode(utf8("abc")) == "YWJj")
    #expect(try Base64.decode("YQ==") == utf8("a"))
    #expect(try Base64.decode("YWI=") == utf8("ab"))
    #expect(try Base64.decode("YWJj") == utf8("abc"))
    #expect(Base64.encode([0xff, 0xef, 0xbf]) == "/++/")
    let all = Data(0...255)
    #expect(try Base64.decode(Base64.encode(all)) == all)
    #expect(Base64.encode([]) == "")
    #expect(try Base64.decode("") == Data())
  }

  @Test("base64: outside the alphabet, bad length, misplaced padding are refused", arguments: [
    "YW Jj", "YWJ\n", "-_-_", "YWJj*", "YWJja", "YQ==YQ==", "Y===", "====", "=AAA", "AB=C",
  ])
  func base64Refusals(_ s: String) {
    #expect(throws: CodecError.notBase64) { try Base64.decode(s) }
  }

  @Test("base64: non-zero unused bits decode as Node, atob and Go decode them")
  func base64LenientTail() throws {
    #expect(try Base64.decode("YR==") == utf8("a"))
    #expect(try Base64.decode("YWJ=") == utf8("ab"))
  }

  @Test("base64url: URL alphabet, optional padding, empty")
  func base64URL() throws {
    #expect(try Base64.decodeURL("_--_") == Data([0xff, 0xef, 0xbf]))
    #expect(throws: CodecError.notBase64) { try Base64.decode("_--_") }
    #expect(try Base64.decodeURL("AP8") == Data([0x00, 0xff]))
    #expect(try Base64.decodeURL("AP8=") == Data([0x00, 0xff]))
    #expect(try Base64.decodeURL("QQ") == utf8("A"))
    #expect(try Base64.decodeURL("QUI") == utf8("AB"))
    #expect(try Base64.decodeURL("") == Data())
    let all = Data(0...255)
    #expect(try Base64.decodeURL(Base64.encodeURL(all)) == all)
    #expect(Base64.encodeURL([0xff, 0xef, 0xbf, 0x00]) == "_--_AA")
  }

  @Test("base64url: +/, junk, whitespace, one leftover character, misplaced padding are refused", arguments: [
    "+/+/", "AP8/", "a+b", "AP8*", "A A", "QQ\n", "A", "AAAAA", "AB=C", "=AAA",
  ])
  func base64URLRefusals(_ s: String) {
    #expect(throws: CodecError.notBase64URL) { try Base64.decodeURL(s) }
  }

  @Test("base64url: padding that does not match the body length is refused", arguments: ["AP8==", "QQ="])
  func base64URLPadding(_ s: String) {
    #expect(throws: CodecError.base64URLPadding) { try Base64.decodeURL(s) }
  }

  @Test("base32: RFC 4648 §6 upper case, unpadded; spec 01 A25's code80")
  func base32() throws {
    #expect(Base32.encode(hex("d2e8838f66d3baba34ce")) == "2LUIHD3G2O5LUNGO")
    #expect(try Base32.decode("2LUIHD3G2O5LUNGO") == hex("d2e8838f66d3baba34ce"))
    let expected = ["", "AE", "AEBA", "AEBAG", "AEBAGBA", "AEBAGBAF"]
    for n in 0...5 {
      let bytes = Data((0..<n).map { UInt8($0 + 1) })
      #expect(Base32.encode(bytes) == expected[n])
      #expect(try Base32.decode(expected[n]) == bytes)
    }
    for bad in ["A", "AEB", "AEBAGB", "ae", "AE=", "AE1", "AF"] {
      #expect(throws: CodecError.notBase32) { try Base32.decode(bad) }
    }
  }
}

@Suite("utf-8 (WHATWG)")
struct UTF8Tests {
  @Test("encodes and decodes ASCII, 2-, 3- and 4-byte scalars and Arabic")
  func roundTrip() {
    #expect(UTF8Text.encode("hello") == [104, 101, 108, 108, 111])
    #expect(UTF8Text.encode("é") == [0xc3, 0xa9])
    #expect(UTF8Text.encode("€") == [0xe2, 0x82, 0xac])
    #expect(UTF8Text.encode("\u{1D11E}") == [0xf0, 0x9d, 0x84, 0x9e])
    #expect(UTF8Text.decode([0xf0, 0x9d, 0x84, 0x9e]) == "\u{1D11E}")
    #expect(UTF8Text.decode(UTF8Text.encode("مرحبا")) == "مرحبا")
  }

  @Test("invalid bytes become U+FFFD per maximal subpart, never a throw")
  func replacement() {
    #expect(UTF8Text.decode([0x61, 0xff, 0x62]) == "a\u{FFFD}b")
    #expect(UTF8Text.decode([0xc3]) == "\u{FFFD}")
    // A truncated 4-byte sequence is ONE maximal subpart (WHATWG), a surrogate
    // encoded in UTF-8 is three.
    #expect(UTF8Text.decode([0xf0, 0x9f, 0x98, 0x61]) == "\u{FFFD}a")
    #expect(UTF8Text.decode([0xed, 0xa0, 0x80]) == "\u{FFFD}\u{FFFD}\u{FFFD}")
    #expect(UTF8Text.decode([0xc0, 0xaf]) == "\u{FFFD}\u{FFFD}")
  }

  @Test("one leading BOM is stripped; a later one, or a second, is kept")
  func bom() {
    #expect(UTF8Text.decode([0xef, 0xbb, 0xbf, 0x61]) == "a")
    #expect(UTF8Text.decode([0x61, 0xef, 0xbb, 0xbf, 0x62]) == "a\u{FEFF}b")
    #expect(UTF8Text.decode([0xef, 0xbb, 0xbf, 0xef, 0xbb, 0xbf]) == "\u{FEFF}")
  }
}

@Suite("gzip")
struct GzipTests {
  @Test("round-trips and emits the gzip magic, at level 9 with mtime 0")
  func roundTrip() throws {
    let plain = utf8(String(repeating: "the quick brown fox", count: 50))
    let z = try Gzip.compress(plain)
    #expect(z[0] == 0x1f && z[1] == 0x8b && z[2] == 0x08)
    #expect(z[4..<8].allSatisfy { $0 == 0 })  // mtime 0: deterministic
    #expect(z[8] == 0x02)  // XFL 2: maximum compression
    #expect(try Gzip.decompress(z, maxOutputBytes: 1 << 20) == plain)
    #expect(try Gzip.decompress(try Gzip.compress(Data()), maxOutputBytes: 1024) == Data())
    let all = Data(0...255)
    #expect(try Gzip.decompress(try Gzip.compress(all), maxOutputBytes: 1024) == all)
    #expect(try Gzip.compress(plain) == z)
  }

  @Test("a gzip bomb is refused at the cap")
  func bomb() throws {
    let bomb = try Gzip.compress(Data(count: 4 << 20))
    #expect(bomb.count < 64 * 1024)
    #expect(throws: GzipError.overCap(1024)) { try Gzip.decompress(bomb, maxOutputBytes: 1024) }
  }

  // The bomb test proves the cap throws; this proves it throws DURING
  // inflation. Same approach as platform.test.ts: the capped path against the
  // same implementation inflating the same bomb uncapped, so machine speed
  // cancels out. Inflate-then-measure would be no cheaper at all.
  @Test("the cap is enforced during inflation, not after it")
  func capIsEarly() throws {
    let n = 32 << 20
    let bomb = try Gzip.compress(Data(count: n))
    func best(_ f: () -> Void) -> Duration {
      var b = Duration.seconds(1000)
      for _ in 0..<3 {
        let t = ContinuousClock.now
        f()
        b = min(b, ContinuousClock.now - t)
      }
      return b
    }
    let capped = best { _ = try? Gzip.decompress(bomb, maxOutputBytes: 1024) }
    let full = best { _ = try? Gzip.decompress(bomb, maxOutputBytes: n + 1) }
    #expect(capped * 4 < full)
  }

  @Test("the cap is exact")
  func exactCap() throws {
    let z = try Gzip.compress(Data(repeating: 0x41, count: 1000))
    #expect(try Gzip.decompress(z, maxOutputBytes: 1000).count == 1000)
    #expect(throws: GzipError.overCap(999)) { try Gzip.decompress(z, maxOutputBytes: 999) }
  }

  @Test("truncated, corrupt, trailing-garbage and non-gzip input are refused")
  func refusals() throws {
    let z = try Gzip.compress(utf8(String(repeating: "hello world", count: 100)))
    #expect(throws: GzipError.self) { try Gzip.decompress(z.prefix(z.count - 8), maxOutputBytes: 1 << 20) }
    #expect(throws: GzipError.truncated) { try Gzip.decompress(z.prefix(10), maxOutputBytes: 1 << 20) }
    #expect(throws: GzipError.truncated) { try Gzip.decompress(Data(), maxOutputBytes: 1024) }
    var crc = z
    crc[crc.count - 6] ^= 0xff  // inside the CRC-32 trailer
    #expect(throws: GzipError.corrupt) { try Gzip.decompress(crc, maxOutputBytes: 1 << 20) }
    #expect(throws: GzipError.trailingData) { try Gzip.decompress(z + Data([0x00]), maxOutputBytes: 1 << 20) }
    #expect(throws: GzipError.trailingData) { try Gzip.decompress(z + z, maxOutputBytes: 1 << 20) }
    #expect(throws: GzipError.corrupt) { try Gzip.decompress(utf8("not gzip at all"), maxOutputBytes: 1024) }
  }
}

@Suite("randomness, SecureBytes, constant-time compare")
struct MiscTests {
  @Test("bytes are the requested length and not all zero; UUIDs are lower-case v4")
  func random() throws {
    let r = SystemRandom()
    #expect(try r.bytes(0).isEmpty)
    let b = try r.bytes(64)
    #expect(b.count == 64 && b.contains { $0 != 0 })
    let u = try r.uuidV4()
    let parts = u.split(separator: "-").map(\.count)
    #expect(parts == [8, 4, 4, 4, 12])
    #expect(u.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) || $0 == 0x2d })
    #expect(Array(u.utf8)[14] == 0x34)  // version 4
    #expect([0x38, 0x39, 0x61, 0x62].contains(Array(u.utf8)[19]))  // variant 10xx
    #expect(try r.uuidV4() != u)
  }

  @Test("SecureBytes never describes its content, and wipes")
  func secureBytes() {
    let s = SecureBytes(copying: Data([1, 2, 3]))
    #expect(s.description == "<redacted>" && "\(s)" == "<redacted>" && String(reflecting: s) == "<redacted>")
    #expect(s.withUnsafeBytes { Array($0) } == [1, 2, 3])
    s.wipe()
    #expect(s.withUnsafeBytes { Array($0) } == [0, 0, 0])
    #expect(SecureBytes(count: 0).count == 0)
  }

  @Test("constant-time equality")
  func ctEquals() {
    #expect(constantTimeEquals(Data([1, 2, 3]), Data([1, 2, 3])))
    #expect(!constantTimeEquals(Data([1, 2, 3]), Data([1, 2, 4])))
    #expect(!constantTimeEquals(Data([1, 2, 3]), Data([1, 2])))
    #expect(constantTimeEquals(Data(), Data()))
  }
}

/// A software P-256 signer standing in for the Secure Enclave key (tests only).
enum P256Testing {
  struct Signer {
    let key = P256.Signing.PrivateKey()
    var publicKeyX963: Data { key.publicKey.x963Representation }
    func sign(_ message: Data) throws -> Data { try key.signature(for: message).rawRepresentation }
  }

  static func newSigner() -> Signer { Signer() }
}
