// The HTTP seam the Gmail lane talks through (spec 04 §2.3: CoreMailbox may use URLSession via
// Foundation; §7.2: every Google request uses an ephemeral session, no cookies, no URL cache).
//
// One protocol serves two hosts: Google (OAuth token endpoint and the Gmail REST API, through
// `URLSessionHTTPExchange.ephemeral()`), and hasalad's mailbox routes (through whatever
// session-authenticated exchange the composition root supplies, spec 02 routes 34-38). Tests
// answer it in process (CoreTestSupport's `FakeGmail`), so the request building and response
// parsing under test are the production code.
//
// Nothing here logs. A request may carry a bearer token or a refresh token; neither ever
// reaches a log line, an error value or a report (spec 04 §2.4 R7).
import Foundation

public struct HTTPRequest: Sendable, Equatable {
  public enum Method: String, Sendable {
    case get = "GET", post = "POST", put = "PUT", patch = "PATCH", delete = "DELETE"
  }
  public var method: Method
  public var url: URL
  public var headers: [(String, String)]
  public var body: Data?

  public init(method: Method, url: URL, headers: [(String, String)] = [], body: Data? = nil) {
    self.method = method
    self.url = url
    self.headers = headers
    self.body = body
  }

  public func header(_ name: String) -> String? { headerValue(headers, name) }

  public static func == (a: HTTPRequest, b: HTTPRequest) -> Bool {
    a.method == b.method && a.url == b.url && a.body == b.body
      && a.headers.elementsEqual(b.headers) { $0.0 == $1.0 && $0.1 == $1.1 }
  }
}

public struct HTTPResponse: Sendable, Equatable {
  public var status: Int
  public var body: Data
  /// The response headers a caller reads (`Retry-After`); empty where the transport keeps none.
  public var headers: [(String, String)]
  public init(status: Int, body: Data = Data(), headers: [(String, String)] = []) {
    self.status = status
    self.body = body
    self.headers = headers
  }
  public var ok: Bool { (200..<300).contains(status) }

  public func header(_ name: String) -> String? { headerValue(headers, name) }

  public static func == (a: HTTPResponse, b: HTTPResponse) -> Bool {
    a.status == b.status && a.body == b.body && a.headers.elementsEqual(b.headers) { $0.0 == $1.0 && $0.1 == $1.1 }
  }
}

/// Transport failures only: a non-2xx answer is a response, never a throw.
public enum HTTPExchangeError: Error, Sendable, Equatable {
  /// No route to the host, timed out, TLS refused: retried by the next trigger.
  case offline
  case cancelled
  case tooLarge
}

public protocol HTTPExchange: Sendable {
  func send(_ request: HTTPRequest) async throws(HTTPExchangeError) -> HTTPResponse
}

/// `URLSession` with the `.ephemeral` configuration: no cookie store, no URL cache, no
/// credential storage (spec 04 §7.2).
public final class URLSessionHTTPExchange: HTTPExchange {
  let session: URLSession
  let maxResponseBytes: Int?

  public init(configuration: URLSessionConfiguration, maxResponseBytes: Int? = nil) {
    session = URLSession(configuration: configuration)
    self.maxResponseBytes = maxResponseBytes
  }

  /// The configuration every Google request uses.
  public static func ephemeral(timeout: TimeInterval = 30, maxResponseBytes: Int? = nil) -> URLSessionHTTPExchange {
    let c = URLSessionConfiguration.ephemeral
    c.httpCookieStorage = nil
    c.httpShouldSetCookies = false
    c.urlCache = nil
    c.urlCredentialStorage = nil
    c.requestCachePolicy = .reloadIgnoringLocalCacheData
    c.timeoutIntervalForRequest = timeout
    c.waitsForConnectivity = false
    return URLSessionHTTPExchange(configuration: c, maxResponseBytes: maxResponseBytes)
  }

  public func send(_ request: HTTPRequest) async throws(HTTPExchangeError) -> HTTPResponse {
    var r = URLRequest(url: request.url)
    r.httpMethod = request.method.rawValue
    for (k, v) in request.headers { r.addValue(v, forHTTPHeaderField: k) }
    r.httpBody = request.body
    do {
      let (data, response) = try await load(r)
      guard let http = response as? HTTPURLResponse else { throw HTTPExchangeError.offline }
      var headers: [(String, String)] = []
      if let retry = http.value(forHTTPHeaderField: "Retry-After") { headers.append(("Retry-After", retry)) }
      return HTTPResponse(status: http.statusCode, body: data, headers: headers)
    } catch let e as HTTPExchangeError {
      throw e
    } catch is CancellationError {
      throw .cancelled
    } catch let e as URLError where e.code == .cancelled {
      throw .cancelled
    } catch {
      throw .offline
    }
  }

  func load(_ r: URLRequest) async throws -> (Data, URLResponse) {
    guard let cap = maxResponseBytes else { return try await session.data(for: r) }
    let (stream, response) = try await session.bytes(for: r)
    if response.expectedContentLength > Int64(cap) {
      stream.task.cancel()
      throw HTTPExchangeError.tooLarge
    }
    var bytes: [UInt8] = []
    bytes.reserveCapacity(min(cap, max(0, Int(clamping: response.expectedContentLength))))
    for try await b in stream {
      if bytes.count >= cap {
        stream.task.cancel()
        throw HTTPExchangeError.tooLarge
      }
      bytes.append(b)
    }
    return (Data(bytes), response)
  }
}

// MARK: - Encoding helpers

@inline(__always) func asciiLower(_ b: UInt8) -> UInt8 { (b >= 0x41 && b <= 0x5a) ? b + 0x20 : b }

func asciiLowered(_ s: String) -> String { String(decoding: s.utf8.map(asciiLower), as: UTF8.self) }

private func headerValue(_ headers: [(String, String)], _ name: String) -> String? {
  let want = Array(name.utf8).map(asciiLower)
  return headers.first { Array($0.0.utf8).map(asciiLower) == want }?.1
}

/// `application/x-www-form-urlencoded` and query-string encoding: every byte outside the RFC 3986
/// unreserved set is percent-encoded (space as `%20`, never `+`), so a Gmail query such as
/// `{from:a.ae from:b.ae} after:1700000000 -in:trash` reaches Google exactly as built.
public enum FormEncoding {
  static let unreserved: Set<UInt8> = Set(
    Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8))

  public static func escape(_ s: String) -> String {
    var out = ""
    for b in s.utf8 {
      if unreserved.contains(b) {
        out.unicodeScalars.append(Unicode.Scalar(b))
      } else {
        out += "%" + String(b, radix: 16, uppercase: true).leftPadded(2)
      }
    }
    return out
  }

  public static func encode(_ pairs: [(String, String)]) -> String {
    pairs.map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&")
  }

  /// Parses `a=b&c=d` (query or form body); `+` is a space; malformed escapes are kept verbatim.
  public static func decode(_ s: String) -> [(String, String)] {
    guard !s.isEmpty else { return [] }
    return s.split(separator: "&", omittingEmptySubsequences: true).map { part in
      let kv = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      let k = unescape(String(kv[0]))
      let v = kv.count > 1 ? unescape(String(kv[1])) : ""
      return (k, v)
    }
  }

  static func unescape(_ s: String) -> String {
    let plus = s.replacingOccurrences(of: "+", with: " ")
    return plus.removingPercentEncoding ?? plus
  }
}

extension String {
  fileprivate func leftPadded(_ n: Int) -> String {
    count >= n ? self : String(repeating: "0", count: n - count) + self
  }
}

extension URL {
  /// `base` + path + `?` + encoded query (no query when `query` is empty).
  static func build(_ base: String, _ path: String, _ query: [(String, String)] = []) -> URL {
    let q = query.isEmpty ? "" : "?" + FormEncoding.encode(query)
    // The pieces are fixed ASCII plus percent-encoded values, so this never fails.
    return URL(string: base + path + q)!
  }
}
