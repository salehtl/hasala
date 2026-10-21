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

nonisolated final class GravatarAsks: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  func next() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    count += 1
    return count == 1
  }
}

@Suite("Gravatar avatar", .serialized)
struct GravatarTests {
  private func loader(
    clock: GravatarClock = GravatarClock(), directory: URL? = nil,
    isEnabled: @escaping @Sendable () -> Bool = { true }
  ) -> GravatarLoader {
    GravatarStubProtocol.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [GravatarStubProtocol.self]
    return GravatarLoader(
      directory: directory, session: URLSession(configuration: configuration), now: { clock.now }, isEnabled: isEnabled)
  }

  private func freshSuite() -> String {
    let name = "test.gravatar.\(UUID().uuidString)"
    UserDefaults(suiteName: name)!.removePersistentDomain(forName: name)
    return name
  }

  private func freshDefaults() -> UserDefaults { UserDefaults(suiteName: freshSuite())! }

  private func tempDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("gravatar-\(UUID().uuidString)")
  }

  @Test func theSwitchIsOnByDefaultAndStoredOnThisIPhone() {
    let d = freshDefaults()
    #expect(GravatarSetting.isEnabled(d))
    GravatarSetting.setEnabled(false, d)
    #expect(!GravatarSetting.isEnabled(d))
    GravatarSetting.setEnabled(true, d)
    #expect(GravatarSetting.isEnabled(d))
  }

  @Test func withTheSwitchOffTheLoaderNeverAsksGravatar() async {
    let subject = loader(isEnabled: { false })
    #expect(await subject.picture(email: "a@example.com", pixels: 72) == nil)
    #expect(await subject.provider.load("a@example.com", 72) == nil)
    #expect(GravatarStubProtocol.requests.isEmpty)
  }

  @Test func clearingDeletesTheCachedPicturesAndTheNextAskFetchesAgain() async {
    let directory = tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let subject = loader(directory: directory)
    _ = await subject.picture(email: "a@example.com", pixels: 72)
    #expect(FileManager.default.fileExists(atPath: directory.path))
    await subject.clear()
    #expect(!FileManager.default.fileExists(atPath: directory.path))
    _ = await subject.picture(email: "a@example.com", pixels: 72)
    #expect(GravatarStubProtocol.requests.count == 2)
  }

  @Test func aPictureThatArrivesAfterTheSwitchTurnedOffIsNotKept() async {
    let directory = tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let asks = GravatarAsks()
    let subject = loader(directory: directory, isEnabled: { asks.next() })
    #expect(await subject.picture(email: "a@example.com", pixels: 72) == nil)
    #expect(!FileManager.default.fileExists(atPath: directory.path))
  }

  @Test @MainActor func turningTheSwitchOffClearsTheCacheAndStaysOff() async {
    let suite = freshSuite()
    let d = UserDefaults(suiteName: suite)!
    let directory = tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let subject = loader(directory: directory, isEnabled: { GravatarSetting.isEnabled(UserDefaults(suiteName: suite)!) })
    _ = await subject.picture(email: "a@example.com", pixels: 72)
    #expect(FileManager.default.fileExists(atPath: directory.path))

    let preference = GravatarPreference(defaults: d, loader: subject)
    #expect(preference.isOn)
    preference.setOn(false)
    #expect(!preference.isOn)
    await preference.clearing?.value
    #expect(!FileManager.default.fileExists(atPath: directory.path))
    #expect(!GravatarSetting.isEnabled(d))
    #expect(!GravatarPreference(defaults: d, loader: subject).isOn)

    GravatarStubProtocol.reset()
    #expect(await subject.picture(email: "a@example.com", pixels: 72) == nil)
    #expect(GravatarStubProtocol.requests.isEmpty)

    preference.setOn(true)
    #expect(preference.isOn)
    #expect(await subject.picture(email: "a@example.com", pixels: 72) == Data([1, 2, 3]))
    #expect(GravatarStubProtocol.requests.count == 1)
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

  @Test func theRequestCarriesOnlyNeutralHeaders() async throws {
    let subject = loader()
    _ = await subject.picture(email: "a@example.com", pixels: 72)
    let sent = try #require(GravatarStubProtocol.requests.first)
    let headers = sent.allHTTPHeaderFields ?? [:]
    #expect(headers["User-Agent"] == "Mozilla/5.0")
    #expect(headers["Accept-Language"] == "*")
    #expect(headers["Accept"] == "image/*")
    #expect(headers["Cookie"] == nil && headers["Authorization"] == nil)
    #expect(Set(headers.keys) == ["User-Agent", "Accept", "Accept-Language"])
    let named = headers.values.contains { v in ["hasala", "cfnetwork", "darwin", "ios"].contains { v.lowercased().contains($0) } }
    #expect(!named)
    #expect(URLComponents(url: try #require(sent.url), resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) == ["s", "d"])
    #expect(Gravatar.session().configuration.httpAdditionalHeaders as? [String: String] == Gravatar.headers)
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
