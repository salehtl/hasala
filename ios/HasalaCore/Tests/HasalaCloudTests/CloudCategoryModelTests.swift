import CoreCategorize
import Foundation
import Synchronization
import Testing

@testable import HasalaCloud

final class StubExchange: CloudHTTPExchange {
  enum Outcome: Sendable {
    case response(CloudResponse)
    case error(CloudExchangeError)
    case hang
  }

  private let outcome: Outcome
  private let sent = Mutex<[CloudRequest]>([])

  init(_ outcome: Outcome) { self.outcome = outcome }

  convenience init(status: Int, json: String) {
    self.init(.response(CloudResponse(status: status, body: Data(json.utf8))))
  }

  var requests: [CloudRequest] { sent.withLock { $0 } }

  func send(_ request: CloudRequest) async throws(CloudExchangeError) -> CloudResponse {
    sent.withLock { $0.append(request) }
    switch outcome {
    case .response(let r): return r
    case .error(let e): throw e
    case .hang:
      do {
        try await Task.sleep(for: .seconds(30))
      } catch {
        throw .cancelled
      }
      throw .transport
    }
  }
}

let base = URL(string: "https://assist.example.test")!
let builtinAllowed = ModelTier.allowed(TaxonomyV1.builtins)
let customCategory = AllowedCategory(id: "u_pets", name: "Pets", hint: nil)

func model(_ exchange: StubExchange, enabled: Bool = true, autoFile: Bool = false) -> CloudCategoryModel {
  CloudCategoryModel(
    baseURL: base, clientVersion: "1.2.3", isEnabled: { enabled }, isAutoFileEnabled: { autoFile }, exchange: exchange, pause: {})
}

func reply(choice: String, _ probabilities: [String: Double], tag: String = "cf-clef/1") -> String {
  let probs = probabilities.sorted { $0.key < $1.key }.map { "\"\($0.key)\":\($0.value)" }.joined(separator: ",")
  return "{\"tag\":\"\(tag)\",\"choice\":\"\(choice)\",\"probabilities\":{\(probs)}}"
}

func bodyObject(_ request: CloudRequest) throws -> [String: Any] {
  try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
}

@Suite("CloudCategoryModel request")
struct CloudRequestTests {
  @Test("POST to /v1/category with only the two contract headers")
  func shape() async throws {
    let ex = StubExchange(status: 200, json: reply(choice: "dining", ["dining": 0.97, "groceries": 0.02]))
    let answer = await model(ex).suggest(subject: "CAFE EXAMPLE JBR", allowed: builtinAllowed)
    #expect(answer == .category("dining"))
    let r = try #require(ex.requests.first)
    #expect(ex.requests.count == 1)
    #expect(r.method == "POST")
    #expect(r.url.absoluteString == "https://assist.example.test/v1/category")
    #expect(r.headers == ["Content-Type": "application/json", "Hasala-Client": "ios/1.2.3"])
    for absent in ["Authorization", "Cookie", "User-Agent", "Accept-Language", "X-Device-Id", "X-Account-Id"] {
      #expect(r.headers.keys.allSatisfy { $0.lowercased() != absent.lowercased() })
    }
  }

  @Test("the body holds the subject and the built-in categories only")
  func body() async throws {
    let ex = StubExchange(status: 200, json: reply(choice: "unknown", ["unknown": 0.9]))
    let allowed = builtinAllowed + [customCategory]
    _ = await model(ex).suggest(subject: "  CAFE EXAMPLE JBR \n", allowed: allowed)
    let r = try #require(ex.requests.first)
    let obj = try bodyObject(r)
    #expect(Set(obj.keys) == ["subject", "categories"])
    #expect(obj["subject"] as? String == "CAFE EXAMPLE JBR")
    let cats = try #require(obj["categories"] as? [[String: Any]])
    #expect(cats.map { $0["id"] as? String } == builtinAllowed.map(\.id))
    #expect(!cats.contains { $0["id"] as? String == "u_pets" })
    for c in cats {
      #expect(Set(c.keys) == ["id", "name", "hint"])
    }
    let dining = try #require(cats.first { $0["id"] as? String == "dining" })
    #expect(dining["name"] as? String == "Dining")
    #expect(dining["hint"] as? String == "restaurants, cafes, food delivery")
  }

  @Test("a built-in category is sent with its built-in name, not the account's name for it")
  func builtinName() async throws {
    let ex = StubExchange(status: 200, json: reply(choice: "unknown", [:]))
    let renamed = builtinAllowed.map { $0.id == "dining" ? AllowedCategory(id: $0.id, name: "Eating Out at Home Street", hint: $0.hint) : $0 }
    _ = await model(ex).suggest(subject: "CAFE EXAMPLE JBR", allowed: renamed)
    let r = try #require(ex.requests.first)
    let cats = try #require(try bodyObject(r)["categories"] as? [[String: Any]])
    let dining = try #require(cats.first { $0["id"] as? String == "dining" })
    #expect(dining["name"] as? String == "Dining")
    #expect(!String(decoding: r.body, as: UTF8.self).contains("Eating Out"))
  }

  @Test("a missing hint is sent as null")
  func nullHint() async throws {
    let ex = StubExchange(status: 200, json: reply(choice: "unknown", [:]))
    _ = await model(ex).suggest(subject: "CAFE EXAMPLE JBR", allowed: [AllowedCategory(id: "dining", name: "Dining", hint: nil)])
    let r = try #require(ex.requests.first)
    let text = String(decoding: r.body, as: UTF8.self)
    #expect(text == "{\"categories\":[{\"hint\":null,\"id\":\"dining\",\"name\":\"Dining\"}],\"subject\":\"CAFE EXAMPLE JBR\"}")
  }

  @Test("the subject is cut to 128 Unicode scalars")
  func cut() async throws {
    let ex = StubExchange(status: 200, json: reply(choice: "unknown", [:]))
    let long = String(repeating: "مطعم ", count: 60)
    _ = await model(ex).suggest(subject: long, allowed: builtinAllowed)
    let r = try #require(ex.requests.first)
    let sent = try #require(try bodyObject(r)["subject"] as? String)
    #expect(sent.unicodeScalars.count == 128)
    #expect(Array(sent.unicodeScalars) == Array(long.unicodeScalars.prefix(128)))
    #expect(CloudCategoryModel.requestSubject(String(repeating: "A", count: 200)).unicodeScalars.count == 128)
  }

  @Test("an Arabic subject passes through unchanged")
  func arabic() async throws {
    let ex = StubExchange(status: 200, json: reply(choice: "dining", ["dining": 0.9, "groceries": 0.05]))
    let subject = "مطعم الياسمين الشعبي"
    let answer = await model(ex).suggest(subject: subject, allowed: builtinAllowed)
    #expect(answer == .category("dining"))
    let r = try #require(ex.requests.first)
    let sent = try bodyObject(r)["subject"] as? String
    #expect(sent == subject)
  }

  @Test("no built-in category left answers unknown with no request")
  func emptyBuiltins() async {
    let ex = StubExchange(status: 200, json: reply(choice: "dining", ["dining": 0.99]))
    #expect(await model(ex).suggest(subject: "CAFE EXAMPLE JBR", allowed: [customCategory]) == .unknown)
    #expect(await model(ex).suggest(subject: "CAFE EXAMPLE JBR", allowed: []) == .unknown)
    #expect(ex.requests.isEmpty)
  }
}

@Suite("CloudCategoryModel answers")
struct CloudAnswerTests {
  @Test("availability follows isEnabled")
  func availability() {
    let ex = StubExchange(status: 200, json: "{}")
    #expect(model(ex, enabled: true).availability() == .available)
    #expect(model(ex, enabled: false).availability() == .notEnabled)
    let flag = Atomic<Bool>(false)
    let m = CloudCategoryModel(baseURL: base, clientVersion: "1", isEnabled: { flag.load(ordering: .relaxed) }, isAutoFileEnabled: { false }, exchange: ex)
    #expect(m.availability() == .notEnabled)
    flag.store(true, ordering: .relaxed)
    #expect(m.availability() == .available)
    #expect(m.modelTag == "cf-clef/1")
    #expect(CloudCategoryModel.defaultTag == "cf-clef/1")
  }

  @Test(
    "the gate",
    arguments: [
      (reply(choice: "dining", ["dining": 0.97, "groceries": 0.02]), ModelAnswer.category("dining")),
      (reply(choice: "dining", ["dining": 0.55, "groceries": 0.1]), ModelAnswer.unknown),
      (reply(choice: "dining", ["dining": 0.65, "groceries": 0.5]), ModelAnswer.unknown),
      (reply(choice: "dining", ["dining": 0.8, "groceries": 0.6]), ModelAnswer.category("dining")),
      (reply(choice: "dining", ["dining": 0.7, "unknown": 0.3]), ModelAnswer.category("dining")),
      (reply(choice: "unknown", ["unknown": 0.95, "dining": 0.01]), ModelAnswer.unknown),
      (reply(choice: "u_pets", ["u_pets": 0.99]), ModelAnswer.unknown),
      (reply(choice: "salary", ["salary": 0.99]), ModelAnswer.unknown),
      (reply(choice: "dining", ["groceries": 0.2]), ModelAnswer.unknown),
    ])
  func gate(json: String, want: ModelAnswer) async {
    let ex = StubExchange(status: 200, json: json)
    #expect(await model(ex).suggest(subject: "CAFE EXAMPLE JBR", allowed: builtinAllowed + [customCategory]) == want)
  }

  @Test("a different tag fails as other")
  func tagMismatch() async {
    let ex = StubExchange(status: 200, json: reply(choice: "dining", ["dining": 0.97], tag: "cf-clef/2"))
    #expect(await model(ex).suggest(subject: "CAFE EXAMPLE JBR", allowed: builtinAllowed) == .failed(.other))
  }

  @Test(
    "HTTP status mapping",
    arguments: [
      (400, ModelAnswer.failed(.refused)), (403, .failed(.refused)), (404, .failed(.other)), (405, .failed(.other)),
      (413, .failed(.refused)), (429, .failed(.rateLimited)), (502, .failed(.decoding)), (503, .failed(.busy)),
      (500, .failed(.other)),
    ])
  func status(code: Int, want: ModelAnswer) async {
    let ex = StubExchange(status: code, json: "{\"error\":\"x\"}")
    #expect(await model(ex).suggest(subject: "CAFE EXAMPLE JBR", allowed: builtinAllowed) == want)
  }

  @Test("transport errors")
  func transport() async {
    let timedOut = StubExchange(.error(.timedOut))
    #expect(await model(timedOut).suggest(subject: "CAFE EXAMPLE JBR", allowed: builtinAllowed) == .failed(.timeout))
    let offline = StubExchange(.error(.transport))
    #expect(await model(offline).suggest(subject: "CAFE EXAMPLE JBR", allowed: builtinAllowed) == .failed(.other))
  }

  @Test("malformed JSON fails as decoding", arguments: ["not json", "{\"tag\":\"cf-clef/1\"}", "{\"tag\":\"cf-clef/1\",\"choice\":1,\"probabilities\":{}}", ""])
  func malformed(json: String) async {
    let ex = StubExchange(status: 200, json: json)
    #expect(await model(ex).suggest(subject: "CAFE EXAMPLE JBR", allowed: builtinAllowed) == .failed(.decoding))
  }

  @Test("a cancelled call returns without an answer")
  func cancellation() async {
    let ex = StubExchange(.hang)
    let m = model(ex)
    let task = Task { await m.suggest(subject: "CAFE EXAMPLE JBR", allowed: builtinAllowed) }
    while ex.requests.isEmpty { await Task.yield() }
    task.cancel()
    #expect(await task.value == .failed(.timeout))
  }

  @Test("an already-cancelled task sends nothing")
  func cancelledBefore() async {
    let ex = StubExchange(status: 200, json: reply(choice: "dining", ["dining": 0.97]))
    let m = model(ex)
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return await m.suggest(subject: "CAFE EXAMPLE JBR", allowed: builtinAllowed)
    }
    #expect(await task.value == .failed(.timeout))
    #expect(ex.requests.isEmpty)
  }

  @Test("the tier's per-call limit cancels a hanging call")
  func tierTimeout() async {
    let ex = StubExchange(.hang)
    let r = await ModelTier.run(
      subjects: ["CAFE EXAMPLE JBR"], model: model(ex), allowed: builtinAllowed, context: .foreground, now: { 0 },
      callTimeout: .milliseconds(50))
    #expect(r.suggestions.isEmpty && r.unknown.isEmpty && r.stoppedBy == nil)
  }

  @Test("the factory needs a base URL")
  func factory() {
    #expect(HasalaCloudFactory.makeCategoryModel(baseURL: nil, clientVersion: "1", isEnabled: { true }, isAutoFileEnabled: { true }) == nil)
    let m = HasalaCloudFactory.makeCategoryModel(baseURL: base, clientVersion: "1", isEnabled: { false }, isAutoFileEnabled: { false })
    #expect(m?.modelTag == "cf-clef/1")
    #expect(m?.availability() == .notEnabled)
  }
}

@Suite("CloudCategoryModel switch, refusal and pause")
struct CloudGuardTests {
  @Test("a switch turned off before the request sends nothing")
  func switchedOff() async {
    let ex = StubExchange(status: 200, json: reply(choice: "dining", ["dining": 0.97]))
    let flag = Atomic<Bool>(true)
    let m = CloudCategoryModel(
      baseURL: base, clientVersion: "1", isEnabled: { flag.load(ordering: .relaxed) }, isAutoFileEnabled: { false }, exchange: ex,
      pause: { flag.store(false, ordering: .relaxed) })
    #expect(await m.suggest(subject: "CAFE EXAMPLE JBR", allowed: builtinAllowed) == .failed(.notEnabled))
    #expect(ex.requests.isEmpty)
    #expect(await model(ex, enabled: false).suggest(subject: "CAFE EXAMPLE JBR", allowed: builtinAllowed) == .failed(.notEnabled))
    #expect(ex.requests.isEmpty)
  }

  @Test("the switch going off mid-run stops the stage after one request")
  func switchedOffMidRun() async {
    let ex = StubExchange(status: 200, json: reply(choice: "dining", ["dining": 0.97]))
    let m = CloudCategoryModel(
      baseURL: base, clientVersion: "1", isEnabled: { ex.requests.isEmpty }, isAutoFileEnabled: { false }, exchange: ex, pause: {})
    let r = await ModelTier.run(
      subjects: ["CAFE EXAMPLE JBR", "BOOKS EXAMPLE MALL", "TAXI EXAMPLE DXB"], model: m, allowed: builtinAllowed, context: .foreground,
      now: { 0 })
    #expect(ex.requests.count == 1)
    #expect(r.suggestions.map(\.subject) == ["CAFE EXAMPLE JBR"])
    #expect(r.stoppedBy == .notEnabled)
  }

  @Test("a refused request stops the stage for the run", arguments: [400, 403, 413])
  func refusedStops(code: Int) async {
    let ex = StubExchange(status: code, json: "{\"error\":\"x\"}")
    let r = await ModelTier.run(
      subjects: ["CAFE EXAMPLE JBR", "BOOKS EXAMPLE MALL"], model: model(ex), allowed: builtinAllowed, context: .foreground, now: { 0 })
    #expect(ex.requests.count == 1)
    #expect(r.stoppedBy == .refused)
    #expect(r.suggestions.isEmpty && r.unknown.isEmpty)
  }

  @Test("403 turns the model off for the life of the instance, across copies")
  func latch() async {
    let ex = StubExchange(status: 403, json: "{\"error\":\"client\"}")
    let m = model(ex)
    let copy = m
    #expect(m.availability() == .available)
    #expect(await m.suggest(subject: "CAFE EXAMPLE JBR", allowed: builtinAllowed) == .failed(.refused))
    #expect(m.availability() == .notEligible)
    #expect(copy.availability() == .notEligible)
    #expect(await copy.suggest(subject: "BOOKS EXAMPLE MALL", allowed: builtinAllowed) == .failed(.refused))
    #expect(await m.suggestGraded(subject: "TAXI EXAMPLE DXB", allowed: builtinAllowed).answer == .failed(.refused))
    #expect(ex.requests.count == 1)
    let fresh = model(ex)
    #expect(fresh.availability() == .available)
  }

  @Test("400 and 413 do not turn the model off", arguments: [400, 413])
  func noLatch(code: Int) async {
    let ex = StubExchange(status: code, json: "{}")
    let m = model(ex)
    #expect(await m.suggest(subject: "CAFE EXAMPLE JBR", allowed: builtinAllowed) == .failed(.refused))
    #expect(m.availability() == .available)
    #expect(await m.suggest(subject: "CAFE EXAMPLE JBR", allowed: builtinAllowed) == .failed(.refused))
    #expect(ex.requests.count == 2)
  }

  @Test("the pause runs before the request")
  func pauseFirst() async {
    let ex = StubExchange(status: 200, json: reply(choice: "dining", ["dining": 0.97]))
    let seen = Mutex<[Int]>([])
    let m = CloudCategoryModel(
      baseURL: base, clientVersion: "1", isEnabled: { true }, isAutoFileEnabled: { false }, exchange: ex,
      pause: { seen.withLock { $0.append(ex.requests.count) } })
    #expect(await m.suggest(subject: "CAFE EXAMPLE JBR", allowed: builtinAllowed) == .category("dining"))
    #expect(seen.withLock { $0 } == [0])
    #expect(ex.requests.count == 1)
    #expect(CloudCategoryModel.jitterRange == 100...400)
  }

  @Test("a task cancelled during the pause sends nothing")
  func cancelledInPause() async {
    let ex = StubExchange(status: 200, json: reply(choice: "dining", ["dining": 0.97]))
    let m = CloudCategoryModel(
      baseURL: base, clientVersion: "1", isEnabled: { true }, isAutoFileEnabled: { false }, exchange: ex,
      pause: { withUnsafeCurrentTask { $0?.cancel() } })
    let task = Task { await m.suggest(subject: "CAFE EXAMPLE JBR", allowed: builtinAllowed) }
    #expect(await task.value == .failed(.timeout))
    #expect(ex.requests.isEmpty)
  }
}

@Suite("URLSessionCloudExchange redirects")
struct CloudRedirectTests {
  @Test("a 3xx status is a transport failure", arguments: [300, 301, 302, 303, 304, 307, 308, 399])
  func redirectStatus(code: Int) {
    #expect(throws: CloudExchangeError.transport) { try URLSessionCloudExchange.response(status: code, body: Data()) }
  }

  @Test("other statuses pass through", arguments: [200, 299, 400, 403, 429, 503])
  func otherStatus(code: Int) throws {
    #expect(try URLSessionCloudExchange.response(status: code, body: Data("x".utf8)) == CloudResponse(status: code, body: Data("x".utf8)))
  }

  @Test("the session delegate refuses to follow a redirect")
  func delegateRefuses() throws {
    let url = URL(string: "https://assist.example.test/v1/category")!
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let task = session.dataTask(with: url)
    let response = try #require(HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": "https://elsewhere.example.test/"]))
    let followed = Mutex<[URLRequest?]>([])
    CloudRefuseRedirects().urlSession(
      session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: URL(string: "https://elsewhere.example.test/")!)
    ) { r in followed.withLock { $0.append(r) } }
    let calls = followed.withLock { $0 }
    #expect(calls.count == 1)
    #expect(calls.first.map { $0 == nil } == true)
  }
}

@Suite("CloudCategoryModel auto-file")
struct CloudAutoFileTests {
  @Test(
    "the auto-file grade",
    arguments: [
      (reply(choice: "dining", ["dining": 0.97, "groceries": 0.01]), true, ModelAnswer.category("dining"), true),
      (reply(choice: "dining", ["dining": 0.97, "groceries": 0.01]), false, ModelAnswer.category("dining"), false),
      (reply(choice: "dining", ["dining": 0.75, "groceries": 0.05]), true, ModelAnswer.category("dining"), false),
      (reply(choice: "dining", ["dining": 0.85, "groceries": 0.5]), true, ModelAnswer.category("dining"), false),
      (reply(choice: "dining", ["dining": 0.8, "groceries": 0.4]), true, ModelAnswer.category("dining"), true),
      (reply(choice: "unknown", ["unknown": 0.97, "dining": 0.01]), true, ModelAnswer.unknown, false),
      (reply(choice: "dining", ["dining": 0.97], tag: "cf-clef/2"), true, ModelAnswer.failed(.other), false),
    ])
  func graded(json: String, autoFile: Bool, want: ModelAnswer, wantAuto: Bool) async {
    let m = model(StubExchange(status: 200, json: json), autoFile: autoFile)
    let r = await m.suggestGraded(subject: "CAFE EXAMPLE JBR", allowed: builtinAllowed)
    #expect(r.answer == want)
    #expect(r.autoFile == wantAuto)
    #expect(await m.suggest(subject: "CAFE EXAMPLE JBR", allowed: builtinAllowed) == want)
  }

  @Test("an HTTP error never auto-files")
  func httpError() async {
    let r = await model(StubExchange(status: 429, json: "{}"), autoFile: true)
      .suggestGraded(subject: "CAFE EXAMPLE JBR", allowed: builtinAllowed)
    #expect(r.answer == .failed(.rateLimited) && !r.autoFile)
  }

  @Test("the thresholds")
  func thresholds() {
    #expect(CloudCategoryModel.suggestThreshold == (minimum: 0.6, margin: 0.2))
    #expect(CloudCategoryModel.autoFileThreshold == (minimum: 0.8, margin: 0.4))
  }
}

@Test func cloudModelIsGraded() {
  let model: any CategoryModel = CloudCategoryModel(
    baseURL: URL(string: "https://assist.hasala.app")!, clientVersion: "1.0.0", isEnabled: { true }, isAutoFileEnabled: { true },
    exchange: URLSessionCloudExchange())
  #expect(model is any GradedCategoryModel)
  #expect(ModelTier.mayAutoFile(modelTag: model.modelTag))
}
