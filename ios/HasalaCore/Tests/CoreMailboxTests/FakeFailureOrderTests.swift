import CoreMailbox
import CoreTestSupport
import Foundation
import Testing

@Suite struct FakeFailureOrderTests {
  @Test func gmailAnswersWithTheFailureQueuedFirstWhenTwoMatch() async throws {
    for i in 0..<32 {
      let g = FakeGmail()
      g.fail("/messages/m\(i)", with: [500])
      g.fail("/m\(i)", with: [503])
      let request = HTTPRequest(method: .get, url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/m\(i)")!)

      #expect(try await g.send(request).status == 500)
      #expect(try await g.send(request).status == 503)
      #expect(try await g.send(request).status == 404)
    }
  }

  @Test func graphAnswersWithTheFailureQueuedFirstWhenTwoMatch() async throws {
    for i in 0..<32 {
      let g = FakeGraph()
      g.fail("/messages/m\(i)", with: [500])
      g.fail("/m\(i)", with: [503])
      let request = HTTPRequest(method: .get, url: URL(string: "https://graph.microsoft.com/v1.0/me/messages/m\(i)")!)

      #expect(try await g.send(request).status == 500)
      #expect(try await g.send(request).status == 503)
    }
  }
}
