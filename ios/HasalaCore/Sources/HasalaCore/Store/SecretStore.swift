// The secret store seam (spec 04 §2.7, §4.4; spec 01 §11.1).
//
// The app implements it with the data-protection Keychain (`HasalaKeychain`,
// the package adapter target); tests use `MemorySecretStore`. Each case of
// `SecretItem` names exactly one Keychain item, and the mapping below (service,
// account, accessibility) is §4.4's table, so the adapter has nothing to decide.
//
// The null-vs-throw contract (pwa `mailboxToken.ts`): `read` returns `nil` only
// when the item is absent; any other failure (before first unlock,
// `errSecInteractionNotAllowed`) throws, and callers treat a throw as "not
// now", never as "absent".
import CorePrimitives
import Foundation
import Synchronization

public enum SecretItem: Sendable, Hashable {
  case session(apiHost: String)
  case accountBinding
  case epochKey(userID: UserID, epoch: UInt32)
  case writerKey(userID: UserID, writerID: WriterID)
  /// The DAK's Secure-Enclave-wrapped handle (01 §4.9, §11.1).
  case approvalKey(userID: UserID, writerID: WriterID)
  /// A mail provider's OAuth refresh token (spec 04 §7.3).
  case mailRefresh(provider: MailSecretProvider, userID: UserID)
  /// The Outlook link's Graph subscription `clientState` (the `PUT /mailbox/link` answer).
  case outlookClientState(userID: UserID)

  /// The Gmail refresh token: service `app.hasala.gmail.refresh`, unchanged from before the
  /// provider seam, so existing links need no migration.
  public static func gmailRefresh(userID: UserID) -> SecretItem { .mailRefresh(provider: .gmail, userID: userID) }

  /// `kSecAttrService` (§4.4).
  public var service: String {
    switch self {
    case .session: "app.hasala.session"
    case .accountBinding: "app.hasala.account"
    case .epochKey: "app.hasala.epoch-key"
    case .writerKey: "app.hasala.writer-key"
    case .approvalKey: "app.hasala.approval-key"
    case .mailRefresh(.gmail, _): "app.hasala.gmail.refresh"
    case .mailRefresh(.outlook, _): "app.hasala.outlook.refresh"
    case .outlookClientState: "app.hasala.outlook.clientstate"
    }
  }

  /// `kSecAttrAccount` (§4.4).
  public var account: String {
    switch self {
    case .session(let host): host
    case .accountBinding: "binding"
    case .epochKey(let u, let e): "\(u.string):\(e)"
    case .writerKey(let u, let w), .approvalKey(let u, let w): "\(u.string):\(w.string)"
    case .mailRefresh(_, let u), .outlookClientState(let u): u.string
    }
  }

  /// The item's accessibility class (01 §11.1).
  public var accessibility: SecretAccessibility {
    switch self {
    case .approvalKey: .whenPasscodeSetThisDeviceOnly
    default: .afterFirstUnlockThisDeviceOnly
    }
  }

  /// Every service the fresh-install purge deletes (§4.4 `installCheck`).
  public static let allServices = [
    "app.hasala.session", "app.hasala.account", "app.hasala.epoch-key", "app.hasala.writer-key",
    "app.hasala.approval-key", "app.hasala.gmail.refresh", "app.hasala.outlook.refresh",
    "app.hasala.outlook.clientstate",
  ]
}

/// The mail providers that keep Keychain items (CoreMailbox's `MailProviderID`, by raw value).
public enum MailSecretProvider: String, Sendable, Hashable, CaseIterable {
  case gmail
  case outlook
}

/// The two classes the items use. Every item is also non-synchronizable, in the
/// data-protection Keychain, in the app-only access group (01 §11.1).
public enum SecretAccessibility: Sendable, Hashable {
  case afterFirstUnlockThisDeviceOnly
  case whenPasscodeSetThisDeviceOnly
}

public enum SecretStoreError: Error, Sendable, Hashable {
  /// The item exists but cannot be read now (before first unlock): "not now".
  case notNow(status: Int32)
  /// A write's read-back did not return the written bytes (§4.4).
  case readBackMismatch
  /// Any other Keychain status.
  case failed(status: Int32)
}

public protocol SecretStore: Sendable {
  /// `nil` = absent; throws = present but unreadable (e.g. before first unlock).
  func read(_ item: SecretItem) throws(SecretStoreError) -> Data?
  func write(_ item: SecretItem, _ value: Data) throws(SecretStoreError)
  /// Deleting an absent item succeeds.
  func delete(_ item: SecretItem) throws(SecretStoreError)
}

/// An in-memory `SecretStore` for tests and `HASALA_MOCKS` previews. `locked`
/// makes every read and write throw `notNow`, as the Keychain does before first
/// unlock.
public final class MemorySecretStore: SecretStore {
  private struct Key: Hashable {
    let service: String
    let account: String
  }

  private let items = Mutex<[Key: Data]>([:])
  private let lockedState = Mutex(false)

  public init() {}

  public var locked: Bool {
    get { lockedState.withLock { $0 } }
    set { lockedState.withLock { $0 = newValue } }
  }

  public func read(_ item: SecretItem) throws(SecretStoreError) -> Data? {
    if locked { throw .notNow(status: -25308) }
    return items.withLock { $0[Key(service: item.service, account: item.account)] }
  }

  public func write(_ item: SecretItem, _ value: Data) throws(SecretStoreError) {
    if locked { throw .notNow(status: -25308) }
    items.withLock { $0[Key(service: item.service, account: item.account)] = value }
  }

  public func delete(_ item: SecretItem) throws(SecretStoreError) {
    if locked { throw .notNow(status: -25308) }
    _ = items.withLock { $0.removeValue(forKey: Key(service: item.service, account: item.account)) }
  }

  /// How many items are held (tests).
  public var count: Int { items.withLock { $0.count } }

  /// Removes every item (the fresh-install purge, tests).
  public func removeAll() { items.withLock { $0.removeAll() } }
}
