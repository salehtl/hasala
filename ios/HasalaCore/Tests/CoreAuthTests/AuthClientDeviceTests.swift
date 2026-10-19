// AuthClient's device and account routes (`02` #31-#33, #74, #76): method,
// path, bearer and the exact body the server's strict decoder accepts, and
// refusals surfacing as `APIError.refused` with the server's code.
import Foundation
import Synchronization
import Testing

@testable import CoreAuth

@Suite("CoreAuth: device and account routes")
struct AuthClientDeviceTests {
  final class Recorder: Transport {
    let requests = Mutex<[APIRequest]>([])
    let answer: APIResponse
    init(_ answer: APIResponse = APIResponse(status: 204)) { self.answer = answer }
    func send(_ request: APIRequest) async throws(TransportError) -> APIResponse {
      requests.withLock { $0.append(request) }
      return answer
    }
    var last: APIRequest? { requests.withLock { $0.last } }
    var body: String { last?.body.map { String(decoding: $0, as: UTF8.self) } ?? "" }
  }

  @Test("#31 PUT /push/apns {environment, token_hex}; the token as lower-case hex")
  func putAPNs() async throws {
    let t = Recorder()
    let token = AuthClient.tokenHex(Data([0x0a, 0xff] + Array(repeating: 0x5c, count: 30)))
    #expect(token.hasPrefix("0aff5c") && token.count == 64)
    try await AuthClient(transport: t).putAPNs(tokenHex: token, environment: .sandbox, bearer: "tok")
    #expect(t.last?.method == .put && t.last?.path == "/api/v1/push/apns" && t.last?.bearer == "tok")
    #expect(t.body == #"{"environment":"sandbox","token_hex":"\#(token)"}"#)
    #expect(APNsTokenEnvironment(rawValue: "production") == .production)
  }

  @Test("#32 GET and #33 DELETE /push/apns (no body)")
  func listAndDelete() async throws {
    let list = Recorder(
      APIResponse(
        status: 200,
        body: Data(
          #"{"devices":[{"writer_id":"ios-0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d","environment":"production","created_at":"2026-10-11T08:00:00Z","updated_at":"2026-10-11T08:00:00Z","current":true}]}"#
            .utf8)))
    let devices = try await AuthClient(transport: list).apnsDevices(bearer: "tok")
    #expect(devices.devices.count == 1 && devices.devices[0].current && list.last?.method == .get)
    let del = Recorder()
    try await AuthClient(transport: del).deleteAPNs(bearer: "tok")
    #expect(del.last?.method == .delete && del.last?.path == "/api/v1/push/apns" && del.last?.body == nil)
  }

  @Test("#74 POST /bank-requests: source app; otherBank only with bank other")
  func bankRequest() async throws {
    let t = Recorder(APIResponse(status: 202, body: Data(#"{"status":"counted"}"#.utf8)))
    let c = AuthClient(transport: t)
    #expect(try await c.bankRequest(bank: "adcb", bearer: "tok").status == "counted")
    #expect(t.last?.method == .post && t.last?.path == "/api/v1/bank-requests" && t.body == #"{"bank":"adcb","source":"app"}"#)
    _ = try await c.bankRequest(bank: "other", otherBank: "Mashreq Neo", bearer: "tok")
    #expect(t.body == #"{"bank":"other","otherBank":"Mashreq Neo","source":"app"}"#)
    _ = try await c.bankRequest(bank: "fab", senderDomain: "alerts.example.ae", bearer: "tok")
    #expect(t.body == #"{"bank":"fab","senderDomain":"alerts.example.ae","source":"app"}"#)
  }

  @Test("GET /bank-requests: the account's requests and the catalog")
  func bankRequestsList() async throws {
    let t = Recorder(APIResponse(status: 200, body: Data(#"""
      {"requests":[{"bank":"fab","name":"First Abu Dhabi Bank","state":"collecting_samples","requestedAt":"2026-10-19T10:00:00Z"}],
       "catalog":[{"bank":"enbd","name":"Emirates NBD","state":"supported"}]}
      """#.utf8)))
    let list = try await AuthClient(transport: t).bankRequests(bearer: "tok")
    #expect(t.last?.method == .get && t.last?.path == "/api/v1/bank-requests")
    #expect(list.requests.first?.state == "collecting_samples" && list.catalog.first?.bank == "enbd")
  }

  @Test("#76 PUT /account/display-name {display_name}; a refusal keeps the server's code")
  func displayName() async throws {
    let t = Recorder()
    try await AuthClient(transport: t).setDisplayName("Maya Rahman", bearer: "tok")
    #expect(t.last?.method == .put && t.last?.path == "/api/v1/account/display-name" && t.body == #"{"display_name":"Maya Rahman"}"#)
    let refused = Recorder(APIResponse(status: 400, body: Data(#"{"error":"bad_name","detail":"too long"}"#.utf8)))
    await #expect(throws: APIError.self) { try await AuthClient(transport: refused).setDisplayName("x", bearer: "tok") }
    do {
      try await AuthClient(transport: refused).setDisplayName("x", bearer: "tok")
    } catch {
      #expect(error.is(400, "bad_name"))
    }
  }
}
