import CorePrimitives
import CoreStore
import Foundation

nonisolated struct TextKeySecret: Sendable {
  static let length = 32

  let store: any SecretStore
  let random: any RandomSource

  init(store: any SecretStore, random: any RandomSource = SystemRandom()) {
    self.store = store
    self.random = random
  }

  func current() throws(SecretStoreError) -> Data {
    if let held = try store.read(.textKeySecret), held.count == Self.length { return held }
    guard let made = try? random.bytes(Self.length), made.count == Self.length else { throw .failed(status: -1) }
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
