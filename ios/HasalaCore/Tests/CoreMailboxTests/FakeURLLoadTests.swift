import CoreMailbox
@testable import CoreTestSupport
import Foundation
import Synchronization
import Testing

@Suite struct FakeURLLoadTests {
  final class HeldAnswer: HTTPExchange {
    struct State {
      var entered = false
      var cancelled = false
      var released = false
      var returned = false
    }

    let state = Mutex(State())

    func send(_ request: HTTPRequest) async throws(HTTPExchangeError) -> HTTPResponse {
      state.withLock { $0.entered = true }
      while !state.withLock({ $0.released }) {
        if Task.isCancelled { state.withLock { $0.cancelled = true } }
        await Task.yield()
      }
      state.withLock { $0.returned = true }
      return HTTPResponse(status: 200)
    }

    func release() { state.withLock { $0.released = true } }
  }

  final class Answer: HTTPExchange {
    func send(_ request: HTTPRequest) async throws(HTTPExchangeError) -> HTTPResponse { HTTPResponse(status: 200) }
  }

  final class RecordingClient: NSObject, URLProtocolClient {
    let calls = Mutex<[String]>([])

    func note(_ call: String) { calls.withLock { $0.append(call) } }
    func urlProtocol(_ protocol: URLProtocol, wasRedirectedTo request: URLRequest, redirectResponse: URLResponse) { note("redirect") }
    func urlProtocol(_ protocol: URLProtocol, cachedResponseIsValid cachedResponse: CachedURLResponse) { note("cached") }
    func urlProtocol(_ protocol: URLProtocol, didReceive response: URLResponse, cacheStoragePolicy policy: URLCache.StoragePolicy) {
      note("response")
    }
    func urlProtocol(_ protocol: URLProtocol, didLoad data: Data) { note("data") }
    func urlProtocolDidFinishLoading(_ protocol: URLProtocol) { note("finished") }
    func urlProtocol(_ protocol: URLProtocol, didFailWithError error: any Error) { note("failed") }
    func urlProtocol(_ protocol: URLProtocol, didReceive challenge: URLAuthenticationChallenge) { note("challenge") }
    func urlProtocol(_ protocol: URLProtocol, didCancel challenge: URLAuthenticationChallenge) { note("cancel") }
  }

  static let url = URL(string: "https://gmail.googleapis.com/x")!

  func eventually(_ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(2))
    }
    return condition()
  }

  func load(_ fake: any HTTPExchange, client: RecordingClient) -> (FakeGmailURLProtocol, String) {
    let id = FakeGmailURLProtocol.register(fake)
    var request = URLRequest(url: Self.url)
    request.setValue(id, forHTTPHeaderField: FakeGmailURLProtocol.header)
    return (FakeGmailURLProtocol(request: request, cachedResponse: nil, client: client), id)
  }

  @Test func aCancelledRequestCancelsTheFakesAnswer() async {
    let held = HeldAnswer()
    let http = FakeGmailURLProtocol.exchange(for: held)
    let task = Task { try? await http.send(HTTPRequest(method: .get, url: Self.url)) }
    #expect(await eventually { held.state.withLock { $0.entered } })

    task.cancel()

    let cancelled = await eventually { held.state.withLock { $0.cancelled } }
    held.release()
    _ = await task.value
    #expect(cancelled)
  }

  @Test func afterStopLoadingTheClientHearsNothing() async throws {
    let held = HeldAnswer()
    let client = RecordingClient()
    let (loading, id) = load(held, client: client)
    defer { FakeGmailURLProtocol.forget(id) }
    loading.startLoading()
    #expect(await eventually { held.state.withLock { $0.entered } })

    loading.stopLoading()
    held.release()

    #expect(await eventually { held.state.withLock { $0.returned } })
    try await Task.sleep(for: .milliseconds(100))
    #expect(client.calls.withLock { $0 }.isEmpty)
  }

  @Test func withoutAStopTheClientHearsTheAnswer() async {
    let client = RecordingClient()
    let (loading, id) = load(Answer(), client: client)
    defer { FakeGmailURLProtocol.forget(id) }

    loading.startLoading()

    #expect(await eventually { client.calls.withLock { $0 } == ["response", "data", "finished"] })
  }

  @Test func anExchangeThatIsGoneReleasesItsFake() async throws {
    weak var released: Answer?
    do {
      let fake = Answer()
      released = fake
      let http = FakeGmailURLProtocol.exchange(for: fake)
      #expect(try await http.send(HTTPRequest(method: .get, url: Self.url)).status == 200)
    }
    #expect(await eventually { released == nil })
  }
}
