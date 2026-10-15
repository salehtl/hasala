// The engine's view of the rest of the app (spec 04 §3: the AccountRuntime wires these).
//
//   MailboxLedger      the fold and the outbox: pull to head, the trusted senders, known cards,
//                      dedup, authoring the non-txn ops of the lane, flush (CoreSync/CoreOutbox/
//                      CoreDomain; Live/ wires it)
//   MailboxServer      hasalad's mailbox routes 34-38 and `meta.gmail_watch_topic` (spec 02)
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

public protocol MailboxLedger: Sendable {
  /// Pull to head so peers' ops are visible to dedup (§7.5 step 2).
  func syncToHead() async throws(MailboxLedgerError)
  /// The `sender_trust_set` fold: domain -> trusted (03c §7.1).
  func senderTrust() async -> [String: Bool]
  /// `card_linked` keys and states (03b §4.3).
  func knownCards() async -> [CardKey: CardState]
  /// Which of these Gmail message ids a projected transaction already carries
  /// (`txn.mailbox_message_id`), so they are never downloaded again (§7.5).
  func projectedMessageIDs(among ids: [String]) async -> Set<String>
  /// Whether an op with this ingest id has folded or is pending on this device.
  func isIngested(_ ingestID: String) async -> Bool
  /// Authors `account_set` / `card_linked` for the given cards (03b §4.2-§4.3) and enqueues them.
  /// The engine no longer calls it (setup has no cards step); kept for marking a card later.
  func authorCards(_ decisions: [CardDecision]) async throws(MailboxLedgerError)
  /// Authors `sender_trust_set {domain, trusted}` (03c §7.1; "Add a sender", "Trust <domain>").
  func authorSenderTrust(domain: String, trusted: Bool) async throws(MailboxLedgerError)
  /// Uploads the outbox (§5.5).
  func flush() async -> FlushOutcome
}

public enum MailboxLinkStatus: Sendable, Equatable {
  case noLink
  case holder(isThisDevice: Bool, watchExpiresAtMs: Int64?)
}

public enum MailboxServerError: Error, Sendable, Equatable {
  case offline
  /// 409 `not_holder`: another iPhone holds the link.
  case notHolder
  /// 404 `no_link`.
  case noLink
  /// 409 `no_watch_topic` from route 36: the server relays no wakes (no Pub/Sub push, so
  /// `meta.gmail_watch_topic` is null) and records no watch.
  case noWatchTopic
  /// Any other refusal (status and the server's content-free code).
  case refused(Int, String)
}

public protocol MailboxServer: Sendable {
  /// `GET /api/v1/mailbox/link` (route 37).
  func linkStatus() async throws(MailboxServerError) -> MailboxLinkStatus
  /// `POST /api/v1/mailbox/link/challenge` (route 34): the nonce (b64url of 32 bytes).
  func linkChallenge() async throws(MailboxServerError) -> String
  /// `PUT /api/v1/mailbox/link {id_token, step_up}` (route 35).
  func putLink(idToken: String, stepUp: JSONValue) async throws(MailboxServerError) -> MailboxLinkStatus
  /// `PUT /api/v1/mailbox/link/watch {expires_at}` (route 36; holder only; `.noWatchTopic`
  /// when the server has no topic).
  func putWatch(expiresAtMs: Int64) async throws(MailboxServerError)
  /// `DELETE /api/v1/mailbox/link {step_up}` (route 38).
  func deleteLink(stepUp: JSONValue) async throws(MailboxServerError)
  /// `GET /api/v1/meta` → `gmail_watch_topic` (nil: the server relays no wakes).
  func watchTopic() async throws(MailboxServerError) -> String?
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
