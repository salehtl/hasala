// The Gmail REST surface the lane uses (spec 04 §7.1, port of the PWA's gmail.ts, narrowed by
// PO G):
//
//   users.getProfile   fields=historyId only: the cheap "did anything change?" test
//   messages.list      ALWAYS with a sender query (`{from:a from:b} after:N -in:trash`), ids only
//   messages.get       format=metadata (From and Authentication-Results only, no snippet, no
//                      Subject; R-07) and format=raw, for listed ids only
//   users.watch / users.stop
//
// There is deliberately no `history.list` (it lists every new message id in the mailbox, PO G)
// and no unfiltered `messages.list`: the rest of the inbox, its ids and its headers included,
// never reaches the phone. `messagesList` refuses an empty query rather than send one.
//
// This client never retries and never interprets: a non-2xx answer is a typed `MailAPIError`
// carrying the status, and the engine decides what it means (`gone`, `retry`, `fatal`). It is the
// Gmail provider's `MailSource` (the extension at the end).
import CoreJSON
import Foundation

public typealias GmailAPIError = MailAPIError
public typealias GmailMessagesPage = MailListPage
/// `messages.get?format=metadata` with `From` and `Authentication-Results` only.
public typealias GmailMessageMetadata = MailMessageMetadata
public typealias GmailRawMessage = MailRawMessage

public struct GmailWatchResponse: Sendable, Equatable {
  public let historyID: String
  /// Epoch ms.
  public let expirationMs: Int64
}

public struct GmailClient: Sendable {
  public static let defaultBase = "https://gmail.googleapis.com/gmail/v1/users/me"
  let http: any HTTPExchange
  let accessToken: String
  let base: String

  public init(http: any HTTPExchange, accessToken: String, base: String = GmailClient.defaultBase) {
    self.http = http
    self.accessToken = accessToken
    self.base = base
  }

  func get(_ path: String, _ query: [(String, String)], op: String) async throws(GmailAPIError) -> JSONObject {
    try await call(.get, path, query, body: nil, op: op)
  }

  func call(
    _ method: HTTPRequest.Method, _ path: String, _ query: [(String, String)], body: JSONValue?, op: String
  ) async throws(GmailAPIError) -> JSONObject {
    var headers = [("Authorization", "Bearer \(accessToken)"), ("Accept", "application/json")]
    if body != nil { headers.append(("Content-Type", "application/json")) }
    let req = HTTPRequest(
      method: method, url: URL.build(base, path, query), headers: headers,
      body: body.map { Data(JSONWriter().bytes($0)) })
    let res: HTTPResponse
    do { res = try await http.send(req) } catch { throw .offline }
    guard res.ok else {
      // Gmail answers per-user and per-project quota with 403 as well as 429. Those are a
      // back-off, not a lost grant: report them as 429 so the engine retries and narrows instead
      // of asking the user to reconnect. Every other 403 (insufficientPermissions, forbidden)
      // stays 403.
      if res.status == 403, Self.isRateLimit(errorBody: res.body) { throw .status(429, op: op) }
      if res.status == 400, Self.isMailServiceNotEnabled(errorBody: res.body) { throw .noMailbox }
      throw .status(res.status, op: op)
    }
    if res.body.isEmpty { return JSONObject() }
    guard let o = (try? JSONParser.parse([UInt8](res.body)))?.objectValue else {
      throw .status(res.status, op: op)
    }
    return o
  }

  /// The mailbox's current historyId (a change detector only, spec 04 §7.5 step 6).
  public func profileHistoryID() async throws(GmailAPIError) -> String {
    let o = try await get("/profile", [("fields", "historyId")], op: "profile")
    if let s = o["historyId"]?.stringValue, !s.isEmpty { return s }
    if let n = o["historyId"]?.numberValue { return n.literal }
    throw .status(200, op: "profile")
  }

  /// One page of ids matching a sender query. `includeSpamTrash=true` (bank mail forwarded or
  /// mis-filed lands in Spam); Trash is excluded by `-in:trash` in the query itself.
  public func messagesList(query: String, pageToken: String?, maxResults: Int = 100)
    async throws(GmailAPIError) -> GmailMessagesPage
  {
    guard query.contains("from:") else { throw .unfilteredListing }
    var q: [(String, String)] = [
      ("q", query), ("includeSpamTrash", "true"), ("maxResults", String(maxResults)),
      ("fields", "messages(id),nextPageToken"),
    ]
    if let pageToken { q.append(("pageToken", pageToken)) }
    let o = try await get("/messages", q, op: "list")
    var ids: [String] = []
    for m in o["messages"]?.arrayValue ?? [] {
      if let id = m["id"]?.stringValue, !id.isEmpty { ids.append(id) }
    }
    let next = o["nextPageToken"]?.stringValue
    return GmailMessagesPage(ids: ids, nextPageToken: (next?.isEmpty ?? true) ? nil : next)
  }

  /// From, Authentication-Results, internalDate and sizeEstimate; nothing else of the message.
  public func messageMetadata(id: String) async throws(GmailAPIError) -> GmailMessageMetadata {
    let o = try await get(
      "/messages/\(FormEncoding.escape(id))",
      [
        ("format", "metadata"), ("metadataHeaders", "From"), ("metadataHeaders", "Authentication-Results"),
        ("fields", "id,internalDate,sizeEstimate,payload/headers"),
      ], op: "metadata")
    var headers: [(name: String, value: String)] = []
    for h in o["payload"]?["headers"]?.arrayValue ?? [] {
      if let n = h["name"]?.stringValue, let v = h["value"]?.stringValue { headers.append((n, v)) }
    }
    return GmailMessageMetadata(
      id: id, internalDate: Self.decimal(o["internalDate"]),
      sizeEstimate: o["sizeEstimate"]?.numberValue?.int64Value, headers: headers)
  }

  /// The RFC 822 message. A 2xx without `raw` is reported as that status (the engine treats it
  /// as `gone`).
  public func messageRaw(id: String) async throws(GmailAPIError) -> GmailRawMessage {
    let o = try await get("/messages/\(FormEncoding.escape(id))", [("format", "raw")], op: "raw")
    guard let raw = o["raw"]?.stringValue, !raw.isEmpty else { throw .status(200, op: "raw") }
    return GmailRawMessage(id: id, rawBase64URL: raw, internalDate: Self.decimal(o["internalDate"]))
  }

  /// `users.watch` on INBOX only (spec 04 §7.5 step 5).
  public func watch(topicName: String) async throws(GmailAPIError) -> GmailWatchResponse {
    let body = JSONValue.object(
      JSONObject([
        ("topicName", .string(topicName)), ("labelIds", .array([.string("INBOX")])),
        ("labelFilterBehavior", .string("include")),
      ]))
    let o = try await call(.post, "/watch", [], body: body, op: "watch")
    let exp = Self.decimal(o["expiration"])
    guard let ms = Int64(exp) else { throw .status(200, op: "watch") }
    return GmailWatchResponse(historyID: Self.decimal(o["historyId"]), expirationMs: ms)
  }

  public func stop() async throws(GmailAPIError) {
    _ = try await call(.post, "/stop", [], body: nil, op: "stop")
  }

  /// `{from:a from:b} after:<sinceSec> -in:trash` (spec 04 §7.5). The domains are query-safe
  /// (`BankDomains.isQuerySafe`, enforced by `BankDomains.effectiveTrusted`).
  public static func senderQuery(_ group: [String], sinceSec: Int64) -> String {
    "{" + group.map { "from:" + $0 }.joined(separator: " ") + "} after:\(sinceSec) -in:trash"
  }

  /// The Google API error reasons that mean "slow down" (`error.errors[].reason`, the legacy
  /// shape Gmail still sends, or `error.details[].reason` / `error.status` in the AIP-193 shape).
  static let rateLimitReasons: Set<String> = [
    "ratelimitexceeded", "userratelimitexceeded", "dailylimitexceeded", "quotaexceeded",
    "rate_limit_exceeded", "resource_exhausted",
  ]

  /// Whether a non-2xx body names a rate or quota limit. Reads only the error's reason codes.
  public static func isRateLimit(errorBody: Data) -> Bool {
    guard !errorBody.isEmpty, let e = (try? JSONParser.parse([UInt8](errorBody)))?["error"] else { return false }
    var reasons: [String] = []
    for x in e["errors"]?.arrayValue ?? [] { if let r = x["reason"]?.stringValue { reasons.append(r) } }
    for x in e["details"]?.arrayValue ?? [] { if let r = x["reason"]?.stringValue { reasons.append(r) } }
    if let st = e["status"]?.stringValue { reasons.append(st) }
    return reasons.contains { rateLimitReasons.contains($0.lowercased()) }
  }

  static let mailServiceNotEnabled = "Mail service not enabled"

  public static func isMailServiceNotEnabled(errorBody: Data) -> Bool {
    guard !errorBody.isEmpty, let e = (try? JSONParser.parse([UInt8](errorBody)))?["error"] else { return false }
    var messages: [String] = []
    var precondition = e["status"]?.stringValue == "FAILED_PRECONDITION"
    if let m = e["message"]?.stringValue { messages.append(m) }
    for x in e["errors"]?.arrayValue ?? [] {
      if x["reason"]?.stringValue == "failedPrecondition" { precondition = true }
      if let m = x["message"]?.stringValue { messages.append(m) }
    }
    return precondition && messages.contains(mailServiceNotEnabled)
  }

  /// Gmail sends int64s as decimal strings; accept a JSON number too.
  static func decimal(_ v: JSONValue?) -> String {
    if let s = v?.stringValue { return s }
    if let n = v?.numberValue, n.isIntegerLiteral { return n.literal }
    return ""
  }
}

// MARK: - MailSource

extension GmailClient: MailSource {
  /// At most this many `from:` terms per query (spec 04 §7.5).
  public var maxSendersPerList: Int { BankDomains.maxTermsPerQuery }

  public func changeToken() async throws(MailAPIError) -> String? { try await profileHistoryID() }

  /// `messages.list` with the sender query; no senders is refused (`unfilteredListing`).
  public func list(senders: [String], since: Int64, pageToken: String?) async throws(MailAPIError) -> MailListPage {
    guard !senders.isEmpty else { throw .unfilteredListing }
    return try await messagesList(query: Self.senderQuery(senders, sinceSec: since), pageToken: pageToken)
  }

  public func metadata(id: String) async throws(MailAPIError) -> MailMessageMetadata { try await messageMetadata(id: id) }

  public func raw(id: String) async throws(MailAPIError) -> MailRawMessage { try await messageRaw(id: id) }

  public func checkMailbox() async throws(MailAPIError) {
    _ = try await get("/profile", [("fields", "historyId")], op: "mailbox")
  }

  /// `users.watch` on the server's Pub/Sub topic; nil without one.
  public func subscribe(_ push: MailboxPushConfig) async throws(MailAPIError) -> MailSubscription? {
    guard case .gmail(let topic) = push else { return nil }
    return MailSubscription(expiresAtMs: try await watch(topicName: topic).expirationMs)
  }

  /// A Gmail watch is renewed by watching again.
  public func renew(_ push: MailboxPushConfig) async throws(MailAPIError) -> MailSubscription? {
    try await subscribe(push)
  }
}
