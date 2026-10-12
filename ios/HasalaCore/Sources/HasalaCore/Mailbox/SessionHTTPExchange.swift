// The `HTTPExchange` hasalad's mailbox routes go through (`HTTPMailboxServer`,
// spec 02 routes 34-38 and #2): the app's session `Transport` with this
// account's bearer token.
//
// Only the request's path and query travel: the transport sends them to its own
// API origin with `Hasala-Client` (URLSessionTransport), and the bearer is read
// from `Secrets` on every call, so a request built for any other host can never
// carry the session there. A path must start with exactly one "/": a path
// starting "//" would be resolved against the origin as a network-path
// reference (a new host), so it is refused before any bearer is read, and
// nothing is sent. No session (or a pending logout) sends no bearer and
// the server answers 401; a Keychain that is unreadable right now (before first
// unlock) is `offline`, retried by the next trigger, never "signed out".
import CoreAuth
import CoreStore
import Foundation

public struct SessionHTTPExchange: HTTPExchange {
  let transport: any Transport
  let secrets: Secrets

  public init(transport: any Transport, secrets: Secrets) {
    self.transport = transport
    self.secrets = secrets
  }

  public func send(_ request: HTTPRequest) async throws(HTTPExchangeError) -> HTTPResponse {
    guard let parts = URLComponents(url: request.url, resolvingAgainstBaseURL: false) else { throw .offline }
    var path = parts.percentEncodedPath.isEmpty ? "/" : parts.percentEncodedPath
    guard Self.isOriginPath(path) else { throw .offline }
    if let q = parts.percentEncodedQuery, !q.isEmpty { path += "?" + q }
    let bearer: String?
    do {
      let s = try secrets.session()
      bearer = (s?.pending_logout ?? true) ? nil : s?.token
    } catch {
      throw .offline
    }
    let method: APIRequest.Method
    switch request.method {
    case .get: method = .get
    case .post: method = .post
    case .put: method = .put
    case .delete: method = .delete
    }
    do {
      let r = try await transport.send(APIRequest(method: method, path: path, body: request.body, bearer: bearer))
      return HTTPResponse(status: r.status, body: r.body)
    } catch {
      if error == .cancelled { throw .cancelled }
      throw .offline
    }
  }

  /// An absolute path on the transport's own origin: "/" then anything but a second "/".
  static func isOriginPath(_ path: String) -> Bool {
    let b = Array(path.utf8.prefix(2))
    return b.first == 0x2F && (b.count == 1 || b[1] != 0x2F)
  }
}
