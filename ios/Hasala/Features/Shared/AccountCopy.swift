import Foundation

/// Words two entry points say for the same account action, held once so they can't drift
/// apart.
enum AccountCopy {
  /// "Sign out of this iPhone?": Your profile and Sign-in & security both ask it. Paper I1C-0
  /// says the data is erased; signing out keeps this iPhone's data (S-26), so the alert says
  /// what happens instead.
  static let signOutMessage =
    "To come back, sign in with your passkey or your password. Hasala's data stays on this iPhone, locked to your account."
}
