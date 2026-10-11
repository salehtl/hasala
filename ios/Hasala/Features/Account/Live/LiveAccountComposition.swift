import CoreAuth
import CorePrimitives
import CoreStore
import CoreSync
import CoreTime
import Foundation
import HasalaKeychain
import UIKit

/// Builds the live account gate for Release builds (spec 04 §3's composition root, the
/// account part): the Keychain, the auth client for `HasalaAPIBaseURL`, the passkey and
/// Secure Enclave adapters, and the boot state the gate starts in (§6.5).
///
/// TODO(WS-14 + the Gmail and sync lanes): the setup steps' Live implementations
/// (`MailboxConnecting` from the Gmail lane, `SetupAuthoring` over OpAuthor + Outbox).
/// Until they land, the gate is not switched on in Release (RootView keeps the A0
/// shell); `make(mailbox:setup:)` takes them so the switch is one line.
enum LiveAccountComposition {
  static let keychainGroup = "8CFG28JHP3.app.hasala.ios"

  @MainActor
  static func environment(build: BuildInfo = .current) -> AccountEnvironment {
    let store = KeychainSecretStore(accessGroup: keychainGroup)
    let host = build.apiBaseURL.host() ?? "api.hasala.app"
    let transport = URLSessionTransport(
      baseURL: build.apiBaseURL, clientHeader: "ios/\(build.marketingVersion)/\(build.buildNumber)")
    let accounts = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
      .appendingPathComponent("accounts", isDirectory: true)
    return AccountEnvironment(
      client: AuthClient(transport: transport), secrets: Secrets(store: store, apiHost: host),
      approvalKeys: SecureEnclaveApprovalKey(store: store), passkeys: LivePasskeyProvider(), clock: SystemClock(),
      random: SystemRandom(), apiBase: build.apiBaseURL.absoluteString, accountsDirectory: accounts)
  }

  /// The gate's first phase from what is on this iPhone (§6.5, without the network).
  @MainActor
  static func initialPhase(_ env: AccountEnvironment) -> AccountSession.Phase {
    switch Boot.decide(Boot.gather(env)) {
    case .signedOut, .foreignData: return .signedOut
    case .onboardingKeys: return .needsKeys
    case .needsUnlock: return .needsUnlock(passkeyCanUnlock: false)
    // TODO(WS-14): the signed-out-bound sheet (C2b/C2b-P) and the unenrolled and
    // waiting-for-unlock walls; until then these sign in again from Welcome.
    case .signedOutBound, .unenrolled, .waitingForUnlock: return .signedOut
    case .restoring, .opening: return .ready
    }
  }

  @MainActor
  static func make(mailbox: MailboxConnecting, setup: SetupAuthoring) -> AccountSession {
    // The fresh-install purge runs before anything reads the Keychain (§4.4, R-03).
    _ = InstallCheck.run(
      protectedDataAvailable: UIApplication.shared.isProtectedDataAvailable, defaults: .standard,
      keychain: KeychainSecretStore(accessGroup: keychainGroup),
      groups: [keychainGroup, "8CFG28JHP3.app.hasala.shared"], widgetsDirectory: nil)
    let env = environment()
    return AccountSession(
      services: AccountServices(
        account: LiveAccountService(env: env), mailbox: mailbox, setup: setup,
        notifications: SystemNotificationPermission()),
      phase: initialPhase(env))
  }
}
