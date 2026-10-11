// Unit tests for CoreSoftAuth (owner: WS-11). So far: the software approval key,
// which must have the Secure Enclave key's byte formats (spec 01 §4.9).
import CoreAuth
import CoreCrypto
import CorePrimitives
import Foundation
import Testing

@testable import CoreSoftAuth

@Suite("CoreSoftAuth: software approval key")
struct SoftwareApprovalKeyTests {
  let user = UserID("6f1c2b9e-4d3a-4f5b-8c7d-0e1f2a3b4c5d")!
  let writer = WriterID("ios-0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d")!

  @Test("create → a 65-byte X9.63 key; sign → 64-byte r ‖ s that DAK.verify accepts")
  func signs() async throws {
    let s = SoftwareApprovalKeySigner()
    let pub = try await s.create(userID: user, writerID: writer)
    #expect(pub.count == 65 && pub.first == 0x04 && DAK.isValidPublicKey(pub))
    #expect(try s.publicKeyX963(userID: user, writerID: writer) == pub)
    let m = try SigningMessage.deviceFreeze(nonce: Data(repeating: 1, count: 32), userID: user, writerID: writer)
    let sig = try await s.sign(m, userID: user, writerID: writer, reason: "Freeze your account")
    #expect(sig.count == 64)
    #expect(DAK.verify(publicKey: pub, signature: sig, message: m))
    #expect(s.signatureCount == 1)
  }

  @Test("a fixed scalar gives spec 01 A13's public key")
  func fixedScalar() throws {
    let s = SoftwareApprovalKeySigner()
    try s.install(privateScalar: Data(0x01...0x20), userID: user, writerID: writer)
    #expect(
      Hex.encode(try s.publicKeyX963(userID: user, writerID: writer))
        == "04515c3d6eb9e396b904d3feca7f54fdcd0cc1e997bf375dca515ad0a6c3b4035f4536be3a50f318fbf9a5475902a221502bef0d57e08c53b2cc0a56f17d9f9354"
    )
  }

  @Test("a missing key, a cancelled prompt and a removed key")
  func failures() async throws {
    let s = SoftwareApprovalKeySigner()
    #expect(throws: ApprovalKeyError.missing) { try s.publicKeyX963(userID: user, writerID: writer) }
    _ = try await s.create(userID: user, writerID: writer)
    s.failNext(.cancelled)
    await #expect(throws: ApprovalKeyError.cancelled) {
      try await s.sign(Data(), userID: user, writerID: writer, reason: "x")
    }
    _ = try await s.sign(Data(), userID: user, writerID: writer, reason: "x")
    s.remove(userID: user, writerID: writer)
    await #expect(throws: ApprovalKeyError.missing) {
      try await s.sign(Data(), userID: user, writerID: writer, reason: "x")
    }
  }
}
