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
      .resetPassword, .recoverWithPassword, .rotatePhrase, .changeEmail, .freeze,
      .removePasskey, .changePassword, .removeDevice, .removeThisIPhone,
    ]
    #expect(AccountCapabilities.all.isSuperset(of: .beta))
    #expect(AccountCapabilities.beta.isDisjoint(with: hidden))
    #expect(AccountCapabilities.beta.union(hidden) == .all)
    #expect(AccountCapabilities.all.rawValue.nonzeroBitCount == 22)
    // Someone who lost their passkey can get back in (and then delete the account).
    #expect(AccountCapabilities.beta.isSuperset(of: [.recoverAccess, .deleteAccount]))
    #expect(AccountCapabilities.beta.contains(.addPasskey))
    #expect(AccountCapabilities.beta.contains(.changeName))
    #expect(AccountCapabilities.beta.contains(.unfreeze))
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

  /// Sign-in & security never offers removing the account's last way to sign in.
  @Test func theLastPasskeyIsNeverOfferedForRemoval() {
    let mine = PasskeyRow(id: "pk-1", provider: "iCloud Keychain", detail: "", isThisCredential: true)
    let other = PasskeyRow(id: "pk-2", provider: "Work iPad", detail: "", isThisCredential: false)
    func state(_ passkeys: [PasskeyRow], password: Bool) -> SecurityState {
      SecurityState(email: "maya@example.com", emailVerified: true, passkeys: passkeys,
                    passwordChanged: password ? "Set" : nil, devices: [], lastSignIn: "", phraseConfirmed: "",
                    frozen: nil)
    }
    // Passkey-only, one passkey (another device's, say after a recovery here): kept.
    #expect(!state([other], password: false).canRemove(other))
    // The passkey in hand is never removed from here.
    #expect(!state([mine, other], password: true).canRemove(mine))
    #expect(!state([mine], password: false).canRemove(mine))
    // Another passkey remains, or a password does: offered.
    #expect(state([mine, other], password: false).canRemove(other))
    #expect(state([other], password: true).canRemove(other))
    // A row that isn't the account's isn't offered.
    #expect(!state([mine], password: true).canRemove(other))
    // The password goes only while a passkey stays.
    #expect(!state([], password: true).canRemovePassword)
    #expect(state([mine], password: true).canRemovePassword)
    #expect(!state([mine], password: false).canRemovePassword)
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
