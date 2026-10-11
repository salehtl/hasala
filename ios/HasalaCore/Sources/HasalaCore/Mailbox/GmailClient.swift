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
// This client never retries and never interprets: a non-2xx answer is a typed `GmailAPIError`
// carrying the status, and the engine decides what it means (`gone`, `retry`, `fatal`).
import CoreJSON
import Foundation

public enum GmailAPIError: Error, Sendable, Equatable {
  /// A non-2xx answer, or a 2xx without the field the call needs (status kept).
  case status(Int, op: String)
  case offline
  /// The caller asked for an unfiltered listing (a programming error, refused locally).
  case unfilteredListing

  public var status: Int? {
    if case .status(let s, _) = self { return s }
    return nil
  }
}

public struct GmailMessagesPage: Sendable, Equatable {
  public let ids: [String]
  public let nextPageToken: String?
}

/// `messages.get?format=metadata` with `From` and `Authentication-Results` only.
public struct GmailMessageMetadata: Sendable, Equatable {
  public let id: String
  /// ms since the epoch as Gmail's decimal string, or "" when absent.
  public let internalDate: String
  public let sizeEstimate: Int64?
  /// The returned headers, in Gmail's order (which preserves the message's order).
  public let headers: [(name: String, value: String)]

  public static func == (a: Self, b: Self) -> Bool {
    a.id == b.id && a.internalDate == b.internalDate && a.sizeEstimate == b.sizeEstimate
      && a.headers.elementsEqual(b.headers) { $0.name == $1.name && $0.value == $1.value }
  }

  /// The headers re-serialized as a header block (`Name: value\r\n`...), for CoreMail's
  /// Authentication-Results analysis. Only the two requested headers are present.
  public var headerBlock: String {
    headers.map { "\($0.name): \($0.value)" }.joined(separator: "\r\n")
  }

  public var from: String { headers.first { $0.name.caseInsensitiveCompare("From") == .orderedSame }?.value ?? "" }
}

public struct GmailRawMessage: Sendable, Equatable {
  public let id: String
  /// base64url (unpadded), undecoded: the engine decodes strictly and hashes the bytes.
  public let rawBase64URL: String
  public let internalDate: String
}

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
    guard res.ok else { throw .status(res.status, op: op) }
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

  /// Gmail sends int64s as decimal strings; accept a JSON number too.
  static func decimal(_ v: JSONValue?) -> String {
    if let s = v?.stringValue { return s }
    if let n = v?.numberValue, n.isIntegerLiteral { return n.literal }
    return ""
  }
}
