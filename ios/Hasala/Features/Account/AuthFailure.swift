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
  case passkeyCantShowUnseenPhrase
  case wordsBeforeRemovingPasskey
  case wordsInSignup
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
  case signupExpiredPhrase
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
  case updateRequired

  /// The copy shown for this failure; nil when nothing is shown. Two short sentences: what
  /// happened, then what to do (spec 01 §7.4; the codes and sign-in copy verbatim from spec
  /// 07 S4, S7 and spec 08 FWD).
  var message: String? {
    switch self {
    case .cancelled: nil
    case .unsupported:
      "Couldn't make a passkey. Turn on a passcode and iCloud Keychain, or use a password."
    case .noCredential: "No Hasala passkey on this iPhone."
    case .notInvited: "We couldn't find that invite. Check each character against your email."
    case .badName: "Use 1 to 64 letters. Spaces, hyphens, apostrophes and periods are fine."
    case .badEmail: "Can't use this address yet. Try another."
    case .orphanedPasskey:
      "No account matches this passkey. If the beta was reset, join again with your invite, then delete the old passkey in the Passwords app."
    case .wrongCredentials: "Wrong email or password. Try again or reset your password."
    case .refused: "That didn't go through. Start again."
    case .emailInUse: "This address already has an account. Sign in instead."
    case .codeWrong(let n):
      "Wrong code. Check our newest email or get a new one. \(n) \(n == 1 ? "try" : "tries") left."
    case .codeExpired: "That code expired. Codes last 10 minutes; get a new one."
    case .rateLimited: "Too many tries. Try again in 15 minutes."
    case .lastAuthenticator: "It's your only way to sign in. Add a passkey or password first."
    case .frozen: "Your account is frozen. Confirm it's you to unfreeze it."
    case .frozenByOperator: "We froze your account to protect it. Talk to us to unfreeze it."
    case .sessionEnded: "You're signed out. Sign in again."
    case .stepUpFailed: "That didn't confirm. Try again."
    case .passkeyCantShowPhrase: "This passkey can't show your 12 words. Use your written copy."
    case .passkeyCantShowUnseenPhrase:
      "This passkey can't show your 12 words. Stay signed in here, where your data opens, and talk to us at hasala.app/support."
    case .wordsBeforeRemovingPasskey:
      "Write down your 12 words first. Until then, only this passkey can show them."
    case .wordsInSignup: "Write down your 12 words to finish."
    case .noDeviceKey:
      "This iPhone can't confirm yet. Use one where your data is open."
    case .offline: "Try again in a moment."
    case .phraseMismatch: "These words are for another account."
    case .noAccountForPhrase:
      "No active account matches these words. Frozen? Unfreeze it on a signed-in iPhone, or contact us."
    case .badPhrase(let text): text
    case .signupExpired: "Time ran out, so we started again. Your invite still works."
    case .signupExpiredPhrase:
      "Time ran out, so we started again with 12 new words. Cross out the old ones."
    case .approvalExpired: "No answer from your other iPhone. Try again, or use your 12 words."
    case .codeMismatch: "That code doesn't match a request. Nothing was approved."
    case .notInThisBuild: "Not in the beta yet. Need it? Talk to us at hasala.app/support."
    case .integrity:
      "Something didn't match, so nothing was changed. Talk to us at hasala.app/support."
    case .updateRequired:
      "This version is too old. Update Hasala in TestFlight, then try again."
    case .noPasscode:
      "Set an iPhone passcode to use Hasala. It protects your data and confirms it's you."
    }
  }
}
