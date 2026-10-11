import CoreMailbox
import Foundation
import Security

/// The Keychain item `.gmailRefresh(user)` (spec 04 §4.4): generic password, service
/// `app.hasala.gmail.refresh`, account `<user_id>`, `AfterFirstUnlockThisDeviceOnly`, data
/// protection keychain, never synchronizable. The access group is the entitlement's first
/// group (`<P>app.hasala.ios`), which is where an item lands when none is named.
///
/// The null-vs-throw contract (§4.4): `read` returns nil only for `errSecItemNotFound` and
/// throws for every other status (e.g. `errSecInteractionNotAllowed` before first unlock), so a
/// locked phone is never mistaken for a disconnected one. Writes add, update on duplicate, and
/// read back; a mismatch throws.
///
/// TODO(WS-11): fold into `KeychainSecretStore` (`SecretItem.gmailRefresh`) once CoreStore's
/// `SecretStore` lands; the item attributes above are the contract either way.
nonisolated final class KeychainGmailRefreshTokenStore: GmailRefreshTokenStore, Sendable {
  static let service = "app.hasala.gmail.refresh"
  let account: String

  /// `userID`: the account's lowercase canonical UUID.
  init(userID: String) {
    account = userID
  }

  private var baseQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.service,
      kSecAttrAccount as String: account,
      kSecUseDataProtectionKeychain as String: true,
      kSecAttrSynchronizable as String: false,
    ]
  }

  func read() throws(SecretUnavailable) -> String? {
    var q = baseQuery
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var out: CFTypeRef?
    let status = SecItemCopyMatching(q as CFDictionary, &out)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = out as? Data, let s = String(data: data, encoding: .utf8) else {
      throw SecretUnavailable()
    }
    return s
  }

  func write(_ token: String) throws(SecretUnavailable) {
    let data = Data(token.utf8)
    var add = baseQuery
    add[kSecValueData as String] = data
    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    var status = SecItemAdd(add as CFDictionary, nil)
    if status == errSecDuplicateItem {
      let attrs: [String: Any] = [
        kSecValueData as String: data,
        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      ]
      status = SecItemUpdate(baseQuery as CFDictionary, attrs as CFDictionary)
    }
    guard status == errSecSuccess else { throw SecretUnavailable() }
    // Read-back compare (the mailboxToken.ts contract).
    guard try read() == token else { throw SecretUnavailable() }
  }

  func delete() throws(SecretUnavailable) {
    let status = SecItemDelete(baseQuery as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretUnavailable() }
  }
}
