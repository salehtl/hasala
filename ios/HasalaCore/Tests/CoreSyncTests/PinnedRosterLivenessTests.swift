import CoreCrypto
import CoreWire
import Foundation
import Testing

@testable import CoreSync

@Suite("PinnedRoster: one reading of whether a writer is live")
struct PinnedRosterLivenessTests {
  static let id = "ios-0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"
  static let key = WriterID(id)!
  static let dwk = Data(repeating: 7, count: 32)
  static let head = Data(repeating: 9, count: 32)

  func roster(counter: Int64?, head: String?) throws -> PinnedRoster {
    var writer: [String: Any] = ["dwk": Self.dwk.base64EncodedString(), "dak": "DAK"]
    if let counter { writer["final_counter"] = counter }
    if let head { writer["final_head"] = head }
    let o: [String: Any] = ["authority_pubkey": "AAK", "writers": [Self.id: writer]]
    return try JSONDecoder().decode(PinnedRoster.self, from: JSONSerialization.data(withJSONObject: o))
  }

  @Test("a live writer is live everywhere")
  func live() throws {
    let r = try roster(counter: nil, head: nil)
    #expect(r.writers[Self.id]?.isLive == true)
    #expect(r.liveWriters() == [Self.key])
    #expect(r.forReader()[Self.key]?.revokedAt == nil && r.forReader()[Self.key] != nil)
  }

  @Test("a revoked writer is revoked everywhere, at its pin")
  func revoked() throws {
    let r = try roster(counter: 3, head: Self.head.base64EncodedString())
    #expect(r.writers[Self.id]?.isLive == false)
    #expect(r.liveWriters().isEmpty)
    #expect(r.forReader()[Self.key]?.revokedAt == Chain.Head(counter: 3, hash: Hash32(Self.head)!))
  }

  @Test(
    "a pin that is half there or does not read is never a live writer",
    arguments: [
      (Int64?.some(3), String?.none),
      (Int64?.none, String?.some(head.base64EncodedString())),
      (Int64?.some(3), String?.some("not a head")),
      (Int64?.some(3), String?.some(Data(repeating: 9, count: 31).base64EncodedString())),
    ] as [(Int64?, String?)])
  func broken(counter: Int64?, head: String?) throws {
    let r = try roster(counter: counter, head: head)
    #expect(r.writers[Self.id]?.isLive == false)
    #expect(r.liveWriters().isEmpty)
    #expect(r.forReader()[Self.key] == nil)
  }

  @Test(
    "a chain is short only while its head is below a readable pin",
    arguments: [
      (Int64?.none, Int64?.none, false),
      (Int64?.some(3), Int64?.none, true),
      (Int64?.some(3), Int64?.some(2), true),
      (Int64?.some(3), Int64?.some(3), false),
      (Int64?.some(3), Int64?.some(4), false),
      (Int64?.some(0), Int64?.none, false),
    ] as [(Int64?, Int64?, Bool)])
  func short(pin: Int64?, head: Int64?, want: Bool) throws {
    let r = try roster(counter: pin, head: pin == nil ? nil : Self.head.base64EncodedString())
    let heads = head.map { [Self.key: Chain.Head(counter: $0, hash: Hash32(Self.head)!)] } ?? [:]
    let got = r.shortOfFinal(heads: heads)
    #expect(got.map(\.writer) == (want ? [Self.key] : []))
    #expect(got.map(\.final.counter) == (want ? [pin!] : []))
  }

  @Test("a pin that does not read is never short")
  func brokenPinIsNotShort() throws {
    #expect(try roster(counter: 3, head: nil).shortOfFinal(heads: [:]).isEmpty)
    #expect(try roster(counter: 3, head: "not a head").shortOfFinal(heads: [:]).isEmpty)
  }

  @Test("the pin of a half-revoked writer still cannot be dropped by a later roster")
  func extendsKeepsThePin() throws {
    let pinned = try roster(counter: 3, head: nil)
    #expect(try !roster(counter: nil, head: nil).extends(pinned))
    let headOnly = try roster(counter: nil, head: Self.head.base64EncodedString())
    #expect(try !roster(counter: nil, head: nil).extends(headOnly))
  }
}
