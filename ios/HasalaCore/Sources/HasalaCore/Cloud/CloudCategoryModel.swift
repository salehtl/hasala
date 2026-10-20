import CoreCategorize
import Foundation
import Synchronization

public struct CloudCategoryModel: GradedCategoryModel {
  public static let defaultTag = "cf-clef/1"
  public static let subjectLimit = 128
  public static let suggestThreshold = (minimum: 0.6, margin: 0.2)
  public static let autoFileThreshold = (minimum: 0.8, margin: 0.4)

  public let modelTag: String
  let endpoint: URL
  let clientVersion: String
  let isEnabled: @Sendable () -> Bool
  let isAutoFileEnabled: @Sendable () -> Bool
  let exchange: any CloudHTTPExchange
  let pause: @Sendable () async -> Void
  let latch = Latch()

  public init(
    baseURL: URL, clientVersion: String, isEnabled: @escaping @Sendable () -> Bool,
    isAutoFileEnabled: @escaping @Sendable () -> Bool, exchange: any CloudHTTPExchange,
    pause: @escaping @Sendable () async -> Void = CloudCategoryModel.jitter
  ) {
    self.modelTag = Self.defaultTag
    self.endpoint = baseURL.appending(path: "v1/category")
    self.clientVersion = clientVersion
    self.isEnabled = isEnabled
    self.isAutoFileEnabled = isAutoFileEnabled
    self.exchange = exchange
    self.pause = pause
  }

  static let jitterRange = 100...400

  @Sendable public static func jitter() async {
    try? await Task.sleep(for: .milliseconds(Int.random(in: jitterRange)))
  }

  public func availability() -> ModelAvailability {
    if latch.isOff { return .notEligible }
    return isEnabled() ? .available : .notEnabled
  }

  public func suggest(subject: String, allowed: [AllowedCategory]) async -> ModelAnswer {
    await suggestGraded(subject: subject, allowed: allowed).answer
  }

  public func suggestGraded(subject: String, allowed: [AllowedCategory]) async -> (answer: ModelAnswer, autoFile: Bool) {
    let answer = await ask(subject: subject, allowed: allowed)
    guard case .category = answer.answer, answer.autoFile, isAutoFileEnabled() else { return (answer.answer, false) }
    return (answer.answer, true)
  }

  func ask(subject: String, allowed: [AllowedCategory]) async -> (answer: ModelAnswer, autoFile: Bool) {
    let sent = allowed.compactMap { a in
      TaxonomyV1.builtin(a.id).map { AllowedCategory(id: a.id, name: $0.name, hint: a.hint) }
    }
    guard !sent.isEmpty else { return (.unknown, false) }
    if latch.isOff { return (.failed(.refused), false) }
    if Task.isCancelled { return (.failed(.timeout), false) }
    await pause()
    if Task.isCancelled { return (.failed(.timeout), false) }
    guard isEnabled() else { return (.failed(.notEnabled), false) }
    if latch.isOff { return (.failed(.refused), false) }
    let body: Data
    do {
      body = try Self.encodeBody(subject: subject, categories: sent)
    } catch {
      return (.failed(.other), false)
    }
    let request = CloudRequest(
      url: endpoint, method: "POST",
      headers: ["Content-Type": "application/json", "Hasala-Client": "ios/\(clientVersion)"], body: body)
    let response: CloudResponse
    do {
      response = try await exchange.send(request)
    } catch {
      switch error {
      case .timedOut, .cancelled: return (.failed(.timeout), false)
      case .transport: return (.failed(.other), false)
      }
    }
    if Task.isCancelled { return (.failed(.timeout), false) }
    switch response.status {
    case 200: return decide(response.body, sent: sent)
    case 403:
      latch.trip()
      return (.failed(.refused), false)
    case 400, 413: return (.failed(.refused), false)
    case 429: return (.failed(.rateLimited), false)
    case 503: return (.failed(.busy), false)
    case 502: return (.failed(.decoding), false)
    default: return (.failed(.other), false)
    }
  }

  func decide(_ data: Data, sent: [AllowedCategory]) -> (answer: ModelAnswer, autoFile: Bool) {
    guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else { return (.failed(.decoding), false) }
    guard reply.tag == modelTag else { return (.failed(.other), false) }
    return Self.grade(choice: reply.choice, probabilities: reply.probabilities, sent: sent.map(\.id))
  }

  public static func gate(choice: String, probabilities: [String: Double], sent: [String]) -> ModelAnswer {
    grade(choice: choice, probabilities: probabilities, sent: sent).answer
  }

  public static func grade(choice: String, probabilities: [String: Double], sent: [String]) -> (answer: ModelAnswer, autoFile: Bool) {
    guard choice != "unknown", sent.contains(choice), let p = probabilities[choice], p.isFinite else { return (.unknown, false) }
    let second = probabilities.filter { $0.key != choice && $0.value.isFinite }.map(\.value).max() ?? 0
    func passes(_ t: (minimum: Double, margin: Double)) -> Bool {
      let epsilon = 1e-9
      return p + epsilon >= t.minimum && p - second + epsilon >= t.margin
    }
    guard passes(suggestThreshold) else { return (.unknown, false) }
    return (.category(choice), passes(autoFileThreshold))
  }

  public static func requestSubject(_ subject: String) -> String {
    let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
    var out = String.UnicodeScalarView()
    out.append(contentsOf: trimmed.unicodeScalars.prefix(subjectLimit))
    return String(out)
  }

  static func encodeBody(subject: String, categories: [AllowedCategory]) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(
      Body(subject: requestSubject(subject), categories: categories.map { Body.Category(id: $0.id, name: $0.name, hint: $0.hint) }))
  }

  struct Body: Encodable {
    struct Category: Encodable {
      let id: String
      let name: String
      let hint: String?

      enum CodingKeys: String, CodingKey { case id, name, hint }

      func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        if let hint { try c.encode(hint, forKey: .hint) } else { try c.encodeNil(forKey: .hint) }
      }
    }
    let subject: String
    let categories: [Category]
  }

  struct Reply: Decodable {
    let tag: String
    let choice: String
    let probabilities: [String: Double]
  }
}

final class Latch: Sendable {
  private let off = Mutex(false)

  var isOff: Bool { off.withLock { $0 } }

  func trip() { off.withLock { $0 = true } }
}

public enum HasalaCloudFactory {
  public static func makeCategoryModel(
    baseURL: URL?, clientVersion: String, isEnabled: @escaping @Sendable () -> Bool,
    isAutoFileEnabled: @escaping @Sendable () -> Bool
  ) -> (any CategoryModel)? {
    guard let baseURL else { return nil }
    return CloudCategoryModel(
      baseURL: baseURL, clientVersion: clientVersion, isEnabled: isEnabled, isAutoFileEnabled: isAutoFileEnabled,
      exchange: URLSessionCloudExchange())
  }
}
