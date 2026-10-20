import Foundation
import Testing

@testable import CoreAuth

final class RedirectStub: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var seen: [String] = []

  static func requested() -> [String] { lock.withLock { seen } }

  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host?.hasSuffix(".redirect.invalid") == true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let url = request.url!
    Self.lock.withLock { Self.seen.append(url.absoluteString) }
    if url.host == "api.redirect.invalid" {
      let target = URL(string: "https://evil.redirect.invalid/steal")!
      let r = HTTPURLResponse(
        url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
      client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: r)
      client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
      client?.urlProtocolDidFinishLoading(self)
    } else {
      let r = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
      client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: Data("{}".utf8))
      client?.urlProtocolDidFinishLoading(self)
    }
  }

  override func stopLoading() {}
}

@Suite("CoreAuth: redirects")
struct AuthRedirectTests {
  @Test("URLSessionTransport: a 302 to another host is not followed and fails as a bad server response")
  func refusesRedirect() async throws {
    let t = URLSessionTransport(
      baseURL: URL(string: "https://api.redirect.invalid")!, clientHeader: "ios/0.1/7", timeout: 5,
      protocolClasses: [RedirectStub.self])
    await #expect(throws: TransportError.offline(.badServerResponse)) {
      _ = try await t.send(APIRequest(method: .get, path: "/api/v1/meta", bearer: "tok"))
    }
    let seen = RedirectStub.requested()
    #expect(seen.contains("https://api.redirect.invalid/api/v1/meta"))
    #expect(!seen.contains { $0.hasPrefix("https://evil.redirect.invalid") })
  }

  @Test("RefuseRedirects hands nil to the completion handler")
  func delegateRefuses() async throws {
    let from = URL(string: "https://api.hasala.app/api/v1/meta")!
    let to = URL(string: "https://evil.example/x")!
    let r = HTTPURLResponse(
      url: from, statusCode: 307, httpVersion: "HTTP/1.1", headerFields: ["Location": to.absoluteString])!
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let task = session.dataTask(with: from)
    let next: URLRequest? = await withCheckedContinuation { c in
      RefuseRedirects().urlSession(session, task: task, willPerformHTTPRedirection: r, newRequest: URLRequest(url: to)) {
        c.resume(returning: $0)
      }
    }
    #expect(next == nil)
  }
}
