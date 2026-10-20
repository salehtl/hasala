// The Outlook provider: Microsoft OAuth (MicrosoftOAuthClient), the Graph mail client
// (GraphClient) and the Outlook Authentication-Results rule (AuthResults.analyze(_:provider:
// .outlook)), behind MailProvider. Personal Microsoft accounts only.
//
// The trust gate ships closed (docs/decisions/outlook-mailbox.md §3 "Shipping gate"): until the
// owner's checks C1–C7 pass on real mail, `trustProven` is false and every Outlook message goes
// to review, whatever the rule says. The verdict's reason is still recorded in the row's gates.
import CoreMail
import CoreTime
import Foundation

public struct OutlookProvider: MailProvider {
  /// Turned on only in a commit that cites the WP0 results in outlook-mailbox.md.
  public static let outlookTrustProven = false
  /// Graph allows four concurrent requests per mailbox; the fourth is for listing and the
  /// subscription (§5).
  public static let downloadWidth = 3

  public let microsoft: MicrosoftOAuthClient
  public let trustProven: Bool
  let http: any HTTPExchange
  let base: String
  let link: any OutlookLinkStore
  let clock: any Clock

  /// `http` carries the Graph calls (an ephemeral session, as for Google). `link` is the
  /// account's `app.hasala.outlook.clientstate` item.
  public init(
    oauth: MicrosoftOAuthClient, http: any HTTPExchange, link: any OutlookLinkStore, clock: any Clock,
    base: String = GraphClient.defaultBase, trustProven: Bool = OutlookProvider.outlookTrustProven
  ) {
    microsoft = oauth
    self.http = http
    self.link = link
    self.clock = clock
    self.base = base
    self.trustProven = trustProven
  }

  public var id: MailProviderID { .outlook }
  public var oauth: any MailOAuthClient { microsoft }
  public var maxDownloadWidth: Int { Self.downloadWidth }
  /// `stop` deletes the subscription id this iPhone created, never another's.
  public var stopIsDeviceScoped: Bool { true }

  public func source(accessToken: AccessToken) -> any MailSource { graph(accessToken: accessToken.value) }

  public var listsByAddress: Bool { true }

  public func source(accessToken: AccessToken, senderAddresses: [String]) -> any MailSource {
    graph(accessToken: accessToken.value, senderAddresses: senderAddresses)
  }

  public func unlisted(_ trusted: [String], senderAddresses: [String]) -> [String] {
    OutlookSenders.unlisted(trusted, known: OutlookSenders.known + senderAddresses)
  }

  public func graph(accessToken: String, senderAddresses: [String] = []) -> GraphClient {
    let clock = self.clock
    return GraphClient(
      http: http, accessToken: accessToken, link: link, base: base, knownSenders: OutlookSenders.known + senderAddresses,
      nowMs: { clock.nowMs() })
  }

  /// The Outlook rule; while the gate is closed a passing verdict is not trusted (the reason is
  /// kept, the verified domain is not), so the message waits for review.
  public func analyzeAuthResults(_ headerBlock: String) -> AuthResults.Analysis {
    let a = AuthResults.analyze(headerBlock, provider: .outlook)
    guard !trustProven, a.verdict.trusted else { return a }
    return AuthResults.Analysis(verdict: AuthResults.Verdict(trusted: false, reason: a.verdict.reason), domain: nil)
  }

  /// Keeps the link's clientState for the subscription (a new link starts with no subscription
  /// id: the old subscription carries the old clientState and is replaced). A server that
  /// returned none relays no Outlook wakes: nothing is kept, and nothing subscribes.
  public func installLink(_ result: MailboxLinkResult) throws(MailAuthError) {
    do {
      if let cs = result.clientState, !cs.isEmpty {
        try link.write(OutlookLinkState(clientState: cs))
      } else {
        try link.delete()
      }
    } catch {
      throw .notNow
    }
  }

  public func forgetLink() { try? link.delete() }
}
