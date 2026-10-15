// The Gmail provider: Google OAuth (GoogleOAuthClient), the Gmail REST client (GmailClient) and
// the `mx.google.com` Authentication-Results rule (AuthResults.analyze), behind MailProvider.
import CoreMail
import Foundation

public struct GmailProvider: MailProvider {
  public let google: GoogleOAuthClient
  let http: any HTTPExchange
  let base: String

  /// `http` carries the Gmail API calls (the app's ephemeral session for Google, §7.2).
  public init(oauth: GoogleOAuthClient, http: any HTTPExchange, base: String = GmailClient.defaultBase) {
    google = oauth
    self.http = http
    self.base = base
  }

  public var id: MailProviderID { .gmail }
  public var oauth: any MailOAuthClient { google }

  public func source(accessToken: AccessToken) -> any MailSource {
    GmailClient(http: http, accessToken: accessToken.value, base: base)
  }

  /// Trusts only the topmost Authentication-Results header with authserv-id `mx.google.com`.
  public func analyzeAuthResults(_ headerBlock: String) -> AuthResults.Analysis { AuthResults.analyze(headerBlock) }
}
