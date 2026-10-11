// `SecretStore` over the data-protection Keychain (spec 04 §4.4; spec 01
// §11.1, §11.3).
//
// Every item: `kSecClassGenericPassword`, `kSecUseDataProtectionKeychain`,
// not synchronizable, the app-only access group, and the accessibility class
// `SecretItem` names. Writes are `SecItemAdd`, then `SecItemUpdate` on
// `errSecDuplicateItem`, then a read-back compare (a mismatch throws). Reads
// return `nil` only for `errSecItemNotFound` and THROW for every other status
// (`errSecInteractionNotAllowed` before first unlock is "not now").
//
// The SecItem calls go through `KeychainAPI`, so the query logic is tested
// with an in-memory double under `swift test` (a macOS test runner has no
// data-protection Keychain entitlement); the system one is `SystemKeychain`.
import CoreStore
import Foundation
import Security

/// The four SecItem calls, as the adapter uses them.
public protocol KeychainAPI: Sendable {
  func add(_ query: [String: Any]) -> OSStatus
  func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus
  func copyData(_ query: [String: Any]) -> (OSStatus, Data?)
  func delete(_ query: [String: Any]) -> OSStatus
}

public struct SystemKeychain: KeychainAPI {
  public init() {}
  public func add(_ q: [String: Any]) -> OSStatus { SecItemAdd(q as CFDictionary, nil) }
  public func update(_ q: [String: Any], _ a: [String: Any]) -> OSStatus {
    SecItemUpdate(q as CFDictionary, a as CFDictionary)
  }
  public func copyData(_ q: [String: Any]) -> (OSStatus, Data?) {
    var out: CFTypeRef?
    let s = SecItemCopyMatching(q as CFDictionary, &out)
    return (s, out as? Data)
  }
  public func delete(_ q: [String: Any]) -> OSStatus { SecItemDelete(q as CFDictionary) }
}

public final class KeychainSecretStore: SecretStore {
  /// `$(AppIdentifierPrefix)app.hasala.ios`; `nil` uses the app's default group
  /// (the first of its `keychain-access-groups`, which is the same one).
  public let accessGroup: String?
  let api: any KeychainAPI

  public init(accessGroup: String?, api: any KeychainAPI = SystemKeychain()) {
    self.accessGroup = accessGroup
    self.api = api
  }

  func base(service: String, account: String?) -> [String: Any] {
    var q: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecUseDataProtectionKeychain as String: true,
      kSecAttrSynchronizable as String: false,
    ]
    if let account { q[kSecAttrAccount as String] = account }
    if let accessGroup { q[kSecAttrAccessGroup as String] = accessGroup }
    return q
  }

  func query(_ item: SecretItem) -> [String: Any] { base(service: item.service, account: item.account) }

  static func accessible(_ a: SecretAccessibility) -> CFString {
    switch a {
    case .afterFirstUnlockThisDeviceOnly: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    case .whenPasscodeSetThisDeviceOnly: kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
    }
  }

  static func failure(_ s: OSStatus) -> SecretStoreError {
    s == errSecInteractionNotAllowed ? .notNow(status: s) : .failed(status: s)
  }

  public func read(_ item: SecretItem) throws(SecretStoreError) -> Data? {
    var q = query(item)
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    let (s, data) = api.copyData(q)
    switch s {
    case errSecSuccess:
      guard let data else { throw .failed(status: s) }
      return data
    case errSecItemNotFound: return nil
    default: throw Self.failure(s)
    }
  }

  public func write(_ item: SecretItem, _ value: Data) throws(SecretStoreError) {
    var add = query(item)
    add[kSecValueData as String] = value
    add[kSecAttrAccessible as String] = Self.accessible(item.accessibility)
    var s = api.add(add)
    if s == errSecDuplicateItem {
      s = api.update(
        query(item),
        [kSecValueData as String: value, kSecAttrAccessible as String: Self.accessible(item.accessibility)])
    }
    guard s == errSecSuccess else { throw Self.failure(s) }
    guard let back = try read(item), back == value else { throw .readBackMismatch }
  }

  public func delete(_ item: SecretItem) throws(SecretStoreError) {
    let s = api.delete(query(item))
    guard s == errSecSuccess || s == errSecItemNotFound else { throw Self.failure(s) }
  }

  /// The fresh-install purge's deletes (§4.4 `installCheck`): every item of
  /// every app service in each of `groups`. Returns whether every delete
  /// answered success or not-found; the caller sets `installID` only then.
  public func purgeAll(groups: [String?]) -> (complete: Bool, statuses: [OSStatus]) {
    var statuses: [OSStatus] = []
    for service in SecretItem.allServices {
      for g in groups {
        var q: [String: Any] = [
          kSecClass as String: kSecClassGenericPassword,
          kSecAttrService as String: service,
          kSecUseDataProtectionKeychain as String: true,
        ]
        if let g { q[kSecAttrAccessGroup as String] = g }
        let s = api.delete(q)
        if s != errSecSuccess && s != errSecItemNotFound { statuses.append(s) }
      }
    }
    return (statuses.isEmpty, statuses)
  }
}

/// An in-memory `KeychainAPI` with the SecItem semantics the adapter relies on
/// (duplicate on add, not-found on update, copy, delete), and a lock switch
/// that answers `errSecInteractionNotAllowed`. Tests only.
public final class InMemoryKeychainAPI: KeychainAPI, @unchecked Sendable {
  private let lock = NSLock()
  private var items: [String: (data: Data, attrs: [String: String])] = [:]
  public var locked = false
  /// When set, `copyData` returns these bytes instead (a corrupt read-back).
  public var corruptReads = false

  public init() {}

  static func key(_ q: [String: Any]) -> String {
    let service = q[kSecAttrService as String] as? String ?? ""
    let account = q[kSecAttrAccount as String] as? String ?? ""
    let group = q[kSecAttrAccessGroup as String] as? String ?? ""
    return "\(group)|\(service)|\(account)"
  }

  public func attributes(service: String, account: String, group: String? = nil) -> [String: String]? {
    lock.withLock { items["\(group ?? "")|\(service)|\(account)"]?.attrs }
  }

  public var count: Int { lock.withLock { items.count } }

  public func add(_ q: [String: Any]) -> OSStatus {
    lock.withLock {
      if locked { return errSecInteractionNotAllowed }
      let k = Self.key(q)
      if items[k] != nil { return errSecDuplicateItem }
      guard let d = q[kSecValueData as String] as? Data else { return errSecParam }
      var attrs: [String: String] = [:]
      if let a = q[kSecAttrAccessible as String] { attrs["accessible"] = "\(a)" }
      attrs["sync"] = "\(q[kSecAttrSynchronizable as String] as? Bool ?? true)"
      attrs["dpk"] = "\(q[kSecUseDataProtectionKeychain as String] as? Bool ?? false)"
      items[k] = (d, attrs)
      return errSecSuccess
    }
  }

  public func update(_ q: [String: Any], _ a: [String: Any]) -> OSStatus {
    lock.withLock {
      if locked { return errSecInteractionNotAllowed }
      let k = Self.key(q)
      guard var item = items[k] else { return errSecItemNotFound }
      if let d = a[kSecValueData as String] as? Data { item.data = d }
      if let acc = a[kSecAttrAccessible as String] { item.attrs["accessible"] = "\(acc)" }
      items[k] = item
      return errSecSuccess
    }
  }

  public func copyData(_ q: [String: Any]) -> (OSStatus, Data?) {
    lock.withLock {
      if locked { return (errSecInteractionNotAllowed, nil) }
      guard let item = items[Self.key(q)] else { return (errSecItemNotFound, nil) }
      return (errSecSuccess, corruptReads ? Data([0]) : item.data)
    }
  }

  public func delete(_ q: [String: Any]) -> OSStatus {
    lock.withLock {
      if locked { return errSecInteractionNotAllowed }
      if q[kSecAttrAccount as String] == nil {
        let prefix = "\(q[kSecAttrAccessGroup as String] as? String ?? "")|\(q[kSecAttrService as String] as? String ?? "")|"
        let before = items.count
        items = items.filter { !$0.key.hasPrefix(prefix) }
        return items.count < before ? errSecSuccess : errSecItemNotFound
      }
      return items.removeValue(forKey: Self.key(q)) == nil ? errSecItemNotFound : errSecSuccess
    }
  }
}
