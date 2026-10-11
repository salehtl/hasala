import Foundation

// The account surface the onboarding, sign-in and Sign-in & security screens bind to
// (spec 04 §6, §15.1). Views talk to `AccountService` only; Debug builds and UI tests
// run it on `MockAccountService`, and the live implementation (CoreAuth over the
// `02` §7 routes, passkeys through `PasskeyAuthenticator`, keys through CoreCrypto)
// replaces it in the composition root without touching a view.
//
// Every value here is content-free or the user's own entry; nothing is logged.

/// How a person signs in (PO A): a passkey with Face ID first, a password second.
enum SignInMethod: String, Equatable, Sendable, CaseIterable {
  case passkey
  case password
}

/// A new credential the user chose at signup or recovery. The password travels as typed
/// only as far as the service, which stretches it on the device and never sends it.
enum NewCredential: Equatable, Sendable {
  case passkey
  case password(String)

  var method: SignInMethod {
    switch self {
    case .passkey: .passkey
    case .password: .password
    }
  }
}

/// A live signup ceremony (`signup/begin`), alive for 30 minutes (spec 04 §6.2 step 6).
struct SignupTicket: Equatable, Sendable {
  var id: String
  /// The invite link's key matched and the typed address is the invite's: no email code.
  var emailProven: Bool
  var email: String
  var displayName: String
  var startedAt: Date

  func isExpired(now: Date) -> Bool { now.timeIntervalSince(startedAt) > 30 * 60 }
  /// The email code expires 10 minutes after it was sent (spec 04 §6.1.4); `startedAt`
  /// is the send, since "Resend code" starts a fresh ceremony.
  func codeExpired(now: Date) -> Bool { now.timeIntervalSince(startedAt) > 10 * 60 }
}

/// The 12 words, held in memory for the phrase screens only (spec 04 §6.7).
struct RecoveryPhrase: Equatable, Sendable {
  var words: [String]
  /// Four distinct positions (0-based, ascending) the user confirms (PO F).
  var confirmPositions: [Int]
}

/// What a sign-in leaves to do (spec 04 §6.5).
enum SignInOutcome: Equatable, Sendable {
  /// Keys are on this iPhone already: open the app.
  case ready
  /// Signed in, data still sealed here: unlock with a passkey's PRF (when the account has
  /// a PRF wrap) or the 12 words (§6.10).
  case needsUnlock(passkeyCanUnlock: Bool)
  /// The account was created but its keys never reached the server (C1 interrupted).
  case needsKeys
  /// The account is frozen (§6.11), by its holder or by the operator.
  case frozen(FreezeInfo.By)
}

/// The forgot-password ceremony on a new iPhone (C9, spec 04 §6.2).
struct ResetTicket: Equatable, Sendable {
  var id: String
  var email: String
  /// Another signed-in iPhone can approve (`approvers` from `password/reset/verify`).
  var approvers: Bool = false
  /// The 16-character reset code (`ResetCode`, §6.1.4) once the request is made.
  var resetCode: String?
}

/// Access recovery (C4, spec 04 §6.2): the words first, then an email code.
struct RecoveryTicket: Equatable, Sendable {
  var id: String
  /// "m•••@g•••.com"
  var emailHint: String
}

/// A password reset waiting for this iPhone's approval (C9 side A, spec 04 §6.12). No
/// device model or place: the server knows neither.
struct PendingReset: Identifiable, Equatable, Sendable {
  var id: String
  /// "2 minutes ago"
  var askedAgo: String
  var email: String
}

/// Who froze the account and when (spec 04 §6.11).
struct FreezeInfo: Equatable, Sendable {
  enum By: Equatable, Sendable { case holder, `operator` }
  var by: By
  /// Already formatted for display ("Sat 11 Oct at 21:20"), or nil when unknown.
  var when: String?
}

/// One row of Sign-in & security › Passkeys.
struct PasskeyRow: Identifiable, Equatable, Sendable {
  var id: String
  /// From the bundled AAGUID table; unknown → "Passkey".
  var provider: String
  var detail: String
  var isThisCredential: Bool
}

/// One row of Sign-in & security › Devices (from the verified roster; no device names).
struct DeviceRow: Identifiable, Equatable, Sendable {
  var id: String
  var title: String
  var detail: String
  var isThisDevice: Bool
}

/// Everything Sign-in & security shows (spec 04 §6.9).
struct SecurityState: Equatable, Sendable {
  var email: String
  var emailVerified: Bool
  var passkeys: [PasskeyRow]
  /// "Changed 3 Oct" when a password is set; nil when there is none.
  var passwordChanged: String?
  var devices: [DeviceRow]
  var lastSignIn: String
  /// The 12 words were confirmed at signup (all accounts) — "Confirmed 11 Sep".
  var phraseConfirmed: String
  var frozen: FreezeInfo?

  var hasPasskey: Bool { !passkeys.isEmpty }
  var hasPassword: Bool { passwordChanged != nil }
}

/// Server-side changes on Sign-in & security. Each runs a step-up (spec 04 §6.3) inside
/// the service: a passkey account asserts; a password-only account passes its password
/// (`device` proof: the password plus this iPhone's approval key).
enum SecurityAction: Equatable, Sendable {
  case addPasskey
  case removePasskey(id: String)
  case setPassword(new: String)
  case changePassword(new: String)
  case removePassword
  case removeDevice(id: String)
  case signOutEverywhere
  case freeze
  case unfreeze
  case deleteAccount

  /// The "Confirm it's you" explainer (spec 04 §6.3's table).
  var explainer: String {
    switch self {
    case .addPasskey: "Confirm it's you to add a passkey"
    case .removePasskey: "Confirm it's you to remove this passkey"
    case .setPassword: "Confirm it's you to set a password"
    case .changePassword: "Confirm it's you to change your password"
    case .removePassword: "Confirm it's you to remove your password"
    case .removeDevice: "Confirm it's you to remove this device"
    case .signOutEverywhere: "Confirm it's you to sign out everywhere"
    case .freeze: "Confirm it's you to freeze your account"
    case .unfreeze: "Confirm it's you to unfreeze your account"
    case .deleteAccount: "Confirm it's you to delete your account"
    }
  }
}

/// The account's identity as the app shows it (Profile, Done board). Cached in the
/// binding item in the live build (spec 04 §4.4, §6.8), never in UserDefaults.
struct AccountProfile: Equatable, Sendable {
  var displayName: String
  var email: String
  var method: SignInMethod

  /// "You're set, Maya." uses the first word of the name.
  var firstName: String {
    displayName.split(separator: " ").first.map(String.init) ?? displayName
  }
}

/// The account actions a build can actually carry out. Screens offer an action (a button,
/// a row, a link) only when its member is in `AccountService.capabilities`, so a build
/// never shows a control whose ceremony isn't wired yet.
///
/// Not main-actor isolated, so any isolation domain can read and compare it.
nonisolated struct AccountCapabilities: OptionSet, Sendable {
  let rawValue: UInt32

  init(rawValue: UInt32) { self.rawValue = rawValue }

  // MARK: Signup (C1, C1-P)

  /// Create an account with a passkey.
  static let signupPasskey = AccountCapabilities(rawValue: 1 << 0)
  /// Create an account with a password.
  static let signupPassword = AccountCapabilities(rawValue: 1 << 1)

  // MARK: Sign in (C2, C2-P, C2b, C2b-P)

  /// Sign in with a passkey.
  static let signInPasskey = AccountCapabilities(rawValue: 1 << 2)
  /// Sign in with an email and password.
  static let signInPassword = AccountCapabilities(rawValue: 1 << 3)

  // MARK: Unlock (C3)

  /// Open this iPhone's sealed data with the 12 words.
  static let unlockWithPhrase = AccountCapabilities(rawValue: 1 << 4)

  // MARK: Leaving

  /// Sign out of this iPhone, keeping its local data.
  static let signOut = AccountCapabilities(rawValue: 1 << 5)
  /// End every session on every device.
  static let signOutEverywhere = AccountCapabilities(rawValue: 1 << 6)
  /// Delete the account and everything the server holds for it.
  static let deleteAccount = AccountCapabilities(rawValue: 1 << 7)
  /// Remove this iPhone from the account and wipe what it holds locally.
  static let removeThisIPhone = AccountCapabilities(rawValue: 1 << 8)

  // MARK: Recovery (C9, C4)

  /// Forgot password on a new iPhone, approved from another signed-in iPhone.
  static let resetPassword = AccountCapabilities(rawValue: 1 << 9)
  /// Get back in with the 12 words plus an email code, setting a new sign-in method.
  static let recoverAccess = AccountCapabilities(rawValue: 1 << 10)

  // MARK: Sign-in & security

  /// Replace the 12 words with a new phrase.
  static let rotatePhrase = AccountCapabilities(rawValue: 1 << 11)
  /// Add another passkey to the account.
  static let addPasskey = AccountCapabilities(rawValue: 1 << 12)
  /// Change the account's email address.
  static let changeEmail = AccountCapabilities(rawValue: 1 << 13)
  /// Freeze (and unfreeze) the account.
  static let freeze = AccountCapabilities(rawValue: 1 << 14)
  /// Show the 12 words again behind a step-up.
  static let viewPhrase = AccountCapabilities(rawValue: 1 << 15)
  /// Remove one of the account's passkeys.
  static let removePasskey = AccountCapabilities(rawValue: 1 << 16)
  /// Set, change or remove the account's password.
  static let changePassword = AccountCapabilities(rawValue: 1 << 17)
  /// Remove another device from the account's roster.
  static let removeDevice = AccountCapabilities(rawValue: 1 << 18)

  /// Every action above. The default for services that don't say (the Debug mocks).
  static let all: AccountCapabilities = [
    .signupPasskey, .signupPassword,
    .signInPasskey, .signInPassword,
    .unlockWithPhrase,
    .signOut, .signOutEverywhere,
    .deleteAccount, .removeThisIPhone,
    .resetPassword, .recoverAccess,
    .rotatePhrase, .addPasskey, .changeEmail,
    .freeze, .viewPhrase,
    .removePasskey, .changePassword, .removeDevice,
  ]

  /// What the TestFlight beta offers: signup, sign-in, unlocking with the words, leaving
  /// (sign out, sign out everywhere, delete, remove this iPhone) and viewing the words.
  /// Password reset, access recovery, phrase rotation, adding or removing a passkey,
  /// setting or changing the password, removing another device, changing the email and
  /// freezing stay hidden.
  static let beta: AccountCapabilities = [
    .signupPasskey, .signupPassword,
    .signInPasskey, .signInPassword,
    .unlockWithPhrase,
    .signOut, .signOutEverywhere,
    .deleteAccount, .removeThisIPhone,
    .viewPhrase,
  ]
}

/// The account surface (spec 04 §6.2's ceremonies at the level of user intents).
@MainActor
protocol AccountService: AnyObject {
  /// Which account actions this service can carry out; screens hide the rest. A
  /// conformer that doesn't declare it gets `.all` (see the extension below).
  var capabilities: AccountCapabilities { get }

  // MARK: Signup (C1, C1-P)

  /// `signup/begin`: the invite, the address and the name.
  func beginSignup(code: InviteCode, linkKey: String?, email: String, displayName: String)
    async throws(AuthFailure) -> SignupTicket
  /// `signup/verify`. Wrong codes throw `.codeWrong(triesLeft:)` / `.codeExpired`.
  func verifySignupEmail(_ ticket: SignupTicket, code: String) async throws(AuthFailure)
  /// A new code: `signup/begin` again with the same invite, address and name. Returns the
  /// new ceremony (its id replaces the old one).
  func resendSignupCode(_ ticket: SignupTicket) async throws(AuthFailure) -> SignupTicket
  /// C1 steps 5-9: create the passkey (one Face ID prompt). A session exists afterwards.
  func registerPasskey(_ ticket: SignupTicket) async throws(AuthFailure)
  /// A fresh 12-word phrase made on this iPhone (01 §4.3).
  func makeRecoveryPhrase() throws(AuthFailure) -> RecoveryPhrase
  /// After the phrase is confirmed: publish the keys (C1 steps 10-16, or C1-P's one
  /// `password/register`). Nothing is published before this call.
  func finishAccount(_ ticket: SignupTicket, credential: NewCredential, phrase: RecoveryPhrase)
    async throws(AuthFailure) -> AccountProfile

  // MARK: Sign in (C2, C2-P, C3)

  func signInWithPasskey() async throws(AuthFailure) -> SignInOutcome
  func signInWithPassword(email: String, password: String) async throws(AuthFailure) -> SignInOutcome
  /// C2's passkey login with PRF (replaces a password session).
  func unlockWithPasskey() async throws(AuthFailure)
  /// C3: the 12 words open the recovery wrap and enrol this iPhone.
  func unlockWithPhrase(_ words: [String]) async throws(AuthFailure)

  // MARK: Relaunch with a session (§6.5)

  /// A session survives on this iPhone but its keys don't (killed before unlock, or C1
  /// killed before its bootstrap): what's left, from the server.
  func resumeSignedIn() async throws(AuthFailure) -> SignInOutcome
  /// C1 interrupted: publish a NEW phrase made by `makeRecoveryPhrase()` and confirmed
  /// by the user (step-up `keys.bootstrap`).
  func finishInterruptedSetup(phrase: RecoveryPhrase) async throws(AuthFailure) -> AccountProfile

  // MARK: Forgot password on a new iPhone (C9 side N)

  func beginPasswordReset(email: String) async throws(AuthFailure) -> ResetTicket
  func verifyPasswordReset(_ ticket: ResetTicket, code: String) async throws(AuthFailure) -> ResetTicket
  /// `password/reset/request` with the new password already stretched; returns the ticket
  /// carrying the reset code to show.
  func requestResetApproval(_ ticket: ResetTicket, newPassword: String) async throws(AuthFailure) -> ResetTicket
  /// One poll of `password/reset/finish`: true once the other iPhone approved.
  func pollResetApproval(_ ticket: ResetTicket) async throws(AuthFailure) -> Bool

  // MARK: Access recovery (C4)

  func beginRecovery(words: [String]) async throws(AuthFailure) -> RecoveryTicket
  /// `recover/verify {code, kind}`: the code and the new way to sign in go together
  /// (`02` #48 answers `options` for a passkey or `salt` for a password).
  func verifyRecovery(_ ticket: RecoveryTicket, code: String, kind: SignInMethod) async throws(AuthFailure)
  func finishRecovery(_ ticket: RecoveryTicket, credential: NewCredential) async throws(AuthFailure)

  // MARK: Signed in

  var profile: AccountProfile? { get }
  func securityState() async throws(AuthFailure) -> SecurityState
  /// Runs `action` behind its step-up. `password` is the `device` proof's password for a
  /// password-only account; nil for a passkey account.
  func perform(_ action: SecurityAction, password: String?) async throws(AuthFailure)
  /// `phrase.view` (passkey accounts only, spec 04 §6.2).
  func viewRecoveryPhrase() async throws(AuthFailure) -> [String]
  /// Sign out of this iPhone; local data stays (S-26).
  func signOut() async

  // MARK: The approving iPhone (C9 side A)

  /// `GET password/reset/pending`: a request waiting for this iPhone, if any.
  func pendingResetRequest() async -> PendingReset?
  /// Compares the typed or scanned code with the request's `ek_pub` in constant time and
  /// throws `.codeMismatch` before any Face ID prompt; then the approval key signs and
  /// `password/reset/approve` is sent.
  func approveReset(_ request: PendingReset, code: String) async throws(AuthFailure)
}

extension AccountService {
  /// Everything, so the Debug mocks and test doubles offer every screen unchanged. A
  /// live service overrides this with only the actions it has wired.
  var capabilities: AccountCapabilities { .all }
}
