import AuthenticationServices
import CoreMailbox
import Foundation
import HasalaModels
import Testing

@testable import Hasala

@MainActor
@Suite("Mailbox sign-in session")
struct WebAuthenticationPresenterTests {
  let url = URL(string: "https://accounts.example.test/authorize")!

  @Test func outlookGetsAPrivateSessionAndGmailTheSharedOne() {
    let outlook = WebAuthenticationPresenter(for: .outlook).makeSession(url: url, scheme: "app.test") { _, _ in }
    let gmail = WebAuthenticationPresenter(for: .gmail).makeSession(url: url, scheme: "app.test") { _, _ in }
    #expect(outlook.prefersEphemeralWebBrowserSession)
    #expect(!gmail.prefersEphemeralWebBrowserSession)
  }

  @Test func everyProviderLaneAsksTheProvider() {
    for p in MailboxProvider.allCases {
      #expect(WebAuthenticationPresenter(for: p).ephemeral == p.providerID.prefersEphemeralSession)
    }
    #expect(MailProviderID.outlook.prefersEphemeralSession && !MailProviderID.gmail.prefersEphemeralSession)
  }
}
