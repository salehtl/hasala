import Foundation
import Testing

@testable import Hasala

/// The integration contracts the account screens and the live runtime share.
@MainActor
@Suite("Account capabilities")
struct AccountCapabilitiesTests {
  func session(_ account: MockAccountService = MockAccountService()) -> AccountSession {
    let services = AccountServices(
      account: account, mailbox: MockMailbox(offersSampleData: false), setup: MockSetupAuthoring(),
      notifications: MockNotificationPermission())
    return AccountSession(services: services, phase: .ready)
  }

  @Test func betaIsTheAgreedSubset() {
    let hidden: AccountCapabilities = [
      .resetPassword, .recoverAccess, .rotatePhrase, .addPasskey, .changeEmail, .freeze,
      .removePasskey, .changePassword, .removeDevice, .removeThisIPhone,
    ]
    #expect(AccountCapabilities.all.isSuperset(of: .beta))
    #expect(AccountCapabilities.beta.isDisjoint(with: hidden))
    #expect(AccountCapabilities.beta.union(hidden) == .all)
    #expect(AccountCapabilities.all.rawValue.nonzeroBitCount == 19)
  }

  /// Sign-in & security points to support when the beta hides an action, and doesn't offer
  /// the lockdown checklist it couldn't carry out.
  @Test func securityFollowsTheCapabilities() {
    let mock = MockAccountService(existing: .passkey, signedIn: true)
    let s = session(mock)
    let model = SecurityModel(session: s)
    #expect(!model.lacksAnAction)
    #expect(model.offersLockdown)
    mock.capabilities = .beta
    #expect(s.capabilities == .beta)
    #expect(model.lacksAnAction)
    #expect(!model.offersLockdown)
  }

  @Test func mocksOfferEverythingByDefault() {
    let s = session()
    #expect(s.account.capabilities == .all)
    #expect(s.capabilities == .all)
  }

  @Test func reviewAccountDefaultsOffAndClearsOnSignOut() {
    let s = session()
    #expect(s.reviewAccount == false)
    s.reviewAccount = true
    s.signedOut()
    #expect(s.reviewAccount == false)
  }
}
