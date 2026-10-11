import CoreMailbox
import Foundation
import Security
import Testing

@testable import Hasala

/// The `.gmailRefresh(user)` Keychain item against the simulator's real Keychain (spec 04 §4.4).
@Suite("Gmail refresh token in the Keychain", .serialized)
struct GmailKeychainTests {
  let store = KeychainGmailRefreshTokenStore(userID: "00000000-0000-4000-8000-\(String(UInt64.random(in: 0..<1 << 40), radix: 16).leftPad())")

  @Test func absentReadsAsNil() throws {
    #expect(try store.read() == nil)
  }

  @Test func writeUpdateReadDelete() throws {
    defer { try? store.delete() }
    try store.write("synthetic-refresh-1")
    #expect(try store.read() == "synthetic-refresh-1")
    try store.write("synthetic-refresh-2")  // duplicate -> update
    #expect(try store.read() == "synthetic-refresh-2")
    try store.delete()
    #expect(try store.read() == nil)
    try store.delete()  // deleting an absent item is fine
  }

  @Test func itemIsDeviceOnlyAfterFirstUnlock() throws {
    defer { try? store.delete() }
    try store.write("synthetic-refresh-3")
    let q: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "app.hasala.gmail.refresh",
      kSecAttrAccount as String: store.account,
      kSecUseDataProtectionKeychain as String: true,
      kSecReturnAttributes as String: true,
    ]
    var out: CFTypeRef?
    #expect(SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess)
    let attrs = try #require(out as? [String: Any])
    #expect(attrs[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    #expect((attrs[kSecAttrSynchronizable as String] as? NSNumber)?.boolValue != true)
  }
}

extension String {
  fileprivate func leftPad() -> String { count >= 12 ? self : String(repeating: "0", count: 12 - count) + self }
}
