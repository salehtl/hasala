import CoreMailbox
import Foundation
import Synchronization
import Testing

private final class OneAnswer: HTTPExchange, Sendable {
  let answer: HTTPResponse
  let seen = Mutex<[HTTPRequest]>([])

  init(_ answer: HTTPResponse) { self.answer = answer }

  func send(_ request: HTTPRequest) async throws(HTTPExchangeError) -> HTTPResponse {
    seen.withLock { $0.append(request) }
    return answer
  }
}

@Suite struct GraphHeaderListTests {
  @Test func headerListSelectsInternetMessageHeadersAndKeepsTheirOrder() async throws {
    let body = #"{"internetMessageHeaders":[{"name":"Received","value":"from a.example"},{"name":"Authentication-Results","value":"spf=pass"},{"name":"X-Broken"},{"name":"From","value":"x@bank.example"}]}"#
    let http = OneAnswer(HTTPResponse(status: 200, body: Data(body.utf8)))
    let client = GraphClient(http: http, accessToken: "t", link: MemoryOutlookLinkStore(), nowMs: { 0 })
    let list = try await client.messageHeaderList(id: "AAkALgAA/id=")
    #expect(list.map(\.name) == ["Received", "Authentication-Results", "From"])
    let req = try #require(http.seen.withLock { $0.first })
    #expect(req.url.absoluteString == "https://graph.microsoft.com/v1.0/me/messages/AAkALgAA%2Fid%3D?$select=internetMessageHeaders")
    #expect(req.headers.contains { $0.0 == "Prefer" && $0.1 == "IdType=\"ImmutableId\"" })
  }

  @Test func valueReturnsTheMIMEBytes() async throws {
    let http = OneAnswer(HTTPResponse(status: 200, body: Data("From: x@bank.example\r\n\r\nbody".utf8)))
    let client = GraphClient(http: http, accessToken: "t", link: MemoryOutlookLinkStore(), nowMs: { 0 })
    let data = try await client.messageValue(id: "m1")
    #expect(data == Data("From: x@bank.example\r\n\r\nbody".utf8))
    #expect(http.seen.withLock { $0.first?.url.absoluteString } == "https://graph.microsoft.com/v1.0/me/messages/m1/$value")
  }

  @Test func anEmptyValueIsAnError() async {
    let http = OneAnswer(HTTPResponse(status: 200))
    let client = GraphClient(http: http, accessToken: "t", link: MemoryOutlookLinkStore(), nowMs: { 0 })
    await #expect(throws: MailAPIError.self) { _ = try await client.messageValue(id: "m1") }
  }
}
