// The engine's view of the rest of the app (spec 04 §3: the AccountRuntime wires these).
//
//   MailboxLedger      the fold and the outbox: pull to head, the trusted senders, known cards,
//                      dedup, authoring the non-txn ops of the lane, flush (CoreSync/CoreOutbox/
//                      CoreDomain; Live/ wires it)
//   MailboxServer      hasalad's mailbox routes 34-38 and the push settings in `meta` (spec 02)
//   MailboxStepUp      the WebAuthn / device step-up proof for mailbox.link and mailbox.unlink
//                      (spec 04 §6.3; the auth lane implements it)
import CoreJSON
import Foundation

public enum FlushOutcome: Sendable, Equatable {
  case flushed
  /// 413 `account_full`: halt with the watermark intact (§7.5 step 8).
  case accountFull
  /// Offline or any other failure: the watermark does not move; the next trigger retries.
  case failed
}

public struct CardDecision: Sendable, Equatable {
  public var card: CardKey
  public var state: CardState
  /// An existing account to attach the card to; nil = a new account per bank+last4 (03b §4.2).
  public var accountID: String?
  public init(card: CardKey, state: CardState, accountID: String? = nil) {
    self.card = card
    self.state = state
    self.accountID = accountID
  }
}

public struct MailboxLedgerError: Error, Sendable, Equatable {
  public let detail: String
  public init(_ detail: String) { self.detail = detail }
}

public struct MailboxRetirePlan: Sendable, Equatable {
  public var grantID: String
  public var provider: String
  public var legacy: Bool
  public var total: Int
  public var edited: Int
  public var countKnown: Bool

  public init(grantID: String, provider: String, legacy: Bool, total: Int, edited: Int, countKnown: Bool = true) {
    self.grantID = grantID
    self.provider = provider
    self.legacy = legacy
    self.total = total
    self.edited = edited
    self.countKnown = countKnown
  }
}

public protocol MailboxLedger: Sendable {
  /// Pull to head so peers' ops are visible to dedup (§7.5 step 2).
  func syncToHead() async throws(MailboxLedgerError)
  /// The `sender_trust_set` fold: domain -> trusted (03c §7.1).
  func senderTrust() async -> [String: Bool]
  /// `card_linked` keys and states (03b §4.3).
  func knownCards() async -> [CardKey: CardState]
  /// Which of these provider message ids a projected transaction already carries
  /// (`txn.mailbox_message_id`), so they are never downloaded again (§7.5).
  func projectedMessageIDs(among ids: [String]) async -> Set<String>
  /// Whether an op with this ingest id has folded or is pending on this device.
  func isIngested(_ ingestID: String) async -> Bool
  func textOverlap() async throws(MailboxLedgerError) -> TextOverlap?
  /// Authors `account_set` / `card_linked` for the given cards (03b §4.2-§4.3) and enqueues them.
  /// The engine no longer calls it (setup has no cards step); kept for marking a card later.
  func authorCards(_ decisions: [CardDecision]) async throws(MailboxLedgerError)
  /// Authors `sender_trust_set {domain, trusted}` (03c §7.1; "Add a sender", "Trust <domain>").
  func authorSenderTrust(domain: String, trusted: Bool) async throws(MailboxLedgerError)
  func retirePlan(grantID: String, provider: String) async -> MailboxRetirePlan
  func authorRetire(_ plan: MailboxRetirePlan) async throws(MailboxLedgerError)
  /// Uploads the outbox (§5.5).
  func flush() async -> FlushOutcome
}

public enum MailboxLinkStatus: Sendable, Equatable {
  case noLink
  case holder(isThisDevice: Bool, watchExpiresAtMs: Int64?)
}

/// `PUT /api/v1/mailbox/link`'s answer: the link, and for Outlook the Graph subscription's
/// `clientState` (b64url of 32 bytes; the server keeps only its hash). The caller stores it in
/// the Keychain (`SecretItem.outlookClientState`) and never logs it.
public struct MailboxLinkResult: Sendable, Equatable {
  public var status: MailboxLinkStatus
  public var clientState: String?
  public init(status: MailboxLinkStatus, clientState: String? = nil) {
    self.status = status
    self.clientState = clientState
  }
}

/// Where the server relays a provider's push (from `GET /api/v1/meta`).
public enum MailboxPushConfig: Sendable, Equatable {
  /// `meta.gmail_watch_topic`: the Pub/Sub topic for `users.watch`.
  case gmail(topic: String)
  /// `meta.outlook_notification_url` and `meta.outlook_lifecycle_url` for a Graph subscription.
  case outlook(notificationURL: String, lifecycleURL: String)
  /// The server relays no wakes for this provider: new mail is caught by the other triggers.
  case none
}

public enum MailboxServerError: Error, Sendable, Equatable {
  case offline
  /// 409 `not_holder`: another iPhone holds the link.
  case notHolder
  /// 404 `no_link`.
  case noLink
  /// 409 `no_watch_topic` from route 36: the server relays no wakes for the link's provider (its
  /// push settings in `meta` are null) and records no watch.
  case noWatchTopic
  case otherProvider
  /// Any other refusal (status and the server's content-free code).
  case refused(Int, String)
}

public protocol MailboxServer: Sendable {
  /// `GET /api/v1/mailbox/link` (route 37).
  func linkStatus() async throws(MailboxServerError) -> MailboxLinkStatus
  /// `POST /api/v1/mailbox/link/challenge` (route 34): the nonce (b64url of 32 bytes).
  func linkChallenge() async throws(MailboxServerError) -> String
  /// `PUT /api/v1/mailbox/link {provider, id_token, step_up}` (route 35). Linking one provider
  /// replaces the account's link to the other.
  func putLink(provider: MailProviderID, idToken: String, stepUp: JSONValue) async throws(MailboxServerError)
    -> MailboxLinkResult
  /// `PUT /api/v1/mailbox/link/watch {expires_at}` (route 36; holder only; `.noWatchTopic`
  /// when the server has no topic).
  func putWatch(expiresAtMs: Int64) async throws(MailboxServerError)
  /// `DELETE /api/v1/mailbox/link {step_up}` (route 38).
  func deleteLink(stepUp: JSONValue) async throws(MailboxServerError)
  /// `GET /api/v1/meta` → where the server relays `provider`'s push (`.none`: it relays none).
  func pushConfig(provider: MailProviderID) async throws(MailboxServerError) -> MailboxPushConfig
  func linkStatus(provider: MailProviderID) async throws(MailboxServerError) -> MailboxLinkStatus
}

extension MailboxServer {
  public func linkStatus(provider: MailProviderID) async throws(MailboxServerError) -> MailboxLinkStatus {
    try await linkStatus()
  }
}

public enum MailboxStepUpError: Error, Sendable, Equatable {
  case cancelled, unavailable, failed
}

public protocol MailboxStepUp: Sendable {
  /// A step-up proof (the `step_up` JSON of spec 02 §8) for `kind` ("mailbox.link" or
  /// "mailbox.unlink") over `payloadHash` (`P`; SHA-256(id_token) for a link, spec 02 route 35).
  func proof(kind: String, payloadHash: Data?) async throws(MailboxStepUpError) -> JSONValue
}

/// The trigger a cycle runs for (spec 04 §5.8). `refresh` and `launch` always list.
public enum MailboxTrigger: String, Sendable {
  case launch, foreground, refresh, silentPush = "silent_push", appRefresh = "app_refresh"
  case processing, timer, retry
}
