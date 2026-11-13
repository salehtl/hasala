import Foundation
import Testing

@testable import CoreAuth

@Suite("CoreAuth: step-up proof shapes")
struct StepUpProofTests {
  static let assertion =
    #"{"id":"a","rawId":"a","type":"public-key","response":{"clientDataJSON":"e30"},"clientExtensionResults":{}}"#

  func decode(_ json: String) throws -> StepUpJSON.Proof {
    try JSONDecoder().decode(StepUpJSON.Proof.self, from: Data(json.utf8))
  }

  func keys(_ proof: StepUpJSON.Proof) throws -> Set<String> {
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(proof))
    return Set(try #require(object as? [String: Any]).keys)
  }

  @Test("each kind sends exactly the fields the server reads for it")
  func wire() throws {
    let passkey = try decode(#"{"kind":"passkey","assertion":\#(Self.assertion)}"#)
    #expect(try keys(passkey) == ["kind", "assertion"])
    #expect(try keys(.device(writerID: "w", sigB64: "s", verifierB64: "v")) == ["kind", "writer_id", "sig", "verifier"])
    #expect(try keys(.deviceCode(writerID: "w", sigB64: "s", code: "123456")) == ["kind", "writer_id", "sig", "code"])
  }

  @Test("a proof without a field of its kind, or of an unknown kind, does not exist")
  func incomplete() {
    for json in [
      #"{"kind":"passkey"}"#,
      #"{"kind":"device","writer_id":"w","sig":"s"}"#,
      #"{"kind":"device","writer_id":"w","verifier":"v"}"#,
      #"{"kind":"device","sig":"s","verifier":"v"}"#,
      #"{"kind":"device_code","writer_id":"w","code":"123456"}"#,
      #"{"kind":"device_code","sig":"s","code":"123456"}"#,
      #"{"kind":"device_code","writer_id":"w","sig":"s"}"#,
      #"{"kind":"magic","writer_id":"w","sig":"s","verifier":"v","code":"123456"}"#,
    ] {
      #expect(throws: DecodingError.self, "\(json)") { _ = try decode(json) }
    }
  }

  @Test("a field of another kind is not carried")
  func foreignFields() throws {
    let p = try decode(
      #"{"kind":"device","writer_id":"w","sig":"s","verifier":"v","code":"9","assertion":\#(Self.assertion)}"#)
    #expect(p == .device(writerID: "w", sigB64: "s", verifierB64: "v"))
    #expect(p.code == nil && p.assertion == nil)
  }
}
