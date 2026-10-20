// `Transport` over URLSession (spec 04 §2.3: CoreAuth and CoreSync may use
// URLSession through Foundation; §5.5 headers).
//
// Every request carries `Hasala-Client: ios/<version>/<build>` (`02` §6.1) and,
// when the call has a session, `Authorization: Bearer <token>`. The session is
// ephemeral: no cookies, no URL cache, no credential storage, so nothing about
// a call is written to disk by Foundation.
import Foundation

public final class URLSessionTransport: Transport, @unchecked Sendable {
  public let baseURL: URL
  public let clientHeader: String
  private let session: URLSession

  /// `baseURL` is the API origin (`https://api.hasala.app`); `clientHeader` is
  /// `ios/<CFBundleShortVersionString>/<CFBundleVersion>`.
  public convenience init(baseURL: URL, clientHeader: String, timeout: TimeInterval = 30) {
    self.init(baseURL: baseURL, clientHeader: clientHeader, timeout: timeout, protocolClasses: nil)
  }

  init(baseURL: URL, clientHeader: String, timeout: TimeInterval, protocolClasses: [AnyClass]?) {
    self.baseURL = baseURL
    self.clientHeader = clientHeader
    let c = URLSessionConfiguration.ephemeral
    c.httpCookieAcceptPolicy = .never
    c.httpShouldSetCookies = false
    c.urlCache = nil
    c.urlCredentialStorage = nil
    c.requestCachePolicy = .reloadIgnoringLocalCacheData
    c.timeoutIntervalForRequest = timeout
    c.waitsForConnectivity = false
    if let protocolClasses { c.protocolClasses = protocolClasses }
    session = URLSession(configuration: c, delegate: RefuseRedirects(), delegateQueue: nil)
  }

  deinit { session.invalidateAndCancel() }

  /// The request for `r`, or nil when `r.path` would leave `baseURL`'s origin:
  /// it must be an absolute path ("/" and not "//", which a URL resolver reads
  /// as a new host), and the resolved URL must keep the scheme, host and port,
  /// so the session's bearer only ever goes to the API.
  public func urlRequest(for r: APIRequest) -> URLRequest? {
    let lead = Array(r.path.utf8.prefix(2))
    guard lead.first == 0x2F, lead.count == 1 || lead[1] != 0x2F,
      let url = URL(string: r.path, relativeTo: baseURL)?.absoluteURL,
      url.scheme == baseURL.scheme, url.host == baseURL.host, url.port == baseURL.port
    else { return nil }
    var u = URLRequest(url: url)
    u.httpMethod = r.method.rawValue
    u.setValue(clientHeader, forHTTPHeaderField: "Hasala-Client")
    u.setValue("application/json", forHTTPHeaderField: "Accept")
    if let b = r.bearer { u.setValue("Bearer \(b)", forHTTPHeaderField: "Authorization") }
    if let body = r.body {
      u.httpBody = body
      u.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    return u
  }

  public func send(_ request: APIRequest) async throws(TransportError) -> APIResponse {
    guard let u = urlRequest(for: request) else { throw .offline(.badURL) }
    do {
      let (data, response) = try await session.data(for: u)
      guard let http = response as? HTTPURLResponse, !(300..<400).contains(http.statusCode) else {
        throw TransportError.offline(.badServerResponse)
      }
      var headers: [String: String] = [:]
      for (k, v) in http.allHeaderFields {
        if let k = k as? String, let v = v as? String { headers[k] = v }
      }
      return APIResponse(status: http.statusCode, headers: headers, body: data)
    } catch let e as TransportError {
      throw e
    } catch let e as URLError {
      throw Self.classify(e.code)
    } catch is CancellationError {
      throw .cancelled
    } catch {
      throw .offline(.unknown)
    }
  }

  static func classify(_ code: URLError.Code) -> TransportError {
    switch code {
    case .cancelled: .cancelled
    case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
      .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
      .clientCertificateRequired:
      .tls
    default: .offline(code)
    }
  }
}

final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}
