// JSON over `Transport` (`02` §6): bodies are JSON objects, errors are
// `{"error":"<code>","detail":"…"}` (§6.2), and every refusal comes back as an
// `APIFailure` carrying its status and code so each caller applies its own
// table (spec 04 §5.5, §6.1.5). Nothing here retries.
import Foundation

/// A non-2xx answer (`02` §6.2–§6.3).
public struct APIFailure: Error, Sendable, Hashable {
  public let status: Int
  /// The closed error code (`02` §6.3), e.g. `unauthorized`, `conflict`.
  public let code: String
  /// Only about the caller's own submission; empty on 401/403.
  public let detail: String
  public let retryAfterSeconds: Int?
  public let requestID: String?

  public init(status: Int, code: String, detail: String = "", retryAfterSeconds: Int? = nil, requestID: String? = nil) {
    self.status = status
    self.code = code
    self.detail = detail
    self.retryAfterSeconds = retryAfterSeconds
    self.requestID = requestID
  }

  /// Reads a refusal body; a body that is not `02`'s shape keeps the status
  /// with the code `"http_<status>"`.
  public static func from(_ r: APIResponse) -> APIFailure {
    struct Body: Decodable {
      let error: String?
      let detail: String?
    }
    let b = try? JSONDecoder().decode(Body.self, from: r.body)
    return APIFailure(
      status: r.status, code: b?.error ?? "http_\(r.status)", detail: b?.detail ?? "",
      retryAfterSeconds: r.retryAfterSeconds, requestID: r.requestID)
  }
}

public enum APIError: Error, Sendable, Hashable {
  /// No response arrived.
  case transport(TransportError)
  /// The server answered with a refusal.
  case refused(APIFailure)
  /// A 2xx whose body is not the documented shape: a protocol error
  /// (offline-class, retried; never shown as tampering).
  case malformed(String)

  public var failure: APIFailure? {
    if case .refused(let f) = self { return f }
    return nil
  }

  /// Whether the answer is `status` with `code`.
  public func `is`(_ status: Int, _ code: String) -> Bool {
    failure.map { $0.status == status && $0.code == code } ?? false
  }
}

/// An empty JSON object, for `{}` bodies and 204 answers.
public struct Empty: Codable, Sendable, Hashable {
  public init() {}
}

public struct APIClient: Sendable {
  public let transport: any Transport

  public init(transport: any Transport) { self.transport = transport }

  /// Sends and returns the raw response, throwing only for transport failures.
  public func send(_ request: APIRequest) async throws(APIError) -> APIResponse {
    do {
      return try await transport.send(request)
    } catch {
      throw .transport(error)
    }
  }

  /// Sends a JSON call and decodes a 2xx body as `Res` (`Empty` for 204).
  public func call<Res: Decodable>(
    _ method: APIRequest.Method, _ path: String, body: Data? = nil, bearer: String? = nil, as: Res.Type = Res.self
  ) async throws(APIError) -> Res {
    let r = try await send(APIRequest(method: method, path: path, body: body, bearer: bearer))
    guard (200..<300).contains(r.status) else { throw .refused(APIFailure.from(r)) }
    if Res.self == Empty.self, r.body.isEmpty || r.status == 204 { return Empty() as! Res }
    do {
      return try JSONDecoder().decode(Res.self, from: r.body)
    } catch {
      throw .malformed("\(method.rawValue) \(Self.routeName(path)): unexpected body")
    }
  }

  /// `call` with an `Encodable` body.
  public func call<Req: Encodable, Res: Decodable>(
    _ method: APIRequest.Method, _ path: String, json: Req, bearer: String? = nil, as: Res.Type = Res.self
  ) async throws(APIError) -> Res {
    try await call(method, path, body: try Self.encode(json), bearer: bearer, as: Res.self)
  }

  public static func encode(_ v: some Encodable) throws(APIError) -> Data {
    do {
      let e = JSONEncoder()
      e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      return try e.encode(v)
    } catch {
      throw .malformed("request body did not encode")
    }
  }

  /// The path without its query, for messages that must not carry values.
  static func routeName(_ path: String) -> String {
    String(path.split(separator: "?", maxSplits: 1).first ?? "")
  }
}
