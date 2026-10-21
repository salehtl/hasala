// FakeGmail: an in-process fake of Google's OAuth token endpoint and the Gmail REST surface the
// lane uses (spec 04 §2.2 CoreTestSupport; port of reference/ledgerd-pwa/harness/fakegmail.mjs
// semantics, narrowed to PO G's sender-filtered listing).
//
// It answers `HTTPExchange`, so the request building and response parsing under test are the
// production `GmailClient` / `GoogleOAuthClient` code. Behaviour kept from fakegmail.mjs:
//   - a refresh token only on the authorization_code grant, never echoed on a refresh;
//   - an `invalid_grant` knob for both /token and /revoke;
//   - an id_token that is a real three-part JWT (alg "none") carrying `email` and the `nonce`
//     of the last authorize URL, as Google does;
//   - raw messages served base64url and UNPADDED.
// Added for PO G: `messages.list` evaluates the lane's query shape
// (`{from:a from:b} after:<sec> -in:trash`) against each message's From domain (subdomains
// match, the AT-GMAIL-10 assumption) and internalDate; an unfiltered listing is answered 400 so
// a test fails loudly if the client ever sends one. Every request is recorded.
//
// SYNTHETIC mail only (`SyntheticMail`): hand-written DIB- and ENBD-shaped alerts with fictional
// amounts, cards and merchants. Real mail is never in this repository.
import CoreJSON
import CoreMailbox
import CorePrimitives
import Foundation

public final class FakeGmail: HTTPExchange, @unchecked Sendable {
  public struct Message: Sendable {
    public var id: String
    public var raw: [UInt8]
    public var internalDateMs: Int64
    public var trashed = false
    public var spam = false
    /// The From header value (for listing); parsed from `raw` when built with `SyntheticMail`.
    public var from: String

    public init(id: String, raw: [UInt8], internalDateMs: Int64, from: String, trashed: Bool = false) {
      self.id = id
      self.raw = raw
      self.internalDateMs = internalDateMs
      self.from = from
      self.trashed = trashed
    }
  }

  public struct Recorded: Sendable {
    public let method: String
    public let path: String
    public let query: [(String, String)]
    public let form: [(String, String)]
    public let authorization: String?
  }

  private let lock = NSLock()
  private var messages: [String: Message] = [:]
  private var order: [String] = []
  private var _requests: [Recorded] = []
  private var failures: [String: [(status: Int, reason: String?)]] = [:]
  private var lastNonce = ""

  public var historyID = "1000"
  public var email = "synthetic.user@example.com"
  public var accessToken = "fake-access-token"
  public var refreshToken = "fake-refresh-token"
  public var expiresIn: Int64 = 3600
  public var invalidGrant = false
  /// Drop the gmail.readonly scope from the token response (a granular-consent untick).
  public var omitGmailScope = false
  public var omitRefreshToken = false
  public var pageSize = 100
  public var watchExpirationMs: Int64 = 0
  public var noMailbox = false
  /// When true every transport call fails (`HTTPExchangeError.offline`).
  public var offline = false
  /// Asked before every Gmail API request with its path: a status answers it with Google's
  /// rate-limit body (reason `rateLimitExceeded`), nil serves it. A test's model of the
  /// per-user quota (250 units a second, a moving average).
  public var limiter: (@Sendable (_ path: String) -> Int?)?

  public static let tokenURL = "https://oauth2.googleapis.com/token"
  public static let revokeURL = "https://oauth2.googleapis.com/revoke"

  public init() {}

  // MARK: Scripting

  public func add(_ m: Message) {
    lock.withLock {
      if messages[m.id] == nil { order.append(m.id) }
      messages[m.id] = m
    }
  }

  public func remove(_ id: String) {
    lock.withLock {
      messages[id] = nil
      order.removeAll { $0 == id }
    }
  }

  /// The next answers for any request whose path contains `pathContains` (e.g. a message id):
  /// each status is used once, then the request is served normally. `reason` goes in Google's
  /// error body (`error.errors[0].reason`, e.g. "userRateLimitExceeded" on a 403).
  public func fail(_ pathContains: String, with statuses: [Int], reason: String? = nil) {
    lock.withLock { failures[pathContains, default: []].append(contentsOf: statuses.map { ($0, reason) }) }
  }

  public var requests: [Recorded] { lock.withLock { _requests } }
  public func clearRequests() { lock.withLock { _requests = [] } }
  public var nonce: String { lock.withLock { lastNonce } }

  /// The fake consent page: records the nonce and answers the redirect with a code.
  public func consent(authorizeURL: URL) -> URL {
    let c = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)
    func q(_ n: String) -> String { c?.queryItems?.first { $0.name == n }?.value ?? "" }
    lock.withLock { lastNonce = q("nonce") }
    var back = URLComponents(string: q("redirect_uri"))!
    back.queryItems = [URLQueryItem(name: "code", value: "fake-auth-code"), URLQueryItem(name: "state", value: q("state"))]
    return back.url!
  }

  // MARK: HTTPExchange

  public func send(_ request: HTTPRequest) async throws(HTTPExchangeError) -> HTTPResponse {
    if lock.withLock({ offline }) { throw .offline }
    let comps = URLComponents(url: request.url, resolvingAgainstBaseURL: false)!
    let query = FormEncoding.decode(comps.percentEncodedQuery ?? "")
    let form = FormEncoding.decode(String(decoding: request.body ?? Data(), as: UTF8.self))
    let path = comps.path
    lock.withLock {
      _requests.append(
        Recorded(
          method: request.method.rawValue, path: path, query: query, form: form,
          authorization: request.header("Authorization")))
    }
    if path.hasPrefix("/gmail/"), let status = lock.withLock({ limiter })?(path) {
      return json(
        status,
        [
          "error": .object(
            JSONObject([
              ("code", .number(JSONNumber(Int64(status)))),
              ("errors", .array([.object(JSONObject([("domain", .string("usageLimits")), ("reason", .string("rateLimitExceeded"))]))])),
            ]))
        ])
    }
    let keyed = path + (query.first { $0.0 == "format" }.map { "?format=\($0.1)" } ?? "")
    if let failure = lock.withLock({ () -> (status: Int, reason: String?)? in
      for (k, v) in failures where !v.isEmpty && keyed.contains(k) {
        failures[k] = Array(v.dropFirst())
        return v[0]
      }
      return nil
    }) {
      var error: [(String, JSONValue)] = [("code", .number(JSONNumber(Int64(failure.status))))]
      if let r = failure.reason {
        error.append(("errors", .array([.object(JSONObject([("domain", .string("usageLimits")), ("reason", .string(r))]))])))
      }
      return json(failure.status, ["error": .object(JSONObject(error))])
    }
    let full = request.url.absoluteString
    if full.hasPrefix(Self.tokenURL) { return token(form) }
    if full.hasPrefix(Self.revokeURL) { return lock.withLock { invalidGrant } ? json(400, ["error": .string("invalid_grant")]) : HTTPResponse(status: 200) }
    let base = "/gmail/v1/users/me"
    guard path.hasPrefix(base) else { return json(404, ["error": .string("not_found")]) }
    let sub = String(path.dropFirst(base.count))
    func q(_ n: String) -> String? { query.first { $0.0 == n }?.1 }
    if lock.withLock({ noMailbox }) { return Self.noMailboxResponse() }
    switch (request.method, sub) {
    case (.get, "/profile"):
      return json(200, ["historyId": .string(lock.withLock { historyID })])
    case (.get, "/messages"):
      return list(q: q("q") ?? "", pageToken: q("pageToken"), max: Int(q("maxResults") ?? "") ?? 100)
    case (.post, "/watch"):
      let exp = lock.withLock { watchExpirationMs }
      return json(200, ["historyId": .string(lock.withLock { historyID }), "expiration": .string(String(exp))])
    case (.post, "/stop"):
      return HTTPResponse(status: 204)
    default:
      guard request.method == .get, sub.hasPrefix("/messages/") else { return json(404, ["error": .string("not_found")]) }
      let id = FormEncoding.unescapeComponent(String(sub.dropFirst("/messages/".count)))
      guard let m = lock.withLock({ messages[id] }) else { return json(404, ["error": .string("not_found")]) }
      switch q("format") {
      case "raw":
        let labels: [JSONValue] = m.spam ? [.string("SPAM"), .string("UNREAD")] : [.string("INBOX"), .string("UNREAD")]
        return json(
          200,
          [
            "id": .string(id), "internalDate": .string(String(m.internalDateMs)), "labelIds": .array(labels),
            "raw": .string(Base64.encodeURL(m.raw)),
          ])
      case "metadata":
        let wanted = query.filter { $0.0 == "metadataHeaders" }.map { $0.1.lowercased() }
        let headers = Self.headers(m.raw).filter { wanted.contains($0.0.lowercased()) }.map {
          JSONValue.object(JSONObject([("name", .string($0.0)), ("value", .string($0.1))]))
        }
        return json(
          200,
          [
            "id": .string(id), "internalDate": .string(String(m.internalDateMs)),
            "sizeEstimate": .number(JSONNumber(Int64(m.raw.count))),
            "payload": .object(JSONObject([("headers", .array(headers))])),
          ])
      default:
        return json(400, ["error": .string("fakegmail serves only format=raw and format=metadata")])
      }
    }
  }

  // MARK: Internals

  public static let noMailboxBody =
    #"{"error":{"code":400,"message":"Mail service not enabled","errors":[{"message":"Mail service not enabled","domain":"global","reason":"failedPrecondition"}],"status":"FAILED_PRECONDITION"}}"#

  static func noMailboxResponse() -> HTTPResponse {
    HTTPResponse(status: 400, body: Data(noMailboxBody.utf8), headers: [("Content-Type", "application/json")])
  }

  func token(_ form: [(String, String)]) -> HTTPResponse {
    func f(_ n: String) -> String { form.first { $0.0 == n }?.1 ?? "" }
    return lock.withLock {
      if invalidGrant {
        return json(400, ["error": .string("invalid_grant"), "error_description": .string("Token has been expired or revoked.")])
      }
      var body: [String: JSONValue] = [
        "access_token": .string(accessToken), "expires_in": .number(JSONNumber(expiresIn)),
        "token_type": .string("Bearer"),
        "scope": .string(omitGmailScope ? "openid email" : "openid https://www.googleapis.com/auth/gmail.readonly email"),
      ]
      if f("grant_type") == "authorization_code" {
        guard !f("code_verifier").isEmpty, !f("code").isEmpty else { return json(400, ["error": .string("invalid_request")]) }
        if !omitRefreshToken { body["refresh_token"] = .string(refreshToken) }
        body["id_token"] = .string(Self.idToken(email: email, nonce: lastNonce))
      } else if f("grant_type") == "refresh_token" {
        guard f("refresh_token") == refreshToken else { return json(400, ["error": .string("invalid_grant")]) }
      }
      return json(200, body)
    }
  }

  public static func idToken(email: String, nonce: String) -> String {
    func b64(_ o: JSONObject) -> String { Base64.encodeURL(JSONWriter().bytes(.object(o))) }
    let header = b64(JSONObject([("alg", .string("none")), ("typ", .string("JWT"))]))
    let payload = b64(
      JSONObject([
        ("iss", .string("https://accounts.google.com")), ("aud", .string("fake-client")),
        ("sub", .string("fake-subject-000")), ("email", .string(email)), ("email_verified", .bool(true)),
        ("nonce", .string(nonce)),
      ]))
    return "\(header).\(payload)."
  }

  func list(q: String, pageToken: String?, max: Int) -> HTTPResponse {
    guard let parsed = Self.parseQuery(q) else {
      return json(400, ["error": .string("fakegmail: only the lane's sender-filtered query is served")])
    }
    return lock.withLock {
      let matching = order.compactMap { messages[$0] }.filter { m in
        if m.trashed && parsed.excludeTrash { return false }
        if m.internalDateMs / 1000 <= parsed.after { return false }
        let d = BankDomains.domainOf(m.from)
        return BankDomains.isMember(d, of: parsed.from)
      }
      // Gmail lists newest first.
      let sorted = matching.sorted { $0.internalDateMs > $1.internalDateMs }
      let start = Int(pageToken ?? "0") ?? 0
      let size = Swift.min(max, pageSize)
      let page = Array(sorted.dropFirst(start).prefix(size))
      var body: [String: JSONValue] = [
        "messages": .array(page.map { .object(JSONObject([("id", .string($0.id))])) })
      ]
      if start + size < sorted.count { body["nextPageToken"] = .string(String(start + size)) }
      return json(200, body)
    }
  }

  struct Query {
    var from: [String]
    var after: Int64
    var excludeTrash: Bool
  }

  /// `{from:a from:b} after:N -in:trash`; nil for anything without a from: group.
  static func parseQuery(_ q: String) -> Query? {
    guard let open = q.firstIndex(of: "{"), let close = q.firstIndex(of: "}"), open < close else { return nil }
    let terms = q[q.index(after: open)..<close].split(separator: " ")
    var from: [String] = []
    for t in terms {
      guard t.hasPrefix("from:") else { return nil }
      from.append(String(t.dropFirst(5)))
    }
    guard !from.isEmpty else { return nil }
    let rest = q[q.index(after: close)...].split(separator: " ")
    var after: Int64 = 0
    var trash = false
    for t in rest {
      if t.hasPrefix("after:") { after = Int64(t.dropFirst(6)) ?? 0 }
      if t == "-in:trash" { trash = true }
    }
    return Query(from: from, after: after, excludeTrash: trash)
  }

  /// The header fields of a raw message, unfolded, in order.
  static func headers(_ raw: [UInt8]) -> [(String, String)] {
    let text = String(decoding: raw, as: UTF8.self)
    let block = headerBlockOf(text)
    var out: [(String, String)] = []
    for line in block.components(separatedBy: "\r\n") {
      if line.first == " " || line.first == "\t", !out.isEmpty {
        out[out.count - 1].1 += line
      } else if let c = line.firstIndex(of: ":") {
        out.append((String(line[..<c]), String(line[line.index(after: c)...]).trimmingCharacters(in: .whitespaces)))
      }
    }
    return out
  }

  static func headerBlockOf(_ text: String) -> String {
    if let r = text.range(of: "\r\n\r\n") { return String(text[..<r.lowerBound]) }
    return text
  }

  func json(_ status: Int, _ o: [String: JSONValue]) -> HTTPResponse {
    let obj = JSONObject(o.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })
    return HTTPResponse(status: status, body: Data(JSONWriter().bytes(.object(obj))))
  }
}

extension FormEncoding {
  static func unescapeComponent(_ s: String) -> String { s.removingPercentEncoding ?? s }
}

/// Hand-written DIB- and ENBD-shaped alerts. Every value is fictional.
public enum SyntheticMail {
  public static let defaultTo = "synthetic.user@example.com"

  /// A text/plain RFC 822 message. `authDomain` nil omits the Authentication-Results header;
  /// `arTopmost` false puts a foreign A-R above Gmail's (verdict `not_topmost`).
  public static func rfc822(
    from: String, subject: String, body: String, dateMs: Int64, authDomain: String?, arTopmost: Bool = true,
    dkimPass: Bool = true, to: String? = defaultTo, signedHeaders: String = "From:To:Subject"
  ) -> [UInt8] {
    var h: [String] = []
    if let d = authDomain {
      if !arTopmost { h.append("Authentication-Results: relay.example.net; dkim=pass header.d=\(d)") }
      let fromDomain = BankDomains.domainOf(from)
      let verdict =
        dkimPass
        ? "dkim=pass header.d=\(d) header.s=synthetic header.b=c3ludGhl; dmarc=pass header.from=\(fromDomain); spf=pass"
        : "dkim=fail header.d=\(d); spf=fail"
      h.append("Authentication-Results: mx.google.com; \(verdict)")
    }
    h.append("Delivered-To: \(defaultTo)")
    if let d = authDomain {
      h.append("DKIM-Signature: v=1; a=rsa-sha256; d=\(d); s=synthetic;\r\n\th=\(signedHeaders); bh=c3ludGhldGlj;\r\n\tb=c3ludGhldGljc2lnbmF0dXJl")
    }
    h.append("From: \(from)")
    if let to { h.append("To: \(to)") }
    h += [
      "Subject: \(subject)",
      "Message-ID: <\(dateMs).synthetic@example.invalid>", "MIME-Version: 1.0",
      "Content-Type: text/plain; charset=\"utf-8\"", "Content-Transfer-Encoding: 8bit",
    ]
    return Array((h.joined(separator: "\r\n") + "\r\n\r\n" + body.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n").utf8)
  }

  /// A DIB card purchase alert (dib.card.v1's shape; body date DD-MM-YYYY).
  public static func dibCard(
    id: String, amount: String = "250.00", day: String = "05-06-2026", merchant: String = "SYNTHETIC GROCER DUBAI",
    last4: String = "1234", dateMs: Int64, authDomain: String? = "dib.ae", fromDomain: String = "dib.ae",
    arTopmost: Bool = true, to: String? = defaultTo, signedHeaders: String = "From:To:Subject"
  ) -> FakeGmail.Message {
    let body = "إشعار مشتريات\nالمبلغ\nAED \(amount)\nبتاريخ \(day)\nالدفع الى\n\(merchant)\nرقم البطاقة\nXXXX\(last4)"
    let from = "DIB Alerts <alerts@\(fromDomain)>"
    return FakeGmail.Message(
      id: id,
      raw: rfc822(from: from, subject: "Card transaction", body: body, dateMs: dateMs, authDomain: authDomain, arTopmost: arTopmost,
        to: to, signedHeaders: signedHeaders),
      internalDateMs: dateMs, from: from)
  }

  /// An ENBD account debit alert (enbd.alert.v1's shape; dated from the email).
  public static func enbdAlert(
    id: String, amount: String = "12.34", last4: String = "8642", dateMs: Int64,
    authDomain: String? = "emiratesnbd.com", fromDomain: String = "emiratesnbd.com"
  ) -> FakeGmail.Message {
    let from = "Emirates NBD <alerts@\(fromDomain)>"
    return FakeGmail.Message(
      id: id,
      raw: rfc822(
        from: from, subject: "Transaction advice for your account ending with \(last4)",
        body: "AED \(amount) has been debited from your account 012XXX34XXX56.", dateMs: dateMs, authDomain: authDomain),
      internalDateMs: dateMs, from: from)
  }

  /// A bank-domain message no template reads (the empty review shape).
  public static func bankNotice(id: String, dateMs: Int64, domain: String = "emiratesnbd.com") -> FakeGmail.Message {
    let from = "Emirates NBD <news@\(domain)>"
    return FakeGmail.Message(
      id: id,
      raw: rfc822(from: from, subject: "Your statement is ready", body: "Your monthly statement is ready to view.", dateMs: dateMs, authDomain: domain),
      internalDateMs: dateMs, from: from)
  }

  /// A look-alike sender the query matched by display name but whose domains are not banks.
  public static func lookAlike(id: String, dateMs: Int64, listedAs bankDomain: String) -> FakeGmail.Message {
    let from = "Offers <offers@\(bankDomain).promo.example>"
    return FakeGmail.Message(
      id: id,
      raw: rfc822(from: from, subject: "Win big", body: "Not a bank.", dateMs: dateMs, authDomain: "promo.example"),
      internalDateMs: dateMs, from: "Offers <offers@\(bankDomain)>")
  }
}

// MARK: - Through URLSession

/// Serves a `FakeGmail` (or any in-process fake, e.g. `FakeGraph`) to a real `URLSession` (spec
/// 04 §2.2 "FakeGmail (URLProtocol)"), so the production `URLSessionHTTPExchange` is exercised
/// too: request encoding, headers, status and body handling, with no socket and no network.
public final class FakeGmailURLProtocol: URLProtocol, @unchecked Sendable {
  static let header = "X-Hasala-Fake-Gmail"
  private static let registry = NSLock()
  nonisolated(unsafe) private static var fakes: [String: any HTTPExchange] = [:]
  nonisolated(unsafe) private static var next = 0

  /// An ephemeral-configured exchange whose every request is answered by `fake`.
  public static func exchange(for fake: any HTTPExchange) -> URLSessionHTTPExchange {
    let id = registry.withLock { () -> String in
      next += 1
      let id = "fake-\(next)"
      fakes[id] = fake
      return id
    }
    let c = URLSessionConfiguration.ephemeral
    c.protocolClasses = [FakeGmailURLProtocol.self]
    c.httpAdditionalHeaders = [header: id]
    return URLSessionHTTPExchange(configuration: c)
  }

  public override class func canInit(with request: URLRequest) -> Bool { request.value(forHTTPHeaderField: header) != nil }
  public override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  public override func startLoading() {
    let req = request
    guard let id = req.value(forHTTPHeaderField: Self.header), let fake = Self.registry.withLock({ Self.fakes[id] }),
      let url = req.url, let method = HTTPRequest.Method(rawValue: req.httpMethod ?? "GET")
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
      return
    }
    var body = req.httpBody
    if body == nil, let stream = req.httpBodyStream {
      stream.open()
      var data = Data()
      var buf = [UInt8](repeating: 0, count: 4096)
      while stream.hasBytesAvailable {
        let n = stream.read(&buf, maxLength: buf.count)
        if n <= 0 { break }
        data.append(buf, count: n)
      }
      stream.close()
      body = data
    }
    let headers = (req.allHTTPHeaderFields ?? [:]).filter { $0.key != Self.header }.map { ($0.key, $0.value) }
    let client = self.client
    let protocolSelf = UnsafeSendable(self)
    Task {
      do {
        let res = try await fake.send(HTTPRequest(method: method, url: url, headers: headers, body: body))
        var fields = ["Content-Type": "application/json"]
        for (k, v) in res.headers { fields[k] = v }
        let http = HTTPURLResponse(url: url, statusCode: res.status, httpVersion: "HTTP/1.1", headerFields: fields)!
        client?.urlProtocol(protocolSelf.value, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(protocolSelf.value, didLoad: res.body)
        client?.urlProtocolDidFinishLoading(protocolSelf.value)
      } catch {
        client?.urlProtocol(protocolSelf.value, didFailWithError: URLError(.notConnectedToInternet))
      }
    }
  }

  public override func stopLoading() {}
}

struct UnsafeSendable<T>: @unchecked Sendable {
  let value: T
  init(_ v: T) { value = v }
}
