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

  /// `base` is the API origin, e.g. `https://api.hasala.app` (a trailing "/"
  /// is dropped, so paths never start with "//").
  public init(http: any HTTPExchange, base: String) {
    self.http = http
    var b = Substring(base)
    while b.hasSuffix("/") { b = b.dropLast() }
    self.base = String(b)
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
      if res.status == 409 && code == "no_watch_topic" { throw .noWatchTopic }
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

  /// Route 37 with the link's provider (`provider`; absent from a server before the Outlook
  /// link, which links only Gmail). The provider is nil with no link.
  public func linkStatusAndProvider() async throws(MailboxServerError) -> (MailboxLinkStatus, MailProviderID?) {
    do {
      let o = try await call(.get, "/api/v1/mailbox/link", body: nil)
      return (Self.status(o), MailProviderID(rawValue: o["provider"]?.stringValue ?? "gmail"))
    } catch .noLink {
      return (.noLink, nil)
    }
  }

  public func linkStatus(provider: MailProviderID) async throws(MailboxServerError) -> MailboxLinkStatus {
    let (status, linked) = try await linkStatusAndProvider()
    if let linked, linked != provider { throw .otherProvider }
    return status
  }

  public func linkChallenge() async throws(MailboxServerError) -> String {
    let o = try await call(.post, "/api/v1/mailbox/link/challenge", body: .object(JSONObject()))
    guard let n = o["nonce"]?.stringValue, !n.isEmpty else { throw .refused(200, "bad_response") }
    return n
  }

  /// `provider` is omitted for Gmail (the route's default), so a server from before the Outlook
  /// link, which refuses unknown fields, still accepts a Gmail link.
  public func putLink(provider: MailProviderID, idToken: String, stepUp: JSONValue) async throws(MailboxServerError)
    -> MailboxLinkResult
  {
    var fields: [(String, JSONValue)] = []
    if provider != .gmail { fields.append(("provider", .string(provider.rawValue))) }
    fields += [("id_token", .string(idToken)), ("step_up", stepUp)]
    let o = try await call(.put, "/api/v1/mailbox/link", body: .object(JSONObject(fields)))
    let cs = o["client_state"]?.stringValue
    return MailboxLinkResult(status: Self.status(o), clientState: (cs?.isEmpty ?? true) ? nil : cs)
  }

  public func putWatch(expiresAtMs: Int64) async throws(MailboxServerError) {
    guard let s = Instant.iso(expiresAtMs) else { throw .refused(0, "bad_expiry") }
    _ = try await call(.put, "/api/v1/mailbox/link/watch", body: .object(JSONObject([("expires_at", .string(s))])))
  }

  public func deleteLink(stepUp: JSONValue) async throws(MailboxServerError) {
    _ = try await call(.delete, "/api/v1/mailbox/link", body: .object(JSONObject([("step_up", stepUp)])))
  }

  public func pushConfig(provider: MailProviderID) async throws(MailboxServerError) -> MailboxPushConfig {
    let o = try await call(.get, "/api/v1/meta", body: nil)
    func field(_ k: String) -> String? {
      guard let v = o[k]?.stringValue, !v.isEmpty else { return nil }
      return v
    }
    switch provider {
    case .gmail:
      guard let t = field("gmail_watch_topic") else { return .none }
      return .gmail(topic: t)
    case .outlook:
      guard let n = field("outlook_notification_url"), let l = field("outlook_lifecycle_url") else { return .none }
      return .outlook(notificationURL: n, lifecycleURL: l)
    }
  }
}
