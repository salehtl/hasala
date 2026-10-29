// The Microsoft Graph mail surface the Outlook lane uses (docs/decisions/outlook-mailbox.md;
// the Outlook plan's shared contract), narrowed by PO G like the Gmail client:
//
//   GET    /me/messages              ALWAYS with a sender `$filter` (`eq` on the From address,
//                                    one clause per known bank address) and a received-time
//                                    bound; ids, received time, From and folder only (§1)
//   GET    /me/messages/{id}         id, received time, From and folder, for a listed id the run
//                                    has not seen in its listing
//   GET    /me/messages/{id}/$value  the MIME, for a listed id (§4)
//   GET    /me/mailFolders/inbox     `$select=id` only: does this account have a mailbox, and
//                                    which folder id is the Inbox (§3a)
//   GET    /me/mailFolders/junkemail and /deleteditems, `$select=id` only: a message in Junk
//                                    Email is marked spam, one in Deleted Items is left out
//   POST   /subscriptions            the inbox's messages, `created`, the server's two hook URLs,
//   PATCH  /subscriptions/{id}       the link's clientState, now + 6 d 23 h (§6)
//   DELETE /subscriptions/{id}
//
// There is no delta query and no unfiltered listing: the rest of the mailbox, its ids included,
// never reaches the phone. Graph may ignore a filter silently, so every listed From address is
// checked against the requested senders and a page with a stranger is dropped unread
// (`filterNotApplied`, §1b). Every request asks for immutable ids (`Prefer: IdType=
// "ImmutableId"`, §4b), so a message moved between folders keeps the id the lane deduplicates on.
//
// Like GmailClient, this never retries and never interprets: a non-2xx answer is a typed
// `MailAPIError` and the engine decides. Graph's "slow down" (429, or 503 with `Retry-After`) is
// `throttled`, and `MailboxNotEnabledForRESTAPI` (a Microsoft account with no Outlook mailbox) is
// `noMailbox`, read from `error.code` and never from the status.
import CoreJSON
import CorePrimitives
import CoreStore
import CoreTime
import Foundation

// MARK: - What the link keeps

/// What the Outlook link keeps on this iPhone beside the refresh token: the subscription's
/// `clientState` (from `PUT /mailbox/link`) and the id of the subscription this iPhone created,
/// so renewing and stopping touch that subscription only.
public struct OutlookLinkState: Sendable, Equatable {
  public var clientState: String
  public var subscriptionID: String?
  /// The resource the subscription watches; nil for one made before it was the inbox alone.
  public var subscriptionResource: String?

  public init(clientState: String, subscriptionID: String? = nil, subscriptionResource: String? = nil) {
    self.clientState = clientState
    self.subscriptionID = subscriptionID
    self.subscriptionResource = subscriptionResource
  }

  var bytes: [UInt8] {
    var o = JSONObject([("client_state", .string(clientState))])
    if let subscriptionID { o["subscription_id"] = .string(subscriptionID) }
    if let subscriptionResource { o["subscription_resource"] = .string(subscriptionResource) }
    return JSONWriter().bytes(.object(o))
  }

  init?(bytes: [UInt8]) {
    guard let o = (try? JSONParser.parse(bytes))?.objectValue, let cs = o["client_state"]?.stringValue, !cs.isEmpty
    else { return nil }
    clientState = cs
    subscriptionID = o["subscription_id"]?.stringValue
    subscriptionResource = o["subscription_resource"]?.stringValue
  }
}

/// The Keychain item `app.hasala.outlook.clientstate`, behind a protocol so the core never imports
/// Security. Same null-vs-throw contract as `MailRefreshTokenStore`.
public protocol OutlookLinkStore: Sendable {
  /// nil = absent; throws = present but unreadable now.
  func read() throws(SecretUnavailable) -> OutlookLinkState?
  func write(_ state: OutlookLinkState) throws(SecretUnavailable)
  func delete() throws(SecretUnavailable)
}

/// `SecretItem.outlookClientState(userID:)` in the account's `Secrets`, so `Secrets.wipeAccount`
/// always takes it. An item that reads but cannot be decoded is deleted and read as absent.
public struct SecretsOutlookLinkStore: OutlookLinkStore {
  let store: any SecretStore
  let item: SecretItem

  public init(secrets: Secrets, userID: UserID) {
    store = secrets.store
    item = .outlookClientState(userID: userID)
  }

  public func read() throws(SecretUnavailable) -> OutlookLinkState? {
    let d: Data?
    do { d = try store.read(item) } catch { throw SecretUnavailable() }
    guard let d else { return nil }
    guard let s = OutlookLinkState(bytes: [UInt8](d)) else {
      do { try store.delete(item) } catch { throw SecretUnavailable() }
      return nil
    }
    return s
  }

  /// Writes, then reads back: a mismatch throws.
  public func write(_ state: OutlookLinkState) throws(SecretUnavailable) {
    let bytes = Data(state.bytes)
    do {
      try store.write(item, bytes)
      guard try store.read(item) == bytes else { throw SecretUnavailable() }
    } catch {
      throw SecretUnavailable()
    }
  }

  public func delete() throws(SecretUnavailable) {
    do { try store.delete(item) } catch { throw SecretUnavailable() }
  }
}

/// An in-memory `OutlookLinkStore` (tests, previews). `locked` simulates before-first-unlock.
public final class MemoryOutlookLinkStore: OutlookLinkStore, @unchecked Sendable {
  private let lock = NSLock()
  private var state: OutlookLinkState?
  public var locked = false

  public init(_ state: OutlookLinkState? = nil) { self.state = state }

  public func read() throws(SecretUnavailable) -> OutlookLinkState? {
    lock.lock()
    defer { lock.unlock() }
    if locked { throw SecretUnavailable() }
    return state
  }
  public func write(_ s: OutlookLinkState) throws(SecretUnavailable) {
    lock.lock()
    defer { lock.unlock() }
    if locked { throw SecretUnavailable() }
    state = s
  }
  public func delete() throws(SecretUnavailable) {
    lock.lock()
    defer { lock.unlock() }
    if locked { throw SecretUnavailable() }
    state = nil
  }
}

// MARK: - The client

/// What a listing page said about each id (its From address and received time), so the download
/// that follows needs no metadata request (§4: "Do not fetch metadata first").
final class GraphListingCache: @unchecked Sendable {
  private let lock = NSLock()
  private var entries: [String: (address: String, receivedMs: Int64, folder: String?, junk: Bool)] = [:]
  private var folders: GraphClient.SpecialFolders?
  private var inbox: String?

  func put(_ id: String, address: String, receivedMs: Int64, folder: String?, junk: Bool) {
    lock.withLock { entries[id] = (address, receivedMs, folder, junk) }
  }
  func get(_ id: String) -> (address: String, receivedMs: Int64, folder: String?, junk: Bool)? { lock.withLock { entries[id] } }
  func special() -> GraphClient.SpecialFolders? { lock.withLock { folders } }
  func setSpecial(_ f: GraphClient.SpecialFolders) { lock.withLock { folders = f } }
  var inboxID: String? {
    get { lock.withLock { inbox } }
    set { lock.withLock { inbox = newValue } }
  }
}

public struct GraphClient: Sendable {
  public static let defaultBase = "https://graph.microsoft.com/v1.0"
  /// At most this many domains per listing (§1, check L4).
  public static let maxDomainsPerList = 20
  /// now + 6 d 23 h: inside Graph's 10,080-minute cap for messages, with an hour of slack for
  /// clocks (the contract).
  public static let subscriptionLifetimeMs: Int64 = (6 * 24 + 23) * 3_600_000
  public static let pageSize = 100
  public static let immutableIDs = ("Prefer", "IdType=\"ImmutableId\"")
  /// `error.code` of a Microsoft account that has no Outlook mailbox.
  public static let noMailboxCode = "MailboxNotEnabledForRESTAPI"
  /// The subscription's resource: new mail in the inbox only, as Gmail's watch is.
  public static let subscriptionResource = "me/mailFolders('inbox')/messages"
  static let subscriptionResources: Set<String> = ["me/messages", subscriptionResource.lowercased()]
  static let messageFields = "id,receivedDateTime,from,parentFolderId"

  /// The ids of Junk Email and Deleted Items (nil when the mailbox has no such folder).
  struct SpecialFolders: Sendable, Equatable {
    var junk: String?
    var deleted: String?
  }

  let http: any HTTPExchange
  let accessToken: String
  let base: String
  let link: any OutlookLinkStore
  let nowMs: @Sendable () -> Int64
  let knownSenders: [String]
  let cache = GraphListingCache()
  static let log = CoreLog(category: "CoreMailbox")

  public init(
    http: any HTTPExchange, accessToken: String, link: any OutlookLinkStore, base: String = GraphClient.defaultBase,
    knownSenders: [String] = OutlookSenders.known, nowMs: @escaping @Sendable () -> Int64
  ) {
    self.http = http
    self.knownSenders = knownSenders
    self.accessToken = accessToken
    self.link = link
    self.base = base
    self.nowMs = nowMs
  }

  // MARK: Wire

  /// `base` + path + query. Query names (`$filter`, `$select`, `$top`) are fixed ASCII and sent
  /// as written; values are percent-encoded.
  func url(_ path: String, _ query: [(String, String)] = []) -> URL {
    let q = query.map { "\($0.0)=\(FormEncoding.escape($0.1))" }.joined(separator: "&")
    return URL(string: base + path + (q.isEmpty ? "" : "?" + q))!
  }

  /// One request. Throws `offline` for a transport failure and the mapped error for a non-2xx.
  func call(_ method: HTTPRequest.Method, _ url: URL, body: JSONValue? = nil, json: Bool = true, op: String)
    async throws(MailAPIError) -> HTTPResponse
  {
    var headers = [("Authorization", "Bearer \(accessToken)"), Self.immutableIDs]
    if json { headers.append(("Accept", "application/json")) }
    if body != nil { headers.append(("Content-Type", "application/json")) }
    let req = HTTPRequest(method: method, url: url, headers: headers, body: body.map { Data(JSONWriter().bytes($0)) })
    let res: HTTPResponse
    do { res = try await http.send(req) } catch .tooLarge { throw .tooLarge(op: op) } catch { throw .offline }
    guard res.ok else { throw Self.failure(res, op: op) }
    return res
  }

  /// A 2xx JSON object; a 2xx that is not one is reported as its status.
  func object(_ method: HTTPRequest.Method, _ url: URL, body: JSONValue? = nil, op: String)
    async throws(MailAPIError) -> JSONObject
  {
    let res = try await call(method, url, body: body, op: op)
    if res.body.isEmpty { return JSONObject() }
    guard let o = (try? JSONParser.parse([UInt8](res.body)))?.objectValue else { throw .status(res.status, op: op) }
    return o
  }

  /// A non-2xx answer as the engine's error. Reads only `error.code` and `Retry-After`.
  public static func failure(_ res: HTTPResponse, op: String) -> MailAPIError {
    let code = (try? JSONParser.parse([UInt8](res.body)))?["error"]?["code"]?.stringValue
    log.notice("graph.failure", .count("status", res.status), .redacted("code", code ?? ""))
    if code == noMailboxCode { return .noMailbox }
    if res.status == 429 || res.status == 503,
      let ra = res.header("Retry-After").flatMap({ Int64($0.trimmingCharacters(in: .whitespaces)) }), ra >= 0
    {
      return .throttled(retryAfterSec: ra, op: op)
    }
    if code == "ErrorItemNotFound" { return .status(404, op: op) }
    return .status(res.status, op: op)
  }

  // MARK: Listing (§1)

  /// `$filter`: `receivedDateTime ge <since> and (from/emailAddress/address eq '<a>' or …)`, one
  /// clause per known address (Outlook.com refuses `endswith` on messages). No `$orderby` (so no
  /// `InefficientFilter`): the engine pages to the end before its watermark moves.
  public static func listQuery(_ addresses: [String], sinceSec: Int64, top: Int = pageSize) -> [(String, String)] {
    let clauses = addresses.map { "from/emailAddress/address eq '\($0)'" }
    let filter = "receivedDateTime ge \(isoSeconds(sinceSec)) and (\(clauses.joined(separator: " or ")))"
    return [("$filter", filter), ("$select", messageFields), ("$top", String(top))]
  }

  /// `2026-10-13T00:00:00Z`.
  static func isoSeconds(_ sec: Int64) -> String {
    let s = Instant.iso(max(0, sec) * 1000) ?? "1970-01-01T00:00:00.000Z"
    return s.hasSuffix(".000Z") ? String(s.dropLast(5)) + "Z" : s
  }

  /// One page of ids from `senders` (domains). `pageToken` is Graph's `@odata.nextLink`, used as
  /// returned and sent only to this client's own API origin. A 504 on a first page is retried once
  /// with a smaller page (§5).
  public func listMessages(senders: [String], sinceSec: Int64, pageToken: String?) async throws(MailAPIError)
    -> MailListPage
  {
    guard !senders.isEmpty, senders.count <= Self.maxDomainsPerList, senders.allSatisfy(BankDomains.isQuerySafe)
    else { throw .unfilteredListing }
    let addresses = OutlookSenders.addresses(for: senders, known: knownSenders)
    guard !addresses.isEmpty else { return MailListPage(ids: [], nextPageToken: nil) }
    let wanted = Set(addresses.map { $0.lowercased() })
    let o: JSONObject
    if let pageToken {
      guard pageToken.hasPrefix(base + "/me/messages?"), let u = URL(string: pageToken) else {
        throw .status(200, op: "list")
      }
      o = try await object(.get, u, op: "list")
    } else {
      _ = try await inboxFolderID()
      do {
        o = try await object(.get, url("/me/messages", Self.listQuery(addresses, sinceSec: sinceSec)), op: "list")
      } catch .status(504, _) {
        o = try await object(.get, url("/me/messages", Self.listQuery(addresses, sinceSec: sinceSec, top: 50)), op: "list")
      }
    }
    var ids: [String] = []
    var seen: [(String, String, Int64, String?, Bool)] = []
    let values = o["value"]?.arrayValue ?? []
    let folders = values.isEmpty ? SpecialFolders() : try await specialFolders()
    for m in values {
      guard let id = m["id"]?.stringValue, !id.isEmpty else { throw .status(200, op: "list") }
      let address = m["from"]?["emailAddress"]?["address"]?.stringValue ?? ""
      let received = m["receivedDateTime"]?.stringValue.flatMap { try? parseInstantMs($0) }
      // §1b: Graph applied the filter, or the whole page is dropped unread.
      guard wanted.contains(address.lowercased()), BankDomains.isMember(BankDomains.domainOf(address), of: senders),
        let received,
        received >= sinceSec * 1000
      else { throw .filterNotApplied }
      let parent = m["parentFolderId"]?.stringValue
      if let deleted = folders.deleted, parent == deleted { continue }
      ids.append(id)
      seen.append((id, address, received, parent, folders.junk != nil && parent == folders.junk))
    }
    for (id, address, received, folder, junk) in seen {
      cache.put(id, address: address, receivedMs: received, folder: folder, junk: junk)
    }
    let next = o["@odata.nextLink"]?.stringValue
    return MailListPage(ids: ids, nextPageToken: (next?.isEmpty ?? true) ? nil : next)
  }

  // MARK: Fetching (§4)

  func path(_ id: String) -> String { "/me/messages/\(FormEncoding.escape(id))" }

  /// The ids of Junk Email and Deleted Items, read once per client.
  func specialFolders() async throws(MailAPIError) -> SpecialFolders {
    if let f = cache.special() { return f }
    let f = SpecialFolders(junk: try await folderID("junkemail"), deleted: try await folderID("deleteditems"))
    cache.setSpecial(f)
    return f
  }

  func folderID(_ wellKnownName: String) async throws(MailAPIError) -> String? {
    do {
      let o = try await object(.get, url("/me/mailFolders/\(wellKnownName)", [("$select", "id")]), op: "folder")
      return o["id"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
    } catch .status(404, _) {
      return nil
    }
  }

  /// From and received time: from this run's listing when it named the id, else one request.
  public func messageMetadata(id: String) async throws(MailAPIError) -> MailMessageMetadata {
    if let c = cache.get(id) { return Self.metadata(id, c.address, c.receivedMs) }
    let o = try await object(.get, url(path(id), [("$select", Self.messageFields)]), op: "metadata")
    let address = o["from"]?["emailAddress"]?["address"]?.stringValue ?? ""
    guard let received = o["receivedDateTime"]?.stringValue.flatMap({ try? parseInstantMs($0) }) else {
      throw .status(200, op: "metadata")
    }
    var junk = false
    let parent = o["parentFolderId"]?.stringValue
    if let parent { junk = try await specialFolders().junk == parent }
    cache.put(id, address: address, receivedMs: received, folder: parent, junk: junk)
    return Self.metadata(id, address, received)
  }

  static func metadata(_ id: String, _ address: String, _ receivedMs: Int64) -> MailMessageMetadata {
    MailMessageMetadata(id: id, internalDate: String(receivedMs), sizeEstimate: nil, headers: [("From", address)])
  }

  /// The MIME (`$value`), served as bytes and handed on as base64url. An empty 2xx is reported as
  /// that status (the engine treats it as `gone`).
  public func messageRaw(id: String) async throws(MailAPIError) -> MailRawMessage {
    let received = try await messageMetadata(id: id).internalDate
    let inbox = try await inboxFolderID()
    let body = try await messageValue(id: id)
    let entry = cache.get(id)
    return MailRawMessage(
      id: id, rawBase64URL: Base64.encodeURL(body), internalDate: received, spam: entry?.junk ?? false,
      inInbox: entry?.folder == inbox)
  }

  public func inboxFolderID() async throws(MailAPIError) -> String {
    if let id = cache.inboxID { return id }
    let o = try await object(.get, url("/me/mailFolders/inbox", [("$select", "id")]), op: "mailbox")
    guard let id = o["id"]?.stringValue, !id.isEmpty else { throw .status(200, op: "mailbox") }
    cache.inboxID = id
    return id
  }

  public func messageValue(id: String) async throws(MailAPIError) -> Data {
    let res = try await call(.get, url(path(id) + "/$value"), json: false, op: "raw")
    guard !res.body.isEmpty else { throw .status(res.status, op: "raw") }
    return res.body
  }

  public func messageHeaderList(id: String) async throws(MailAPIError) -> [(name: String, value: String)] {
    let o = try await object(.get, url(path(id), [("$select", "internetMessageHeaders")]), op: "headers")
    return (o["internetMessageHeaders"]?.arrayValue ?? []).compactMap { h in
      guard let n = h["name"]?.stringValue, let v = h["value"]?.stringValue else { return nil }
      return (n, v)
    }
  }

  // MARK: Subscriptions (§6)

  func subscriptionBody(_ notificationURL: String, _ lifecycleURL: String, clientState: String, expiresAtMs: Int64)
    -> JSONValue
  {
    .object(
      JSONObject([
        ("changeType", .string("created")), ("notificationUrl", .string(notificationURL)),
        ("lifecycleNotificationUrl", .string(lifecycleURL)), ("resource", .string(Self.subscriptionResource)),
        ("expirationDateTime", .string(Instant.iso(expiresAtMs) ?? "")), ("clientState", .string(clientState)),
      ]))
  }

  /// The expiry Graph answered, else the one asked for.
  static func expiry(_ o: JSONObject, asked: Int64) -> Int64 {
    o["expirationDateTime"]?.stringValue.flatMap { try? parseInstantMs($0) } ?? asked
  }

  /// Creates the subscription. A `409 Conflict` means the app already has one for the inbox
  /// in this mailbox (another iPhone's, or one this iPhone lost track of): it is deleted and the
  /// subscription created again, once.
  func createSubscription(_ n: String, _ l: String, state: OutlookLinkState) async throws(MailAPIError)
    -> MailSubscription
  {
    let asked = nowMs() + Self.subscriptionLifetimeMs
    let body = subscriptionBody(n, l, clientState: state.clientState, expiresAtMs: asked)
    let o: JSONObject
    do {
      o = try await object(.post, url("/subscriptions"), body: body, op: "subscribe")
    } catch .status(409, _) {
      try await deleteMailboxSubscriptions()
      o = try await object(.post, url("/subscriptions"), body: body, op: "subscribe")
    }
    guard let id = o["id"]?.stringValue, !id.isEmpty else { throw .status(200, op: "subscribe") }
    var kept = state
    kept.subscriptionID = id
    kept.subscriptionResource = Self.subscriptionResource
    try? link.write(kept)
    return MailSubscription(expiresAtMs: Self.expiry(o, asked: asked))
  }

  /// Deletes every subscription the app holds on this mailbox's messages (the 409 case), the
  /// inbox's and any older one on every folder.
  func deleteMailboxSubscriptions() async throws(MailAPIError) {
    let o = try await object(.get, url("/subscriptions"), op: "subscriptions")
    for s in o["value"]?.arrayValue ?? [] {
      guard let id = s["id"]?.stringValue, !id.isEmpty else { continue }
      var resource = (s["resource"]?.stringValue ?? "").lowercased()
      if resource.hasPrefix("/") { resource.removeFirst() }
      guard Self.subscriptionResources.contains(resource) else { continue }
      try await deleteSubscription(id: id)
    }
  }

  /// `DELETE /subscriptions/{id}`; one that is already gone is success. Also used, with only a
  /// refresh token left, when the account leaves this iPhone.
  public func deleteSubscription(id: String) async throws(MailAPIError) {
    do {
      _ = try await call(.delete, url("/subscriptions/\(FormEncoding.escape(id))"), op: "unsubscribe")
    } catch .status(404, _) {}
  }
}

// MARK: - MailSource

extension GraphClient: MailSource {
  public var maxSendersPerList: Int { Self.maxDomainsPerList }

  /// None (§2): every cycle runs the filtered listing.
  public func changeToken() async throws(MailAPIError) -> String? { nil }

  public func list(senders: [String], since: Int64, pageToken: String?) async throws(MailAPIError) -> MailListPage {
    try await listMessages(senders: senders, sinceSec: since, pageToken: pageToken)
  }

  public func metadata(id: String) async throws(MailAPIError) -> MailMessageMetadata { try await messageMetadata(id: id) }

  public func raw(id: String) async throws(MailAPIError) -> MailRawMessage { try await messageRaw(id: id) }

  /// A subscription for the server's two hook URLs and the link's clientState; nil when the
  /// server relays no Outlook wakes, or this iPhone keeps no clientState.
  public func subscribe(_ push: MailboxPushConfig) async throws(MailAPIError) -> MailSubscription? {
    guard case .outlook(let n, let l) = push, let state = try? link.read() else { return nil }
    return try await createSubscription(n, l, state: state)
  }

  /// `PATCH` this iPhone's subscription to now + 6 d 23 h (and the server's current notification
  /// URL); a subscription Graph no longer has is created again, and one on every folder is
  /// replaced by one on the inbox.
  public func renew(_ push: MailboxPushConfig) async throws(MailAPIError) -> MailSubscription? {
    guard case .outlook(let n, let l) = push, var state = try? link.read() else { return nil }
    guard let id = state.subscriptionID else { return try await createSubscription(n, l, state: state) }
    if state.subscriptionResource != Self.subscriptionResource {
      try await deleteSubscription(id: id)
      state.subscriptionID = nil
      try? link.write(state)
      return try await createSubscription(n, l, state: state)
    }
    let asked = nowMs() + Self.subscriptionLifetimeMs
    let body = JSONValue.object(
      JSONObject([("expirationDateTime", .string(Instant.iso(asked) ?? "")), ("notificationUrl", .string(n))]))
    do {
      let o = try await object(.patch, url("/subscriptions/\(FormEncoding.escape(id))"), body: body, op: "renew")
      return MailSubscription(expiresAtMs: Self.expiry(o, asked: asked))
    } catch .status(404, _) {
      state.subscriptionID = nil
      try? link.write(state)
      return try await createSubscription(n, l, state: state)
    }
  }

  /// Deletes this iPhone's subscription only (never another iPhone's).
  public func stop() async throws(MailAPIError) {
    guard var state = try? link.read(), let id = state.subscriptionID else { return }
    try await deleteSubscription(id: id)
    state.subscriptionID = nil
    state.subscriptionResource = nil
    try? link.write(state)
  }

  /// `GET /me/mailFolders/inbox?$select=id`: reads no message; `noMailbox` when the account has
  /// no Outlook mailbox.
  public func checkMailbox() async throws(MailAPIError) {
    _ = try await object(.get, url("/me/mailFolders/inbox", [("$select", "id")]), op: "mailbox")
  }
}
