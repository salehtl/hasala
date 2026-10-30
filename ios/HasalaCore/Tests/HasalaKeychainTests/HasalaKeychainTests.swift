// Unit tests for HasalaKeychain (owner: WS-11): §4.4's query attributes, the
// add/update/read-back write, the null-vs-throw read, and the purge.
import CorePrimitives
import CoreStore
import Foundation
import Security
import Testing

@testable import HasalaKeychain

let user = UserID("6f1c2b9e-4d3a-4f5b-8c7d-0e1f2a3b4c5d")!
let writer = WriterID("ios-0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d")!

@Suite("HasalaKeychain")
struct KeychainTests {
  @Test("items are data-protection, non-synchronizable, with §4.4's accessibility")
  func attributes() throws {
    let api = InMemoryKeychainAPI()
    let k = KeychainSecretStore(accessGroup: "TEAM.app.hasala.ios", api: api)
    try k.write(.epochKey(userID: user, epoch: 1), Data(repeating: 1, count: 32))
    try k.write(.approvalKey(userID: user, writerID: writer), Data(repeating: 2, count: 8))
    let e = try #require(api.attributes(service: "app.hasala.epoch-key", account: "\(user.string):1", group: "TEAM.app.hasala.ios"))
    #expect(e["accessible"] == "\(kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)")
    #expect(e["sync"] == "false" && e["dpk"] == "true")
    let a = try #require(
      api.attributes(service: "app.hasala.approval-key", account: "\(user.string):\(writer.string)", group: "TEAM.app.hasala.ios"))
    #expect(a["accessible"] == "\(kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly)")
  }

  @Test("write adds, then updates a duplicate; read-back must match")
  func writes() throws {
    let api = InMemoryKeychainAPI()
    let k = KeychainSecretStore(accessGroup: nil, api: api)
    try k.write(.accountBinding, Data("a".utf8))
    try k.write(.accountBinding, Data("b".utf8))
    #expect(try k.read(.accountBinding) == Data("b".utf8))
    api.corruptReads = true
    #expect(throws: SecretStoreError.readBackMismatch) { try k.write(.accountBinding, Data("c".utf8)) }
  }

  @Test("absent → nil; locked → throws notNow (never nil); delete of an absent item succeeds")
  func reads() throws {
    let api = InMemoryKeychainAPI()
    let k = KeychainSecretStore(accessGroup: nil, api: api)
    #expect(try k.read(.gmailRefresh(userID: user)) == nil)
    try k.write(.gmailRefresh(userID: user), Data("t".utf8))
    api.locked = true
    #expect(throws: SecretStoreError.notNow(status: errSecInteractionNotAllowed)) {
      _ = try k.read(.gmailRefresh(userID: user))
    }
    api.locked = false
    try k.delete(.gmailRefresh(userID: user))
    try k.delete(.gmailRefresh(userID: user))
    #expect(try k.read(.gmailRefresh(userID: user)) == nil)
  }

  @Test("the purge deletes every service in every group and reports completeness")
  func purge() throws {
    let api = InMemoryKeychainAPI()
    let k = KeychainSecretStore(accessGroup: "G1", api: api)
    try k.write(.session(apiHost: "api.hasala.app"), Data("s".utf8))
    try k.write(.writerKey(userID: user, writerID: writer), Data(count: 33))
    try k.write(.textKeySecret, Data(repeating: 5, count: 32))
    #expect(api.attributes(service: "app.hasala.text-key", account: "device", group: "G1")?["accessible"]
      == "\(kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)")
    #expect(api.attributes(service: "app.hasala.text-key", account: "device", group: "G1")?["sync"] == "false")
    try k.write(.readerWordKey, Data(repeating: 6, count: 32))
    #expect(api.attributes(service: "app.hasala.reader-key", account: "device", group: "G1")?["accessible"]
      == "\(kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)")
    #expect(api.attributes(service: "app.hasala.reader-key", account: "device", group: "G1")?["sync"] == "false")
    let r = k.purgeAll(groups: ["G1", "G2"])
    #expect(r.complete && api.count == 0)
    api.locked = true
    #expect(!k.purgeAll(groups: ["G1"]).complete)
  }

  // The system Keychain itself cannot be exercised here: a hostless package
  // test bundle has no keychain-access-groups entitlement, so SecItem answers
  // errSecMissingEntitlement (-34018) even on the simulator. The round trip
  // belongs to the app's hosted unit tests (ios/HasalaTests), TODO(WS-13
  // integration): write, read, update, delete each SecretItem through
  // KeychainSecretStore(accessGroup: "<P>app.hasala.ios").
}

@Suite("InstallCheck (§4.4, R-03)")
struct InstallCheckTests {
  func defaults() -> UserDefaults {
    let name = "hasala-test-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
  }

  @Test("before first unlock: nothing is deleted or written")
  func locked() throws {
    let api = InMemoryKeychainAPI()
    let k = KeychainSecretStore(accessGroup: nil, api: api)
    try k.write(.accountBinding, Data("b".utf8))
    let d = defaults()
    #expect(InstallCheck.run(protectedDataAvailable: false, defaults: d, keychain: k, groups: [nil], widgetsDirectory: nil) == .notNow(statuses: []))
    #expect(api.count == 1 && d.string(forKey: InstallCheck.installIDKey) == nil)
  }

  @Test("first launch purges, then sets installID; a later launch purges nothing")
  func purges() throws {
    let api = InMemoryKeychainAPI()
    let k = KeychainSecretStore(accessGroup: nil, api: api)
    try k.write(.accountBinding, Data("b".utf8))
    let d = defaults()
    #expect(InstallCheck.run(protectedDataAvailable: true, defaults: d, keychain: k, groups: [nil], widgetsDirectory: nil) == .done)
    #expect(api.count == 0 && d.string(forKey: InstallCheck.installIDKey)?.count == 36)
    try k.write(.accountBinding, Data("b".utf8))
    #expect(InstallCheck.run(protectedDataAvailable: true, defaults: d, keychain: k, groups: [nil], widgetsDirectory: nil) == .done)
    #expect(api.count == 1)
  }

  @Test("a session left by an earlier install survives the purge only as a pending logout")
  func strandedSession() throws {
    let api = InMemoryKeychainAPI()
    let k = KeychainSecretStore(accessGroup: nil, api: api)
    let secrets = Secrets(store: k, apiHost: "api.example.test")
    try secrets.writeSession(SessionRecord(token: "old-token", userID: "user-1", expiresAt: 4_000_000_000, tag: "0011223344556677"))
    try k.write(.accountBinding, Data("b".utf8))
    let d = defaults()
    #expect(InstallCheck.run(
      protectedDataAvailable: true, defaults: d, keychain: k, groups: [nil], widgetsDirectory: nil,
      apiHost: "api.example.test") == .done)
    let kept = try secrets.session()
    #expect(kept?.token == "old-token" && kept?.pending_logout == true)
    #expect(try k.read(.accountBinding) == nil)
  }

  @Test("a failed delete leaves installID unset, so the next launch retries")
  func retries() throws {
    let api = InMemoryKeychainAPI()
    let k = KeychainSecretStore(accessGroup: nil, api: api)
    api.locked = true
    let d = defaults()
    guard case .notNow(let s) = InstallCheck.run(
      protectedDataAvailable: true, defaults: d, keychain: k, groups: [nil], widgetsDirectory: nil)
    else { Issue.record("expected notNow"); return }
    #expect(!s.isEmpty && d.string(forKey: InstallCheck.installIDKey) == nil)
  }
}
