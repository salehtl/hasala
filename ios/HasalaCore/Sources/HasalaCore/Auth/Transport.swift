// The HTTP seam (spec 04 §2.7 `Transport`; `02` §6).
//
// Spec 04 §2.7 lists `Transport` under CoreSync, while §2.2 gives CoreAuth an
// `AuthClient` "over Transport" one layer below. The protocol therefore lives
// here, in CoreAuth (L1), and CoreSync re-exports it; the shapes are §2.7's.
//
// A transport never throws on a non-2xx status: the status and body come back
// for the caller's error table (spec 04 §5.5). It throws only when no response
// arrived.
import Foundation

/// One API call. `path` is the path and query below the API base
/// (`/api/v1/sync?stream=hot&after=0&limit=500`); credentials never go in it
/// (`02` §6.1).
public struct APIRequest: Sendable, Hashable {
  public enum Method: String, Sendable, Hashable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"
  }

  public let method: Method
  public let path: String
  /// A JSON body (`Content-Type: application/json`), or `nil`.
  public let body: Data?
  /// The session token, sent only as `Authorization: Bearer` (spec 04 §6.4).
  public let bearer: String?

  public init(method: Method, path: String, body: Data? = nil, bearer: String? = nil) {
    self.method = method
    self.path = path
    self.body = body
    self.bearer = bearer
  }
}

public struct APIResponse: Sendable, Hashable {
  public let status: Int
  /// Header names lower-cased.
  public let headers: [String: String]
  public let body: Data

  public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
    self.status = status
    var h: [String: String] = [:]
    for (k, v) in headers { h[asciiLower(k)] = v }
    self.headers = h
    self.body = body
  }

  /// `Hasala-Request-Id` (`02` §6.2): the only correlator a tester reports.
  public var requestID: String? { headers["hasala-request-id"] }

  /// `Retry-After` in whole seconds, when present and numeric.
  public var retryAfterSeconds: Int? { headers["retry-after"].flatMap { Int($0) } }

  /// The HTTP `Date` header, as sent (advisory only, spec 04 §5.4).
  public var date: String? { headers["date"] }
}

public enum TransportError: Error, Sendable, Hashable {
  /// No response: no network, DNS, timeout, connection lost.
  case offline(URLError.Code)
  case cancelled
  /// The TLS handshake or the server's certificate failed.
  case tls
}

public protocol Transport: Sendable {
  func send(_ request: APIRequest) async throws(TransportError) -> APIResponse
}

func asciiLower(_ s: String) -> String {
  String(decoding: s.utf8.map { (0x41...0x5a).contains($0) ? $0 + 0x20 : $0 }, as: UTF8.self)
}
