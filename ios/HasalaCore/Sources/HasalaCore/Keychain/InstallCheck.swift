// The fresh-install purge (spec 04 §4.4 `installCheck`; spec 01 §11.3; R-03).
//
// At process start, before anything reads the Keychain, and only while
// protected data is available: if `app.hasala.installID` is unset, delete every
// item of every app service in both access groups; only when every delete
// answered success or not-found, remove the widget snapshot directory and set
// `installID`. Otherwise `installID` stays unset (the next launch retries) and
// boot waits (`.notNow`). Before first unlock UserDefaults may read as empty, so
// a missing `installID` is never trusted then. App process only; extensions
// never purge.
import CorePrimitives
import CoreStore
import Foundation

public enum InstallCheck {
  public static let installIDKey = "app.hasala.installID"

  public enum Outcome: Sendable, Hashable {
    case done
    case notNow(statuses: [Int32])
  }

  public static func run(
    protectedDataAvailable: Bool, defaults: UserDefaults, keychain: KeychainSecretStore, groups: [String?],
    widgetsDirectory: URL?
  ) -> Outcome {
    guard protectedDataAvailable else { return .notNow(statuses: []) }
    if defaults.string(forKey: installIDKey) != nil { return .done }
    let (complete, statuses) = keychain.purgeAll(groups: groups)
    guard complete else { return .notNow(statuses: statuses) }
    if let w = widgetsDirectory { try? FileManager.default.removeItem(at: w) }  // logged and retried, never fatal
    let id = (try? SystemRandom().uuidV4()) ?? "00000000-0000-4000-8000-000000000000"
    defaults.set(id, forKey: installIDKey)
    return .done
  }
}
