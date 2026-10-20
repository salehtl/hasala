import Foundation
import Testing

@testable import Hasala

nonisolated final class GravatarStubProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var status = 200
  nonisolated(unsafe) static var body = Data([1, 2, 3])
  nonisolated(unsafe) static var fails = false
  nonisolated(unsafe) static var requests: [URLRequest] = []

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.requests.append(request)
    if Self.fails {
      client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
      return
    }
    let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Self.body)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}

  static func reset() {
    status = 200
    body = Data([1, 2, 3])
    fails = false
    requests = []
  }
}

nonisolated final class GravatarClock: @unchecked Sendable {
  nonisolated(unsafe) var now = Date(timeIntervalSince1970: 1_000_000)
}

@Suite("Gravatar avatar", .serialized)
struct GravatarTests {
  private func loader(clock: GravatarClock = GravatarClock(), directory: URL? = nil) -> GravatarLoader {
    GravatarStubProtocol.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [GravatarStubProtocol.self]
    return GravatarLoader(directory: directory, session: URLSession(configuration: configuration), now: { clock.now })
  }

  @Test func hashIsTheSHA256OfTheTrimmedLowercasedAddress() {
    let expected = "973dfe463ec85785f5f95af5ba3906eedb2d931c24e69824a89ea65dba4e813b"
    #expect(Gravatar.hash(email: "Test@Example.com ") == expected)
    #expect(Gravatar.hash(email: "test@example.com") == expected)
  }

  @Test func urlAsksFor404OnAMissingPicture() {
    let url = Gravatar.url(email: "Test@Example.com ", pixels: 108)
    #expect(
      url?.absoluteString
        == "https://gravatar.com/avatar/973dfe463ec85785f5f95af5ba3906eedb2d931c24e69824a89ea65dba4e813b?s=108&d=404")
  }

  @Test func requestSendsNoCookies() {
    #expect(Gravatar.request(email: "a@example.com", pixels: 72)?.httpShouldHandleCookies == false)
    #expect(Gravatar.session().configuration.httpCookieStorage == nil)
  }

  @Test func foundPictureIsReturned() async {
    let subject = loader()
    let data = await subject.picture(email: "a@example.com", pixels: 72)
    #expect(data == Data([1, 2, 3]))
  }

  @Test func a404FallsBackToInitials() async {
    let subject = loader()
    GravatarStubProtocol.status = 404
    #expect(await subject.picture(email: "a@example.com", pixels: 72) == nil)
  }

  @Test func offlineFallsBackToInitials() async {
    let subject = loader()
    GravatarStubProtocol.fails = true
    #expect(await subject.picture(email: "a@example.com", pixels: 72) == nil)
  }

  @Test func aSecondAskWithinADayDoesNotRefetch() async {
    let subject = loader()
    _ = await subject.picture(email: "a@example.com", pixels: 72)
    _ = await subject.picture(email: "a@example.com", pixels: 72)
    #expect(GravatarStubProtocol.requests.count == 1)
  }

  @Test func a404IsCachedToo() async {
    let subject = loader()
    GravatarStubProtocol.status = 404
    _ = await subject.picture(email: "a@example.com", pixels: 72)
    _ = await subject.picture(email: "a@example.com", pixels: 72)
    #expect(GravatarStubProtocol.requests.count == 1)
  }

  @Test func theCacheExpiresAfterADay() async {
    let clock = GravatarClock()
    let subject = loader(clock: clock)
    _ = await subject.picture(email: "a@example.com", pixels: 72)
    clock.now = clock.now.addingTimeInterval(GravatarLoader.maxAge + 1)
    _ = await subject.picture(email: "a@example.com", pixels: 72)
    #expect(GravatarStubProtocol.requests.count == 2)
  }

  @Test func theDiskCacheServesANewLoader() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gravatar-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let clock = GravatarClock()
    let first = loader(clock: clock, directory: directory)
    _ = await first.picture(email: "a@example.com", pixels: 72)
    let second = loader(clock: clock, directory: directory)
    GravatarStubProtocol.reset()
    let data = await second.picture(email: "a@example.com", pixels: 72)
    #expect(data == Data([1, 2, 3]))
    #expect(GravatarStubProtocol.requests.isEmpty)
  }

  @Test func aFailedRefreshKeepsTheStalePicture() async {
    let clock = GravatarClock()
    let subject = loader(clock: clock)
    _ = await subject.picture(email: "a@example.com", pixels: 72)
    clock.now = clock.now.addingTimeInterval(GravatarLoader.maxAge + 1)
    GravatarStubProtocol.fails = true
    #expect(await subject.picture(email: "a@example.com", pixels: 72) == Data([1, 2, 3]))
  }
}
