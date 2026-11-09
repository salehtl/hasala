import CoreMailbox
@testable import CoreTestSupport
import Foundation
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(1))) struct FakeURLLoadTests {
  struct Signal: Sendable {
    private let events = AsyncStream<Never>.makeStream()

    func fire() { events.continuation.finish() }
    func wait() async { for await _ in events.stream {} }
  }

  final class HeldAnswer: HTTPExchange {
    let entered = Signal()
    let cancelled = Signal()
    let returned = Signal()
    private let gate = Gate()

    func send(_ request: HTTPRequest) async throws(HTTPExchangeError) -> HTTPResponse {
      entered.fire()
      await withTaskCancellationHandler {
        await gate.pass()
      } onCancel: {
        cancelled.fire()
      }
      returned.fire()
      return HTTPResponse(status: 200)
    }

    func release() { gate.open() }
  }

  final class Answer: HTTPExchange {
    let gone = Signal()

    deinit { gone.fire() }

    func send(_ request: HTTPRequest) async throws(HTTPExchangeError) -> HTTPResponse { HTTPResponse(status: 200) }
  }

  final class RecordingClient: NSObject, URLProtocolClient {
    let calls = Mutex<[String]>([])
    let ended = Signal()

    func note(_ call: String) { calls.withLock { $0.append(call) } }
    func urlProtocol(_ protocol: URLProtocol, wasRedirectedTo request: URLRequest, redirectResponse: URLResponse) { note("redirect") }
    func urlProtocol(_ protocol: URLProtocol, cachedResponseIsValid cachedResponse: CachedURLResponse) { note("cached") }
    func urlProtocol(_ protocol: URLProtocol, didReceive response: URLResponse, cacheStoragePolicy policy: URLCache.StoragePolicy) {
      note("response")
    }
    func urlProtocol(_ protocol: URLProtocol, didLoad data: Data) { note("data") }
    func urlProtocolDidFinishLoading(_ protocol: URLProtocol) {
      note("finished")
      ended.fire()
    }
    func urlProtocol(_ protocol: URLProtocol, didFailWithError error: any Error) {
      note("failed")
      ended.fire()
    }
    func urlProtocol(_ protocol: URLProtocol, didReceive challenge: URLAuthenticationChallenge) { note("challenge") }
    func urlProtocol(_ protocol: URLProtocol, didCancel challenge: URLAuthenticationChallenge) { note("cancel") }
  }

  static let url = URL(string: "https://gmail.googleapis.com/x")!

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
    await held.entered.wait()

    task.cancel()

    await held.cancelled.wait()
    held.release()
    _ = await task.value
  }

  @Test func afterStopLoadingTheClientHearsNothing() async throws {
    let held = HeldAnswer()
    let client = RecordingClient()
    let (loading, id) = load(held, client: client)
    defer { FakeGmailURLProtocol.forget(id) }
    loading.startLoading()
    await held.entered.wait()

    loading.stopLoading()
    held.release()

    await held.returned.wait()
    try await Task.sleep(for: .milliseconds(100))
    #expect(client.calls.withLock { $0 }.isEmpty)
  }

  @Test func withoutAStopTheClientHearsTheAnswer() async {
    let client = RecordingClient()
    let (loading, id) = load(Answer(), client: client)
    defer { FakeGmailURLProtocol.forget(id) }

    loading.startLoading()

    await client.ended.wait()
    #expect(client.calls.withLock { $0 } == ["response", "data", "finished"])
  }

  @Test func anExchangeThatIsGoneReleasesItsFake() async throws {
    let gone: Signal
    do {
      let fake = Answer()
      gone = fake.gone
      let http = FakeGmailURLProtocol.exchange(for: fake)
      #expect(try await http.send(HTTPRequest(method: .get, url: Self.url)).status == 200)
    }
    await gone.wait()
  }
}
