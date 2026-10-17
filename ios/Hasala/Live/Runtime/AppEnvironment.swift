import CoreAuth
import CorePrimitives
import CoreStore
import CoreSync
import CoreTime
import Foundation
import HasalaKeychain
import UIKit

/// The live graph's fixed half (spec 04 §3, the composition root): the Keychain behind
/// `Secrets`, the API transport, the approval key, the passkey adapter, the clock and the
/// randomness, and the directory each account's store lives in. Built once per process,
/// before anything reads the Keychain: the fresh-install purge runs first (§4.4, R-03).
///
/// Everything per account (the store, sync, the Gmail lane, the screens' ledger) is
/// `AccountRuntime`'s; the account gate's state is `BootController`'s.
@MainActor
final class AppEnvironment {
  /// The app's Keychain access group (`$(AppIdentifierPrefix)app.hasala.ios`).
  static let keychainGroup = "8CFG28JHP3.app.hasala.ios"
  /// The group shared with extensions; the fresh-install purge clears it too.
  static let sharedKeychainGroup = "8CFG28JHP3.app.hasala.shared"

  let build: BuildInfo
  /// The API origin this run talks to (`BuildInfo.apiBaseURL()`).
  let apiBaseURL: URL
  let transport: URLSessionTransport
  let account: AccountEnvironment
  /// Onboarding step 0: the device has a passcode.
  let hasPasscode: @MainActor () -> Bool
  /// The fresh-install purge's outcome; `.notNow` until protected data is available.
  private(set) var installCheck: InstallCheck.Outcome
  /// Debug simulator runs only: the Keychain refused this unsigned build, so the
  /// secrets live in memory for this process (see `debugSecretStore`).
  let secretsInMemory: Bool
  private let keychain: KeychainSecretStore

  init(
    build: BuildInfo, apiBaseURL: URL, transport: URLSessionTransport, account: AccountEnvironment,
    keychain: KeychainSecretStore, installCheck: InstallCheck.Outcome, secretsInMemory: Bool,
    hasPasscode: @escaping @MainActor () -> Bool
  ) {
    self.build = build
    self.apiBaseURL = apiBaseURL
    self.transport = transport
    self.account = account
    self.keychain = keychain
    self.installCheck = installCheck
    self.secretsInMemory = secretsInMemory
    self.hasPasscode = hasPasscode
  }

  /// `Hasala-Client: ios/<version>/<build>` (`02` §6.1).
  var clientHeader: String { "ios/\(build.marketingVersion)/\(build.buildNumber)" }

  /// `CFBundleVersion` as the launch probe compares it with `meta.min_ios_build`.
  var buildNumber: Int { Int(build.buildNumber.split(separator: ".").joined()) ?? 0 }

  /// Runs the fresh-install purge again once protected data is available (a launch in
  /// the background before first unlock defers it).
  func retryInstallCheck() -> InstallCheck.Outcome {
    if case .done = installCheck { return installCheck }
    // An unsigned Debug simulator build keeps its secrets in memory: nothing to purge.
    if secretsInMemory { return .done }
    installCheck = Self.purge(keychain)
    return installCheck
  }

  /// The fresh-install purge (§4.4). An `installID` that reads back means this install
  /// already purged: UserDefaults read as empty only before first unlock, so the purge
  /// needs protected data only when there is none. `isProtectedDataAvailable` is false
  /// on every locked iPhone with a passcode, so requiring it always would keep a silent
  /// push or a background task that launches the app on a locked iPhone from running.
  private static func purge(_ keychain: KeychainSecretStore, defaults: UserDefaults = .standard)
    -> InstallCheck.Outcome
  {
    if defaults.string(forKey: InstallCheck.installIDKey) != nil { return .done }
    return InstallCheck.run(
      protectedDataAvailable: UIApplication.shared.isProtectedDataAvailable, defaults: defaults, keychain: keychain,
      groups: [keychainGroup, sharedKeychainGroup], widgetsDirectory: nil)
  }

  /// "Remove this iPhone's data" from a wall (§4.7 row 2, without the server's writer
  /// revocation): the session is signed out (kept as `pending_logout` when the server
  /// can't be reached, so the logout is retried), then every Hasala item in both access
  /// groups and every account's files go, with what UserDefaults noted about the
  /// account. This iPhone's Google grant is revoked last, from the token read first.
  func eraseLocalData() async {
    let secrets = account.secrets
    let binding = try? secrets.binding()
    let session = try? secrets.session()
    let grant = binding?.userID.flatMap { MailboxLane.heldGrant(secrets: secrets, userID: $0) }
    let confirmed = await AccountSignIn.signOut(account)
    let pending = confirmed ? nil : (try? secrets.session())
    if let b = binding, let u = b.userID { AccountWipe.wipe(account, userID: u, writerID: b.writerID) }
    if let s = session, let u = UserID(s.user_id) { AccountWipe.wipe(account, userID: u, writerID: nil) }
    if let dir = account.accountsDirectory,
      let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
    {
      for item in items { try? FileManager.default.removeItem(at: item) }
    }
    _ = keychain.purgeAll(groups: [Self.keychainGroup, Self.sharedKeychainGroup])
    LocalAccountData.forget()
    if let pending { try? secrets.writeSession(pending) }
    if let grant {
      // Through the queue a later connect waits for (`MailGrantEnds`).
      let build = self.build
      MailGrantEnds.shared.enqueue { await MailboxLane.endGrant(grant, build: build, stopWatch: false) }
    }
  }

  /// `<Application Support>/Hasala/accounts`; each account's store is `<user_id>/` below it.
  static func accountsDirectory() -> URL? {
    guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
      return nil
    }
    let dir = support.appendingPathComponent("Hasala", isDirectory: true).appendingPathComponent(
      "accounts", isDirectory: true)
    try? FileHygiene.prepareDirectory(dir)
    return dir
  }

  /// The live environment for this build.
  static func live(build: BuildInfo = .current) -> AppEnvironment {
    let base = BuildInfo.apiBaseURL()
    let keychain = KeychainSecretStore(accessGroup: keychainGroup)
    // The purge runs before anything reads the Keychain (§4.4).
    let install = purge(keychain)
    var store: any SecretStore = keychain
    var inMemory = false
    #if DEBUG && targetEnvironment(simulator)
      if let fallback = debugSecretStore(keychain) {
        store = fallback
        inMemory = true
      }
    #endif
    let transport = URLSessionTransport(
      baseURL: base, clientHeader: "ios/\(build.marketingVersion)/\(build.buildNumber)")
    let approvalKeys: any ApprovalKeySigner
    #if DEBUG && targetEnvironment(simulator)
      approvalKeys = SimulatorApprovalKey()
    #else
      approvalKeys = SecureEnclaveApprovalKey(store: store)
    #endif
    let env = AccountEnvironment(
      client: AuthClient(transport: transport), secrets: Secrets(store: store, apiHost: base.host() ?? "api.hasala.app"),
      approvalKeys: approvalKeys, passkeys: PasskeyProviderAdapter(), clock: SystemClock(), random: SystemRandom(),
      apiBase: base.absoluteString, accountsDirectory: accountsDirectory())
    let hasPasscode: @MainActor () -> Bool
    #if DEBUG && targetEnvironment(simulator)
      // A simulator has no passcode; Debug runs there sign up with a password.
      hasPasscode = { true }
    #else
      hasPasscode = { DevicePasscode.isSet() }
    #endif
    return AppEnvironment(
      build: build, apiBaseURL: base, transport: transport, account: env, keychain: keychain, installCheck: install,
      secretsInMemory: inMemory, hasPasscode: hasPasscode)
  }

  #if DEBUG && targetEnvironment(simulator)
    /// An unsigned simulator build has no `keychain-access-groups` entitlement, so every
    /// Keychain call fails with `errSecMissingEntitlement`. Debug simulator runs then keep
    /// the secrets in memory for the process (a relaunch starts signed out). A signed
    /// simulator build (the default "Sign to Run Locally" embeds the entitlements) uses
    /// the Keychain like a device. Never compiled into a device or Release build.
    static func debugSecretStore(_ keychain: KeychainSecretStore) -> (any SecretStore)? {
      let probe = SecretItem.gmailRefresh(userID: UserID("00000000-0000-4000-8000-000000000000")!)
      do {
        try keychain.write(probe, Data([1]))
        try keychain.delete(probe)
        return nil
      } catch {
        return MemorySecretStore()
      }
    }
  #endif
}
