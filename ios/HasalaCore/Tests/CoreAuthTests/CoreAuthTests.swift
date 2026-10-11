// Unit tests for CoreAuth (owner: WS-11): refusals, the transport's headers,
// go-webauthn options and PublicKeyCredential JSON.
import CorePrimitives
import Foundation
import Testing

@testable import CoreAuth

@Suite("CoreAuth: wire")
struct AuthWireTests {
  @Test("02 §6.2 refusals carry status, code, Retry-After and the request id; other bodies keep the status")
  func refusals() {
    let r = APIResponse(
      status: 429, headers: ["Retry-After": "12", "Hasala-Request-Id": "0123456789abcdef"],
      body: Data(#"{"error":"rate_limited","detail":""}"#.utf8))
    let f = APIFailure.from(r)
    #expect(f.code == "rate_limited" && f.retryAfterSeconds == 12 && f.requestID == "0123456789abcdef")
    #expect(APIFailure.from(APIResponse(status: 502, body: Data("<html>".utf8))).code == "http_502")
  }

  @Test("URLSessionTransport: Hasala-Client always, Bearer only with a session, JSON bodies")
  func headers() throws {
    let t = URLSessionTransport(baseURL: URL(string: "https://api.hasala.app")!, clientHeader: "ios/0.1/7")
    let u = try #require(
      t.urlRequest(for: APIRequest(method: .post, path: "/api/v1/sync?stream=hot", body: Data("{}".utf8), bearer: "tok")))
    #expect(u.url?.absoluteString == "https://api.hasala.app/api/v1/sync?stream=hot")
    #expect(u.value(forHTTPHeaderField: "Hasala-Client") == "ios/0.1/7")
    #expect(u.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
    #expect(u.value(forHTTPHeaderField: "Content-Type") == "application/json")
    let g = try #require(t.urlRequest(for: APIRequest(method: .get, path: "/api/v1/meta")))
    #expect(g.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(URLSessionTransport.classify(.serverCertificateUntrusted) == .tls)
    #expect(URLSessionTransport.classify(.notConnectedToInternet) == .offline(.notConnectedToInternet))
    #expect(URLSessionTransport.classify(.cancelled) == .cancelled)
  }

  @Test("URLSessionTransport: a path that would leave the API origin builds no request")
  func originOnly() throws {
    let t = URLSessionTransport(baseURL: URL(string: "https://api.hasala.app")!, clientHeader: "ios/0.1/7")
    for path in ["//api/v1/mailbox/link", "//evil.example/x", "api/v1/meta", "https://evil.example/x", ""] {
      #expect(t.urlRequest(for: APIRequest(method: .get, path: path, bearer: "tok")) == nil, "\(path)")
    }
    let local = URLSessionTransport(baseURL: URL(string: "http://api.example.invalid:8443")!, clientHeader: "ios/0.1/7")
    let u = try #require(local.urlRequest(for: APIRequest(method: .get, path: "/api/v1/meta?x=%2F%2Fy")))
    #expect(u.url?.absoluteString == "http://api.example.invalid:8443/api/v1/meta?x=%2F%2Fy")
  }

  @Test("go-webauthn CredentialCreation and CredentialAssertion options decode")
  func options() throws {
    let creation = #"""
      {"publicKey":{"rp":{"name":"Hasala","id":"hasala.app"},"user":{"name":"Hasala","displayName":"Hasala","id":"AQID"},
      "challenge":"3q2-7w","pubKeyCredParams":[{"type":"public-key","alg":-7}],"timeout":300000,
      "excludeCredentials":[{"type":"public-key","id":"BAUG"}],
      "authenticatorSelection":{"residentKey":"required","userVerification":"required"},"attestation":"none"}}
      """#
    let c = try JSONDecoder().decode(WireCreationOptions.self, from: Data(creation.utf8)).decoded()
    #expect(c.challenge == Data([0xde, 0xad, 0xbe, 0xef]) && c.rpID == "hasala.app" && c.userID == Data([1, 2, 3]))
    #expect(c.excludeCredentialIDs == [Data([4, 5, 6])])
    let assertion = #"{"publicKey":{"challenge":"3q2-7w","timeout":300000,"rpId":"hasala.app","userVerification":"required"}}"#
    let a = try JSONDecoder().decode(WireAssertionOptions.self, from: Data(assertion.utf8)).decoded()
    #expect(a.challenge == Data([0xde, 0xad, 0xbe, 0xef]) && a.allowCredentialIDs.isEmpty)
    let bad = #"{"publicKey":{"challenge":"3q2+7w=="}}"#
    #expect(throws: WebAuthnError.self) {
      _ = try JSONDecoder().decode(WireAssertionOptions.self, from: Data(bad.utf8)).decoded()
    }
  }

  @Test("PublicKeyCredential JSON: unpadded base64url, the raw bytes untouched")
  func credential() throws {
    let reg = RawRegistration(
      credentialID: Data([0xfb, 0xff]), rawClientDataJSON: Data("{}".utf8), rawAttestationObject: Data([0xa0]),
      prfFirst: nil)
    let json = String(decoding: try JSONEncoder().encode(reg.credential), as: UTF8.self)
    #expect(json.contains(#""id":"-_8""#))
    #expect(json.contains(#""attestationObject":"oA""#))
    #expect(json.contains(#""clientExtensionResults":{}"#))
    #expect(!json.contains("="))
  }

  @Test("a key-history id arrives as a decimal string (Go) or a number")
  func flexibleDecimal() throws {
    struct W: Decodable { let id: FlexibleDecimal }
    #expect(try JSONDecoder().decode(W.self, from: Data(#"{"id":"12"}"#.utf8)).id.value == 12)
    #expect(try JSONDecoder().decode(W.self, from: Data(#"{"id":13}"#.utf8)).id.value == 13)
    #expect(throws: (any Error).self) { _ = try JSONDecoder().decode(W.self, from: Data(#"{"id":"-1"}"#.utf8)) }
  }
}
