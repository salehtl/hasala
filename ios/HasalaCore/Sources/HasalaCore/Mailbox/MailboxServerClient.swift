// hasalad's mailbox routes (spec 02 §7 routes 2, 34-38; §13.2), over an `HTTPExchange` that
// already carries the session (the composition root wraps the app's session transport). Times
// on the wire are RFC 3339 UTC with milliseconds (spec 02 §7 conventions). Error bodies are
// `{"error":"<code>"}`; only the code is kept.
import CoreJSON
import CoreTime
import Foundation

public struct HTTPMailboxServer: MailboxServer {
  let http: any HTTPExchange
  let base: String

  /// `base` is the API origin, e.g. `https://api.hasala.app`.
  public init(http: any HTTPExchange, base: String) {
    self.http = http
    self.base = base
  }

  func call(_ method: HTTPRequest.Method, _ path: String, body: JSONValue?) async throws(MailboxServerError)
    -> JSONObject
  {
    var headers = [("Accept", "application/json")]
    if body != nil { headers.append(("Content-Type", "application/json")) }
    let req = HTTPRequest(
      method: method, url: URL.build(base, path), headers: headers, body: body.map { Data(JSONWriter().bytes($0)) })
    let res: HTTPResponse
    do { res = try await http.send(req) } catch { throw .offline }
    let o = (try? JSONParser.parse([UInt8](res.body)))?.objectValue
    guard res.ok else {
      let code = o?["error"]?.stringValue ?? ""
      if res.status == 404 && code == "no_link" { throw .noLink }
      if res.status == 409 && code == "not_holder" { throw .notHolder }
      throw .refused(res.status, String(code.prefix(64)))
    }
    return o ?? JSONObject()
  }

  static func status(_ o: JSONObject) -> MailboxLinkStatus {
    let mine = o["holder"]?["is_this_device"]?.boolValue ?? false
    let watch = o["watch_expires_at"]?.stringValue.flatMap { try? parseInstantMs($0) }
    return .holder(isThisDevice: mine, watchExpiresAtMs: watch)
  }

  public func linkStatus() async throws(MailboxServerError) -> MailboxLinkStatus {
    do {
      return Self.status(try await call(.get, "/api/v1/mailbox/link", body: nil))
    } catch .noLink {
      return .noLink
    }
  }

  public func linkChallenge() async throws(MailboxServerError) -> String {
    let o = try await call(.post, "/api/v1/mailbox/link/challenge", body: .object(JSONObject()))
    guard let n = o["nonce"]?.stringValue, !n.isEmpty else { throw .refused(200, "bad_response") }
    return n
  }

  public func putLink(idToken: String, stepUp: JSONValue) async throws(MailboxServerError) -> MailboxLinkStatus {
    let body = JSONValue.object(JSONObject([("id_token", .string(idToken)), ("step_up", stepUp)]))
    return Self.status(try await call(.put, "/api/v1/mailbox/link", body: body))
  }

  public func putWatch(expiresAtMs: Int64) async throws(MailboxServerError) {
    guard let s = Instant.iso(expiresAtMs) else { throw .refused(0, "bad_expiry") }
    _ = try await call(.put, "/api/v1/mailbox/link/watch", body: .object(JSONObject([("expires_at", .string(s))])))
  }

  public func deleteLink(stepUp: JSONValue) async throws(MailboxServerError) {
    _ = try await call(.delete, "/api/v1/mailbox/link", body: .object(JSONObject([("step_up", stepUp)])))
  }

  public func watchTopic() async throws(MailboxServerError) -> String? {
    let o = try await call(.get, "/api/v1/meta", body: nil)
    guard let t = o["gmail_watch_topic"]?.stringValue, !t.isEmpty else { return nil }
    return t
  }
}
