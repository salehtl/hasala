import CorePrimitives
import CoreStore
import Foundation
import Security

nonisolated struct TextKeySecret: Sendable {
  static let length = 32

  let store: any SecretStore
  var random: @Sendable (Int) -> Data? = TextKeySecret.systemRandom

  init(store: any SecretStore, random: @escaping @Sendable (Int) -> Data? = TextKeySecret.systemRandom) {
    self.store = store
    self.random = random
  }

  static func systemRandom(_ n: Int) -> Data? {
    var bytes = Data(count: n)
    let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, n, $0.baseAddress!) }
    return status == errSecSuccess ? bytes : nil
  }

  func current() throws(SecretStoreError) -> Data {
    if let held = try store.read(.textKeySecret), held.count == Self.length { return held }
    guard let made = random(Self.length), made.count == Self.length else { throw .failed(status: -1) }
    try store.write(.textKeySecret, made)
    return made
  }

  func held() throws(SecretStoreError) -> Bool {
    try store.read(.textKeySecret) != nil
  }

  func beforeFirstUnlock() -> Bool {
    do {
      _ = try store.read(.textKeySecret)
      return false
    } catch .notNow {
      return true
    } catch {
      return false
    }
  }

  func forget() {
    try? store.delete(.textKeySecret)
  }
}

enum BankTextsDeviceData {
  static func forgetFiles(facts: BankTextsFacts = .shared, marker: LockedTextsMarkerFile = .shared) {
    facts.forget()
    marker.remove()
  }

  static func forget(
    secrets: any SecretStore, facts: BankTextsFacts = .shared, marker: LockedTextsMarkerFile = .shared
  ) {
    forgetFiles(facts: facts, marker: marker)
    TextKeySecret(store: secrets).forget()
  }
}
