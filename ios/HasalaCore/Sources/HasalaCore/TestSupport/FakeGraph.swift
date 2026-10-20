// FakeGraph: an in-process fake of Microsoft's consumers token endpoint and the Graph mail
// surface the Outlook lane uses (docs/decisions/outlook-mailbox.md), answering `HTTPExchange`
// so the request building and response parsing under test are the production
// `MicrosoftOAuthClient` / `GraphClient` code. `FakeGmailURLProtocol.exchange(for:)` serves it
// through a real URLSession too.
//
//   - the token endpoint issues a refresh token on the code grant and a NEW one on every refresh
//     (Microsoft rotates them); an id_token that is a real three-part JWT (alg "none") with
//     `email`, `tid` (consumers) and the nonce of the last authorize URL;
//   - `/me/messages` evaluates the lane's `$filter` shape (`receivedDateTime ge` and `endswith`
//     clauses on the From address); a listing without it is answered 400, so a test fails loudly
//     if the client ever sends one. `ignoreFilter` plays Graph silently ignoring a filter;
//   - `$value` serves the MIME bytes; subscriptions are kept, with Graph's 409 on a second
//     `created` subscription to `me/messages`;
//   - `noMailbox` answers every `/me/` request with `MailboxNotEnabledForRESTAPI`;
//   - every request is recorded, with its `Prefer` header.
//
// SYNTHETIC mail only (`SyntheticOutlookMail`). Real mail is never in this repository.
import CoreJSON
import CoreMailbox
import CorePrimitives
import CoreTime
import Foundation

public final class FakeGraph: HTTPExchange, @unchecked Sendable {
  public struct Message: Sendable {
    public var id: String
    public var raw: [UInt8]
    public var receivedMs: Int64
    /// The From address Graph reports (`from.emailAddress.address`).
    public var fromAddress: String

    public init(id: String, raw: [UInt8], receivedMs: Int64, fromAddress: String) {
      self.id = id
      self.raw = raw
      self.receivedMs = receivedMs
      self.fromAddress = fromAddress
    }
  }

  public struct Subscription: Sendable, Equatable {
    public var id: String
    public var resource: String
    public var changeType: String
    public var notificationURL: String
    public var lifecycleURL: String
    public var clientState: String
    public var expiresAtMs: Int64

    public init(
      id: String, resource: String, changeType: String, notificationURL: String, lifecycleURL: String,
      clientState: String, expiresAtMs: Int64
    ) {
      self.id = id
      self.resource = resource
      self.changeType = changeType
      self.notificationURL = notificationURL
      self.lifecycleURL = lifecycleURL
      self.clientState = clientState
      self.expiresAtMs = expiresAtMs
    }
  }

  public struct Recorded: Sendable {
    public let method: String
    public let path: String
    public let query: [(String, String)]
    public let form: [(String, String)]
    public let body: JSONObject?
    public let authorization: String?
    public let prefer: String?
  }

  private let lock = NSLock()
  private var messages: [String: Message] = [:]
  private var order: [String] = []
  private var _subscriptions: [Subscription] = []
  private var _requests: [Recorded] = []
  private var failures: [String: [(status: Int, retryAfter: Int?, code: String?)]] = [:]
  private var lastNonce = ""
  private var nextSubscription = 0
  private var inFlight = 0
  private var _maxInFlight = 0

  public var email: String? = "synthetic.user@outlook.example"
  public var tid = MicrosoftOAuthConfig.consumersTenantID
  public var accessToken = "fake-ms-access-token"
  /// The refresh token now valid; every refresh replaces it.
  public private(set) var refreshToken = "fake-ms-refresh-0"
  public var expiresIn: Int64 = 3600
  public var invalidGrant = false
  public var omitMailScope = false
  public var omitRefreshToken = false
  /// The account has no Outlook mailbox (a Microsoft account on another provider's address).
  public var noMailbox = false
  /// Graph ignores the `$filter` and lists every message.
  public var ignoreFilter = false
  public var pageSize = 100
  /// When true every transport call fails (`HTTPExchangeError.offline`).
  public var offline = false
  /// Each `$value` answer waits this long (ms of real time), so concurrent downloads overlap.
  public var rawDelayMs: UInt64 = 0
  /// The fake's "now", for the subscription lifetime cap; no cap check when nil.
  public var nowMs: (@Sendable () -> Int64)?

  public static let tokenURL = "https://login.microsoftonline.com/consumers/oauth2/v2.0/token"
  static let graphPrefix = "/v1.0"

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

  /// The next answers for any request whose path contains `pathContains`: each status is used
  /// once, then the request is served normally. `retryAfter` adds a `Retry-After` header and
  /// `code` Graph's `error.code`.
  public func fail(_ pathContains: String, with statuses: [Int], retryAfter: Int? = nil, code: String? = nil) {
    lock.withLock {
      failures[pathContains, default: []].append(contentsOf: statuses.map { ($0, retryAfter, code) })
    }
  }

  /// A subscription another iPhone of the app left on this mailbox.
  public func addSubscription(_ s: Subscription) { lock.withLock { _subscriptions.append(s) } }

  public var subscriptions: [Subscription] { lock.withLock { _subscriptions } }
  public var requests: [Recorded] { lock.withLock { _requests } }
  public var graphRequests: [Recorded] { requests.filter { $0.path.hasPrefix(Self.graphPrefix) } }
  public func clearRequests() { lock.withLock { _requests = [] } }
  public var nonce: String { lock.withLock { lastNonce } }
  /// The most `$value` downloads that were ever in flight at once.
  public var maxInFlight: Int { lock.withLock { _maxInFlight } }

  /// The fake consent page: records the nonce and answers the redirect with a code.
  public func consent(authorizeURL: URL) -> URL {
    let c = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)
    func q(_ n: String) -> String { c?.queryItems?.first { $0.name == n }?.value ?? "" }
    lock.withLock { lastNonce = q("nonce") }
    var back = URLComponents(string: q("redirect_uri"))!
    back.queryItems = [URLQueryItem(name: "code", value: "fake-ms-code"), URLQueryItem(name: "state", value: q("state"))]
    return back.url!
  }

  // MARK: HTTPExchange

  public func send(_ request: HTTPRequest) async throws(HTTPExchangeError) -> HTTPResponse {
    if lock.withLock({ offline }) { throw .offline }
    let comps = URLComponents(url: request.url, resolvingAgainstBaseURL: false)!
    let query = FormEncoding.decode(comps.percentEncodedQuery ?? "")
    let bodyText = String(decoding: request.body ?? Data(), as: UTF8.self)
    let form = request.header("Content-Type")?.hasPrefix("application/x-www-form-urlencoded") == true
      ? FormEncoding.decode(bodyText) : []
    let body = request.body.flatMap { (try? JSONParser.parse([UInt8]($0)))?.objectValue }
    let path = comps.path
    lock.withLock {
      _requests.append(
        Recorded(
          method: request.method.rawValue, path: path, query: query, form: form, body: body,
          authorization: request.header("Authorization"), prefer: request.header("Prefer")))
    }
    if let f = lock.withLock({ () -> (status: Int, retryAfter: Int?, code: String?)? in
      for (k, v) in failures where !v.isEmpty && path.contains(k) {
        failures[k] = Array(v.dropFirst())
        return v[0]
      }
      return nil
    }) {
      var r = error(f.status, f.code ?? "SyntheticFailure")
      if let ra = f.retryAfter { r.headers.append(("Retry-After", String(ra))) }
      return r
    }
    if request.url.absoluteString.hasPrefix(Self.tokenURL) { return token(form) }
    guard path.hasPrefix(Self.graphPrefix) else { return error(404, "NotFound") }
    let sub = String(path.dropFirst(Self.graphPrefix.count))
    func q(_ n: String) -> String? { query.first { $0.0 == n }?.1 }
    if sub.hasPrefix("/me/"), lock.withLock({ noMailbox }) {
      return error(404, GraphClient.noMailboxCode)
    }
    switch (request.method, sub) {
    case (.get, "/me/mailFolders/inbox"):
      return json(200, [("id", .string("inbox-synthetic"))])
    case (.get, "/me/messages"):
      return list(query: query, rawQuery: comps.percentEncodedQuery ?? "")
    case (.post, "/subscriptions"):
      return createSubscription(body)
    case (.get, "/subscriptions"):
      let subs = lock.withLock { _subscriptions }
      return json(200, [("value", .array(subs.map { Self.json($0) }))])
    default: break
    }
    if sub.hasPrefix("/subscriptions/") {
      let id = String(sub.dropFirst("/subscriptions/".count))
      return lock.withLock {
        guard let i = _subscriptions.firstIndex(where: { $0.id == id }) else { return error(404, "ResourceNotFound") }
        switch request.method {
        case .delete:
          _subscriptions.remove(at: i)
          return HTTPResponse(status: 204)
        case .patch:
          if let e = body?["expirationDateTime"]?.stringValue, let ms = try? parseInstantMs(e) {
            _subscriptions[i].expiresAtMs = ms
          }
          if let n = body?["notificationUrl"]?.stringValue { _subscriptions[i].notificationURL = n }
          return json(200, Self.fields(_subscriptions[i]))
        default:
          return error(405, "MethodNotAllowed")
        }
      }
    }
    guard request.method == .get, sub.hasPrefix("/me/messages/") else { return error(404, "NotFound") }
    var rest = String(sub.dropFirst("/me/messages/".count))
    let wantsValue = rest.hasSuffix("/$value")
    if wantsValue { rest = String(rest.dropLast("/$value".count)) }
    guard let m = lock.withLock({ messages[rest] }) else { return error(404, "ErrorItemNotFound") }
    if wantsValue {
      lock.withLock {
        inFlight += 1
        _maxInFlight = max(_maxInFlight, inFlight)
      }
      let delay = lock.withLock { rawDelayMs }
      if delay > 0 { try? await Task.sleep(nanoseconds: delay * 1_000_000) }
      lock.withLock { inFlight -= 1 }
      return HTTPResponse(status: 200, body: Data(m.raw), headers: [("Content-Type", "message/rfc822")])
    }
    _ = q("$select")
    return json(200, Self.listed(m))
  }

  // MARK: Internals

  func token(_ form: [(String, String)]) -> HTTPResponse {
    func f(_ n: String) -> String { form.first { $0.0 == n }?.1 ?? "" }
    return lock.withLock {
      if invalidGrant {
        return json(400, [("error", .string("invalid_grant")), ("error_description", .string("AADSTS70000: synthetic"))])
      }
      let scope = omitMailScope ? "openid email" : "https://graph.microsoft.com/Mail.Read openid email"
      var body: [(String, JSONValue)] = [
        ("token_type", .string("Bearer")), ("scope", .string(scope)), ("expires_in", .number(JSONNumber(expiresIn))),
        ("access_token", .string(accessToken)),
      ]
      switch f("grant_type") {
      case "authorization_code":
        guard !f("code_verifier").isEmpty, !f("code").isEmpty, !f("client_id").isEmpty, !f("redirect_uri").isEmpty
        else { return json(400, [("error", .string("invalid_request"))]) }
        if !omitRefreshToken { body.append(("refresh_token", .string(refreshToken))) }
        body.append(("id_token", .string(Self.idToken(email: email, tid: tid, nonce: lastNonce))))
      case "refresh_token":
        guard f("refresh_token") == refreshToken else { return json(400, [("error", .string("invalid_grant"))]) }
        let n = (Int(refreshToken.split(separator: "-").last ?? "0") ?? 0) + 1
        refreshToken = "fake-ms-refresh-\(n)"
        body.append(("refresh_token", .string(refreshToken)))
      default:
        return json(400, [("error", .string("unsupported_grant_type"))])
      }
      return json(200, body)
    }
  }

  public static func idToken(email: String?, tid: String, nonce: String) -> String {
    func b64(_ o: JSONObject) -> String { Base64.encodeURL(JSONWriter().bytes(.object(o))) }
    let header = b64(JSONObject([("alg", .string("none")), ("typ", .string("JWT"))]))
    var claims: [(String, JSONValue)] = [
      ("iss", .string("https://login.microsoftonline.com/\(tid)/v2.0")), ("aud", .string("fake-ms-client")),
      ("tid", .string(tid)), ("sub", .string("fake-ms-subject-000")), ("nonce", .string(nonce)),
    ]
    if let email { claims.append(("email", .string(email))) }
    return "\(header).\(b64(JSONObject(claims)))."
  }

  /// `receivedDateTime ge <iso> and (endswith(from/emailAddress/address,'<s>') or …)`: the
  /// lower time bound and the suffixes; nil for anything else.
  static func parseFilter(_ f: String) -> (sinceMs: Int64, suffixes: [String])? {
    let head = "receivedDateTime ge "
    guard f.hasPrefix(head), let and = f.range(of: " and (") , f.hasSuffix(")") else { return nil }
    guard let since = try? parseInstantMs(String(f[f.index(f.startIndex, offsetBy: head.count)..<and.lowerBound]))
    else { return nil }
    let inner = f[and.upperBound..<f.index(before: f.endIndex)]
    var suffixes: [String] = []
    for clause in inner.components(separatedBy: " or ") {
      let open = "endswith(from/emailAddress/address,'"
      guard clause.hasPrefix(open), clause.hasSuffix("')") else { return nil }
      suffixes.append(String(clause.dropFirst(open.count).dropLast(2)))
    }
    return suffixes.isEmpty ? nil : (since, suffixes)
  }

  func list(query: [(String, String)], rawQuery: String) -> HTTPResponse {
    func q(_ n: String) -> String? { query.first { $0.0 == n }?.1 }
    guard let parsed = q("$filter").flatMap(Self.parseFilter) else {
      return error(400, "BadRequest")
    }
    return lock.withLock {
      let all = order.compactMap { messages[$0] }
      let matching =
        ignoreFilter
        ? all
        : all.filter { m in
          let a = m.fromAddress.lowercased()
          return m.receivedMs >= parsed.sinceMs && parsed.suffixes.contains { a.hasSuffix($0.lowercased()) }
        }
      let sorted = matching.sorted { $0.receivedMs > $1.receivedMs }
      let start = Int(q("$skiptoken") ?? "0") ?? 0
      let size = Swift.min(Int(q("$top") ?? "") ?? 100, pageSize)
      let page = Array(sorted.dropFirst(start).prefix(size))
      var body: [(String, JSONValue)] = [("value", .array(page.map { .object(JSONObject(Self.listed($0))) }))]
      if start + size < sorted.count {
        let base = rawQuery.components(separatedBy: "&").filter { !$0.hasPrefix("$skiptoken=") }.joined(separator: "&")
        body.append(("@odata.nextLink", .string("https://graph.microsoft.com/v1.0/me/messages?\(base)&$skiptoken=\(start + size)")))
      }
      return json(200, body)
    }
  }

  static func listed(_ m: Message) -> [(String, JSONValue)] {
    [
      ("id", .string(m.id)), ("receivedDateTime", .string(Instant.iso(m.receivedMs) ?? "")),
      (
        "from",
        .object(JSONObject([("emailAddress", .object(JSONObject([("name", .string("Synthetic")), ("address", .string(m.fromAddress))])))]))
      ),
    ]
  }

  func createSubscription(_ body: JSONObject?) -> HTTPResponse {
    guard let b = body, let resource = b["resource"]?.stringValue, let change = b["changeType"]?.stringValue,
      let n = b["notificationUrl"]?.stringValue, let l = b["lifecycleNotificationUrl"]?.stringValue,
      let cs = b["clientState"]?.stringValue, !cs.isEmpty, cs.utf8.count <= 128,
      let e = b["expirationDateTime"]?.stringValue, let exp = try? parseInstantMs(e)
    else { return error(400, "InvalidRequest") }
    return lock.withLock {
      if let now = nowMs?(), exp > now + 10_080 * 60_000 { return error(400, "InvalidRequest") }
      if _subscriptions.contains(where: { $0.resource == resource && $0.changeType == change }) {
        return error(409, "Conflict")
      }
      nextSubscription += 1
      let s = Subscription(
        id: "sub-synthetic-\(nextSubscription)", resource: resource, changeType: change, notificationURL: n,
        lifecycleURL: l, clientState: cs, expiresAtMs: exp)
      _subscriptions.append(s)
      return json(201, Self.fields(s))
    }
  }

  static func fields(_ s: Subscription) -> [(String, JSONValue)] {
    [
      ("id", .string(s.id)), ("resource", .string(s.resource)), ("changeType", .string(s.changeType)),
      ("notificationUrl", .string(s.notificationURL)), ("lifecycleNotificationUrl", .string(s.lifecycleURL)),
      // Graph does not echo clientState.
      ("clientState", .null),
      // Graph's own format: seven fractional digits.
      ("expirationDateTime", .string((Instant.iso(s.expiresAtMs) ?? "").replacingOccurrences(of: "Z", with: "0000Z"))),
    ]
  }

  static func json(_ s: Subscription) -> JSONValue { .object(JSONObject(fields(s))) }

  func error(_ status: Int, _ code: String) -> HTTPResponse {
    json(status, [("error", .object(JSONObject([("code", .string(code)), ("message", .string("synthetic"))])))])
  }

  func json(_ status: Int, _ o: [(String, JSONValue)]) -> HTTPResponse {
    HTTPResponse(status: status, body: Data(JSONWriter().bytes(.object(JSONObject(o)))))
  }
}

/// Hand-written alerts as Outlook.com delivers them: EOP's Microsoft-form Authentication-Results
/// on top and the EOP-only `X-MS-Exchange-Organization-*` fields (docs/decisions/
/// outlook-mailbox.md §3). Every value is fictional; message ids are short immutable-id-shaped
/// strings.
public enum SyntheticOutlookMail {
  public static let defaultTo = "synthetic.user@outlook.example"

  /// A text/plain message. `authDomain` nil omits the A-R; `eop` false omits the EOP fields
  /// (verdict `no_eop`); `spoofedAbove` adds a sender-written A-R above EOP's (`multiple_ar`).
  public static func rfc822(
    from: String, subject: String, body: String, dateMs: Int64, authDomain: String?, eop: Bool = true,
    spoofedAbove: Bool = false
  ) -> [UInt8] {
    var h = ["Received: from mail.synthetic.example (192.0.2.1) by AM0PR01MB0001.eurprd01.prod.outlook.com"]
    if spoofedAbove, let d = authDomain {
      h.append("Authentication-Results: spf=pass smtp.mailfrom=\(d); dkim=pass header.d=\(d);dmarc=pass action=none header.from=\(d);compauth=pass reason=100")
    }
    if let d = authDomain {
      h.append("Authentication-Results: spf=pass (sender IP is 192.0.2.1)")
      h.append(" smtp.mailfrom=\(d); dkim=pass (signature was verified)")
      h.append(" header.d=\(d);dmarc=pass action=none")
      h.append(" header.from=\(d);compauth=pass reason=100")
    }
    if eop {
      h.append("X-MS-Exchange-Organization-AuthAs: Anonymous")
      h.append("X-MS-Exchange-Organization-AuthSource: AM0PR01MB0001.eurprd01.prod.outlook.com")
    }
    if let d = authDomain {
      h.append("DKIM-Signature: v=1; a=rsa-sha256; d=\(d); s=synthetic; h=From:To:Subject; bh=c3ludGhldGlj; b=c3ludGhldGljc2lnbmF0dXJl")
    }
    h += [
      "From: \(from)", "To: \(defaultTo)", "Subject: \(subject)", "Message-ID: <\(dateMs).synthetic@example.invalid>",
      "MIME-Version: 1.0", "Content-Type: text/plain; charset=\"utf-8\"", "Content-Transfer-Encoding: 8bit",
    ]
    return Array((h.joined(separator: "\r\n") + "\r\n\r\n" + body.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n").utf8)
  }

  /// A DIB card purchase alert (dib.card.v1's shape), from `alerts@dib.ae`.
  public static func dibCard(
    id: String, amount: String = "250.00", day: String = "05-06-2026", merchant: String = "SYNTHETIC GROCER DUBAI",
    last4: String = "1234", dateMs: Int64, fromDomain: String = "dib.ae", eop: Bool = true, spoofedAbove: Bool = false
  ) -> FakeGraph.Message {
    let body = "إشعار مشتريات\nالمبلغ\nAED \(amount)\nبتاريخ \(day)\nالدفع الى\n\(merchant)\nرقم البطاقة\nXXXX\(last4)"
    let address = "alerts@\(fromDomain)"
    return FakeGraph.Message(
      id: id,
      raw: rfc822(
        from: "DIB Alerts <\(address)>", subject: "Card transaction", body: body, dateMs: dateMs, authDomain: fromDomain,
        eop: eop, spoofedAbove: spoofedAbove),
      receivedMs: dateMs, fromAddress: address)
  }

  /// An ENBD account debit alert (enbd.alert.v1's shape; dated from the email).
  public static func enbdAlert(id: String, amount: String = "12.34", last4: String = "8642", dateMs: Int64)
    -> FakeGraph.Message
  {
    let address = "alerts@emiratesnbd.com"
    return FakeGraph.Message(
      id: id,
      raw: rfc822(
        from: "Emirates NBD <\(address)>", subject: "Transaction advice for your account ending with \(last4)",
        body: "AED \(amount) has been debited from your account 012XXX34XXX56.", dateMs: dateMs,
        authDomain: "emiratesnbd.com"),
      receivedMs: dateMs, fromAddress: address)
  }

  /// A bank-domain message no template reads (the empty review shape).
  public static func bankNotice(id: String, dateMs: Int64) -> FakeGraph.Message {
    let address = "news@emiratesnbd.com"
    return FakeGraph.Message(
      id: id,
      raw: rfc822(
        from: "Emirates NBD <\(address)>", subject: "Your statement is ready",
        body: "Your monthly statement is ready to view.", dateMs: dateMs, authDomain: "emiratesnbd.com"),
      receivedMs: dateMs, fromAddress: address)
  }

  /// Mail from a look-alike domain (`notdib.ae`, `dib.ae.evil.example`): never a bank sender.
  public static func lookAlike(id: String, dateMs: Int64, address: String) -> FakeGraph.Message {
    let d = BankDomains.domainOf(address)
    return FakeGraph.Message(
      id: id,
      raw: rfc822(from: "Offers <\(address)>", subject: "Win big", body: "Not a bank.", dateMs: dateMs, authDomain: d),
      receivedMs: dateMs, fromAddress: address)
  }
}
