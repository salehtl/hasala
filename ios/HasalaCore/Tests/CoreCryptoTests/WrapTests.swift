// Spec 01 §15.3's wrap cases W01-W13 (§5.4's order and error policy).
import CorePrimitives
import CoreWire
import Foundation
import Testing

@testable import CoreCrypto

struct WrapFixture {
  let entropy = try! Hex.decode("9e885d952ad362caeb4efe34a8e91bd2")
  let prf = Data(0xc0...0xdf)
  let credential = Data(0x01...0x10)
  let body = try! KeyBody(amk: Data(0x40...0x5f), aakSeed: Data(0x60...0x7f))
  let random = StreamRandom(seed: "wraps")

  var published: PublishedAccountKeys {
    PublishedAccountKeys(
      userID: testUser, recoveryPublicKey: try! KeyDerivation.recoveryPublicKey(entropy: entropy),
      amkCommitment: try! body.amkCommitment(userID: testUser), authorityPublicKey: try! body.authorityPublicKey())
  }

  func recoveryWrap() throws -> Data { try Wrap.sealRecovery(body: body, entropy: entropy, userID: testUser, random: random) }
  func prfWrap() throws -> Data {
    try Wrap.sealPRF(body: body, prfOutput: prf, userID: testUser, credentialID: credential, random: random)
  }
  func box() throws -> Data {
    try PhraseBox.seal(
      entropy: entropy, amk: body.amk, userID: testUser, recoveryPublicKey: published.recoveryPublicKey, random: random)
  }
}

@Suite("spec 01 §15.3: wrap cases")
struct WrapTests {
  let f = WrapFixture()

  func flipped(_ d: Data, _ i: Int) -> Data {
    var c = d
    c[i] ^= 0x01
    return c
  }

  @Test("W01 a recovery wrap opens with E and the commitments match; a PRF wrap opens with P")
  func w01() throws {
    let w = try f.recoveryWrap()
    #expect(w.count == 127 && w[0] == 1 && w[1] == 1)
    let body = try AccountUnlock.withPhrase(entropy: f.entropy, recoveryWrap: w, published: f.published)
    #expect(body.amk.withUnsafeBytes { Data($0) } == Data(0x40...0x5f))
    let p = try f.prfWrap()
    #expect(p[1] == 2)
    _ = try AccountUnlock.withPRF(prfOutput: f.prf, credentialID: f.credential, prfWrap: p, published: f.published)
  }

  @Test("W02 every header byte; W03 ciphertext and tag bytes")
  func w02w03() throws {
    let w = try f.recoveryWrap()
    for i in Array(0..<46) + [46, 78, 110, 111] + Array(111..<127) {
      #expect(throws: UnwrapError.unwrapFailed, "byte \(i)") {
        try AccountUnlock.withPhrase(entropy: f.entropy, recoveryWrap: flipped(w, i), published: f.published)
      }
    }
  }

  @Test("W04 another user in the AD; W05 another credential; W07 another P")
  func w04w05w07() throws {
    let w = try f.recoveryWrap()
    let other = UserID("0f1e2d3c-4b5a-4968-8776-655443322110")!
    #expect(throws: UnwrapError.unwrapFailed) { try Wrap.openRecovery(w, entropy: f.entropy, userID: other) }
    let p = try f.prfWrap()
    #expect(throws: UnwrapError.unwrapFailed) {
      try Wrap.openPRF(p, prfOutput: f.prf, userID: testUser, credentialID: Data(0x02...0x11))
    }
    #expect(throws: UnwrapError.unwrapFailed) {
      try Wrap.openPRF(p, prfOutput: Data(repeating: 1, count: 32), userID: testUser, credentialID: f.credential)
    }
  }

  @Test("W06 another valid phrase: notThisAccountsPhrase, before any unwrap")
  func w06() throws {
    #expect(throws: UnwrapError.notThisAccountsPhrase) {
      try AccountUnlock.withPhrase(entropy: Data(repeating: 0x80, count: 16), recoveryWrap: Data(), published: f.published)
    }
  }

  @Test("W08 126 or 128 bytes, kdf 0x02 in a recovery wrap, body version 0x02")
  func w08() throws {
    let w = try f.recoveryWrap()
    #expect(throws: UnwrapError.unwrapFailed) { try Wrap.openRecovery(w.prefix(126), entropy: f.entropy, userID: testUser) }
    #expect(throws: UnwrapError.unwrapFailed) { try Wrap.openRecovery(w + [0], entropy: f.entropy, userID: testUser) }
    let p = try f.prfWrap()
    #expect(throws: UnwrapError.unwrapFailed) { try Wrap.openRecovery(p, entropy: f.entropy, userID: testUser) }
    // A wrap whose sealed body has version 0x02.
    let salt = Data(repeating: 5, count: 32)
    let nonce = Data(repeating: 6, count: 12)
    let header = Data([1, 1]) + salt + nonce
    let key = try KeyDerivation.recoveryWrapKey(entropy: f.entropy, salt: salt)
    let bad = Data([2]) + Data(0x40...0x5f) + Data(0x60...0x7f)
    let ad = Wrap.associatedData(header: header, userID: testUser, credentialID: nil)
    let w2 = header + (try AESGCM.seal(key: key, nonce: nonce, aad: ad, plaintext: bad))
    #expect(throws: UnwrapError.unwrapFailed) { try Wrap.openRecovery(w2, entropy: f.entropy, userID: testUser) }
  }

  @Test("W09 an AMK that is not the committed one; W10 an AAK that is not the published one")
  func w09w10() throws {
    let other = try KeyBody(amk: Data(repeating: 1, count: 32), aakSeed: Data(0x60...0x7f))
    let w = try Wrap.sealRecovery(body: other, entropy: f.entropy, userID: testUser, random: f.random)
    #expect(throws: UnwrapError.accountKeysMismatch) {
      try AccountUnlock.withPhrase(entropy: f.entropy, recoveryWrap: w, published: f.published)
    }
    let otherAAK = try KeyBody(amk: Data(0x40...0x5f), aakSeed: Data(repeating: 2, count: 32))
    let w2 = try Wrap.sealPRF(
      body: otherAAK, prfOutput: f.prf, userID: testUser, credentialID: f.credential, random: f.random)
    #expect(throws: UnwrapError.accountKeysMismatch) {
      try AccountUnlock.withPRF(prfOutput: f.prf, credentialID: f.credential, prfWrap: w2, published: f.published)
    }
  }

  @Test("W11 phrase box: header and tag bytes, 44 or 46 bytes; W12 another user or recovery key in the AD")
  func w11w12() throws {
    let b = try f.box()
    let rk = f.published.recoveryPublicKey
    #expect(b.count == 45)
    #expect(try PhraseBox.open(b, amk: f.body.amk, userID: testUser, recoveryPublicKey: rk).withUnsafeBytes { Data($0) } == f.entropy)
    for i in Array(0..<13) + Array(29..<45) {
      #expect(throws: UnwrapError.unwrapFailed, "byte \(i)") {
        try PhraseBox.open(flipped(b, i), amk: f.body.amk, userID: testUser, recoveryPublicKey: rk)
      }
    }
    #expect(throws: UnwrapError.unwrapFailed) { try PhraseBox.open(b.prefix(44), amk: f.body.amk, userID: testUser, recoveryPublicKey: rk) }
    #expect(throws: UnwrapError.unwrapFailed) { try PhraseBox.open(b + [0], amk: f.body.amk, userID: testUser, recoveryPublicKey: rk) }
    let other = UserID("0f1e2d3c-4b5a-4968-8776-655443322110")!
    #expect(throws: UnwrapError.unwrapFailed) { try PhraseBox.open(b, amk: f.body.amk, userID: other, recoveryPublicKey: rk) }
    #expect(throws: UnwrapError.unwrapFailed) {
      try PhraseBox.open(b, amk: f.body.amk, userID: testUser, recoveryPublicKey: Data(repeating: 1, count: 32))
    }
  }

  @Test("W13 a box that opens to another phrase: phraseBoxMismatch")
  func w13() throws {
    let rk = f.published.recoveryPublicKey
    // Built for another phrase, with this account's recovery key in its AD.
    let forged = try PhraseBox.seal(
      entropy: Data(repeating: 0x80, count: 16), amk: f.body.amk, userID: testUser, recoveryPublicKey: rk,
      nonce: Data(repeating: 4, count: 12))
    #expect(throws: UnwrapError.phraseBoxMismatch) {
      try PhraseBox.open(forged, amk: f.body.amk, userID: testUser, recoveryPublicKey: rk)
    }
  }

  @Test("the body encodes to 65 bytes; seal refuses a short credential id")
  func body() throws {
    let e = f.body.encoded()
    #expect(e.count == 65 && e.withUnsafeBytes { $0[0] } == 1)
    #expect(throws: PrimitivesError.self) {
      try Wrap.sealPRF(body: f.body, prfOutput: f.prf, userID: testUser, credentialID: Data(count: 15), random: f.random)
    }
  }
}
