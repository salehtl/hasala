import Foundation

/// The failure taxonomy (spec 04 §6.1.5), one copy block each. Every case is content-free:
/// it names what went wrong, never which part of a credential.
enum AuthFailure: Error, Equatable, Sendable {
  /// The user closed a system sheet: not an error, the screen stays.
  case cancelled
  /// Passkey creation unavailable (no passcode, iCloud Keychain off).
  case unsupported
  case noCredential
  case notInvited
  case badName
  case badEmail
  /// `403 passkey_rejected` on a device with no local account: the beta was reset.
  case orphanedPasskey
  case wrongCredentials
  /// `recovery_refused` / `reset_refused`: start the ceremony again.
  case refused
  case emailInUse
  case codeWrong(triesLeft: Int)
  case codeExpired
  case rateLimited
  case lastAuthenticator
  case frozen
  /// The operator froze the account (`frozen_by`, spec 04 §6.11): only they unfreeze it.
  case frozenByOperator
  /// The server ended this session (`401`; an operator freeze revokes every session):
  /// this iPhone is signed out, and signs in again.
  case sessionEnded
  case stepUpFailed
  /// "View your 12 words" with a passkey that gave no PRF output, so it can't open them.
  case passkeyCantShowPhrase
  case noDeviceKey
  case offline
  /// The local RK check failed: real words, another account (S-15).
  case phraseMismatch
  /// `recover/begin` answered 404 (S-44).
  case noAccountForPhrase
  /// The phrase did not validate locally (S-16), with its message.
  case badPhrase(String)
  /// The signup ceremony's 30 minutes ran out: start again with the same invite.
  case signupExpired
  /// No answer from the approving iPhone before the request expired.
  case approvalExpired
  /// The device can't run Hasala: no passcode (S-24).
  case noPasscode
  /// The reset code doesn't match the pending request: nothing was approved.
  case codeMismatch
  /// A ceremony this build cannot run yet (the live service binds it later).
  case notInThisBuild
  /// The server's keys or address differ from this iPhone's after setup (E-04), or a
  /// server value failed the client's own check: stop, never retry blind.
  case integrity

  /// The copy shown for this failure; nil when nothing is shown.
  var message: String? {
    switch self {
    case .cancelled: nil
    case .unsupported:
      "This iPhone can't make a passkey right now. Check that it has a passcode and iCloud Keychain is on, or use a password instead."
    case .noCredential: "No Hasala passkey on this iPhone."
    case .notInvited: "We couldn't find that invite. Check the code, or ask for a new one."
    case .badName: "Use 1 to 64 letters. Spaces, hyphens, apostrophes and periods are fine."
    case .badEmail: "Hasala can't use this address yet. Try another one."
    case .orphanedPasskey:
      "Hasala couldn't find an account for this passkey. If the beta was reset, join again with your invite. Then delete the older Hasala passkey in the Passwords app, so iPhone stops offering it."
    case .wrongCredentials: "That email and password don't match."
    case .refused: "That didn't go through. Start again."
    case .emailInUse: "This address already has a Hasala account. Sign in instead."
    case .codeWrong(let n): "That code didn't work. \(n) \(n == 1 ? "try" : "tries") left."
    case .codeExpired: "That code has expired. Send a new one."
    case .rateLimited: "Too many tries. Try again in 15 minutes."
    case .lastAuthenticator: "This is your only way to sign in. Add a passkey or a password first."
    case .frozen: "Your account is frozen. Confirm it's you to unfreeze it."
    case .frozenByOperator: "We froze your account to protect it. Talk to us to unfreeze it."
    case .sessionEnded: "You're signed out. Sign in again."
    case .stepUpFailed: "That didn't confirm. Try again."
    case .passkeyCantShowPhrase: "This passkey can't show your 12 words. Use the copy you wrote down."
    case .noDeviceKey:
      "This iPhone can't confirm yet. Changes need your password plus the key of an iPhone where your data is open."
    case .offline: "Try again in a moment."
    case .phraseMismatch: "These words are a valid recovery phrase, but not for this Hasala account."
    case .noAccountForPhrase:
      "These words don't open an active Hasala account. If your account may be frozen, unfreeze it from a signed-in iPhone, or contact us."
    case .badPhrase(let text): text
    case .signupExpired: "That took a while, so we started again. Your invite still works."
    case .approvalExpired: "No answer from your other iPhone. Try again, or use your 12 words."
    case .codeMismatch: "That code doesn't match a request. Nothing was approved."
    case .notInThisBuild: "This isn't in this beta build yet. If you need it now, talk to us at hasala.app/support."
    case .integrity:
      "Something didn't match what this iPhone expected, so Hasala stopped to keep your data safe. Nothing was changed. Talk to us at hasala.app/support."
    case .noPasscode:
      "Set a passcode on your iPhone to use Hasala. It protects your data and lets this iPhone confirm it's you."
    }
  }
}
