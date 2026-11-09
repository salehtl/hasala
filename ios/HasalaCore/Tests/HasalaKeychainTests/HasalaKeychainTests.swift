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

  @Test("accounts lists one service's items in the store's group; none is empty; locked throws")
  func accounts() throws {
    let api = InMemoryKeychainAPI()
    let k = KeychainSecretStore(accessGroup: "G1", api: api)
    let elsewhere = KeychainSecretStore(accessGroup: "G2", api: api)
    #expect(try k.accounts(service: "app.hasala.writer-key").isEmpty)
    try k.write(.writerKey(userID: user, writerID: writer), Data(count: 33))
    try k.write(.approvalKey(userID: user, writerID: writer), Data(count: 8))
    try elsewhere.write(.writerKey(userID: user, writerID: writer), Data(count: 33))
    #expect(try k.accounts(service: "app.hasala.writer-key") == ["\(user.string):\(writer.string)"])
    api.locked = true
    #expect(throws: SecretStoreError.self) { _ = try k.accounts(service: "app.hasala.writer-key") }
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

  let host = "api.example.test"

  func stranded(_ k: KeychainSecretStore, pending: Bool = false) throws -> Secrets {
    let secrets = Secrets(store: k, apiHost: host)
    try secrets.writeSession(
      SessionRecord(token: "old-token", userID: "user-1", expiresAt: 4_000_000_000, tag: "0011223344556677", pendingLogout: pending))
    try k.write(.accountBinding, Data("b".utf8))
    return secrets
  }

  func run(_ k: KeychainSecretStore, _ d: UserDefaults) -> InstallCheck.Outcome {
    InstallCheck.run(protectedDataAvailable: true, defaults: d, keychain: k, groups: [nil], widgetsDirectory: nil, apiHost: host)
  }

  @Test("a session the Keychain answers not-now for stops the install before anything is deleted")
  func strandedNotNow() throws {
    let api = ScriptedKeychain()
    let k = KeychainSecretStore(accessGroup: nil, api: api)
    let secrets = try stranded(k)
    let d = defaults()
    api.sessionReadFailure = errSecInteractionNotAllowed
    #expect(run(k, d) == .notNow(statuses: [errSecInteractionNotAllowed]))
    #expect(d.string(forKey: InstallCheck.installIDKey) == nil)
    #expect(api.deletes.isEmpty)
    api.sessionReadFailure = nil
    #expect(run(k, d) == .done)
    #expect(try secrets.session()?.token == "old-token" && secrets.session()?.pending_logout == true)
    #expect(try k.read(.accountBinding) == nil)
  }

  @Test("a stranded session that cannot be marked stays, and the next launch marks it")
  func strandedMarkRefused() throws {
    let api = ScriptedKeychain()
    let k = KeychainSecretStore(accessGroup: nil, api: api)
    let secrets = try stranded(k)
    let d = defaults()
    api.sessionWriteFailure = errSecNotAvailable
    #expect(run(k, d) == .notNow(statuses: [errSecNotAvailable]))
    #expect(d.string(forKey: InstallCheck.installIDKey) == nil)
    #expect(api.deletes.isEmpty)
    #expect(try secrets.session()?.token == "old-token")
    api.sessionWriteFailure = nil
    #expect(run(k, d) == .done)
    #expect(try secrets.session()?.pending_logout == true)
  }

  @Test("a mark that was applied but not read back is finished by the next launch")
  func strandedMarkNotConfirmed() throws {
    let api = ScriptedKeychain()
    let k = KeychainSecretStore(accessGroup: nil, api: api)
    let secrets = try stranded(k)
    let d = defaults()
    api.failReadAfterWrite = errSecNotAvailable
    guard case .notNow = run(k, d) else {
      Issue.record("an unconfirmed mark must not commit the install")
      return
    }
    #expect(d.string(forKey: InstallCheck.installIDKey) == nil)
    #expect(try secrets.session()?.token == "old-token")
    api.failReadAfterWrite = nil
    #expect(run(k, d) == .done)
    #expect(try secrets.session()?.token == "old-token" && secrets.session()?.pending_logout == true)
  }

  @Test("the purge never deletes the marked session, so a kill mid-purge cannot lose it")
  func strandedNeverDeleted() throws {
    let api = ScriptedKeychain()
    let k = KeychainSecretStore(accessGroup: nil, api: api)
    let secrets = try stranded(k)
    let d = defaults()
    api.deleteFailure = errSecNotAvailable
    guard case .notNow = run(k, d) else {
      Issue.record("a failed delete must not commit the install")
      return
    }
    #expect(try secrets.session()?.pending_logout == true)
    api.deleteFailure = nil
    #expect(run(k, d) == .done)
    #expect(api.sessionDeletes(of: host).isEmpty)
    #expect(try secrets.session()?.token == "old-token" && secrets.session()?.pending_logout == true)
  }

  @Test("a session of another API host still goes when this host's is kept")
  func strandedOtherHost() throws {
    let api = ScriptedKeychain()
    let k = KeychainSecretStore(accessGroup: nil, api: api)
    let secrets = try stranded(k)
    let other = Secrets(store: k, apiHost: "old.example.test")
    try other.writeSession(SessionRecord(token: "other", userID: "user-2", expiresAt: 4_000_000_000, tag: "8899aabbccddeeff"))
    #expect(run(k, defaults()) == .done)
    #expect(try other.session() == nil)
    #expect(try secrets.session()?.token == "old-token")
    #expect(api.inner.count == 1)
  }

  @Test("sessions that cannot be listed leave the install for the next launch")
  func strandedListingRefused() throws {
    let api = ScriptedKeychain()
    let k = KeychainSecretStore(accessGroup: nil, api: api)
    _ = try stranded(k)
    let d = defaults()
    api.accountsFailure = errSecNotAvailable
    #expect(run(k, d) == .notNow(statuses: [errSecNotAvailable]))
    #expect(d.string(forKey: InstallCheck.installIDKey) == nil)
  }

  @Test("a session the Keychain refuses outright cannot hold the install back")
  func strandedRefused() throws {
    let api = ScriptedKeychain()
    let k = KeychainSecretStore(accessGroup: nil, api: api)
    _ = try stranded(k)
    let d = defaults()
    api.sessionReadFailure = errSecDecode
    #expect(run(k, d) == .done)
    #expect(api.inner.count == 0)
    #expect(d.string(forKey: InstallCheck.installIDKey)?.count == 36)
  }

  @Test("a session item that is not a session cannot hold the install back")
  func strandedUndecodable() throws {
    let api = ScriptedKeychain()
    let k = KeychainSecretStore(accessGroup: nil, api: api)
    try k.write(.session(apiHost: host), Data("not json".utf8))
    let d = defaults()
    #expect(run(k, d) == .done)
    #expect(api.inner.count == 0)
    #expect(d.string(forKey: InstallCheck.installIDKey)?.count == 36)
  }

  @Test("a session already marked is kept without another write")
  func strandedAlreadyMarked() throws {
    let api = ScriptedKeychain()
    let k = KeychainSecretStore(accessGroup: nil, api: api)
    let secrets = try stranded(k, pending: true)
    api.sessionWriteFailure = errSecNotAvailable
    #expect(run(k, defaults()) == .done)
    #expect(try secrets.session()?.token == "old-token" && secrets.session()?.pending_logout == true)
  }

  struct NoRandom: RandomSource {
    func fill(_ buffer: UnsafeMutableRawBufferPointer) throws(PrimitivesError) { throw .randomUnavailable(status: -1) }
  }

  @Test("no random source: nothing is deleted, no install id is set, and the next launch finishes")
  func noRandom() throws {
    let api = ScriptedKeychain()
    let k = KeychainSecretStore(accessGroup: nil, api: api)
    try k.write(.accountBinding, Data("b".utf8))
    let d = defaults()
    #expect(InstallCheck.run(
      protectedDataAvailable: true, defaults: d, keychain: k, groups: [nil], widgetsDirectory: nil, random: NoRandom())
      == .notNow(statuses: [-1]))
    #expect(d.string(forKey: InstallCheck.installIDKey) == nil)
    #expect(api.deletes.isEmpty && api.inner.count == 1)
    #expect(InstallCheck.run(protectedDataAvailable: true, defaults: d, keychain: k, groups: [nil], widgetsDirectory: nil) == .done)
    let id = try #require(d.string(forKey: InstallCheck.installIDKey))
    #expect(id.count == 36 && id != "00000000-0000-4000-8000-000000000000")
    #expect(api.inner.count == 0)
  }

  func widgets() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("hasala-install-\(UUID().uuidString)", isDirectory: true)
    let dir = root.appendingPathComponent("Widgets", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: dir.appendingPathComponent("widget-snapshot.json"))
    return dir
  }

  @Test("the first launch removes the widget snapshot; a later launch leaves a new one alone")
  func widgetSnapshot() throws {
    let k = KeychainSecretStore(accessGroup: nil, api: InMemoryKeychainAPI())
    let d = defaults()
    let dir = try widgets()
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    #expect(InstallCheck.run(protectedDataAvailable: true, defaults: d, keychain: k, groups: [nil], widgetsDirectory: dir) == .done)
    #expect(!FileManager.default.fileExists(atPath: dir.path))
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    #expect(InstallCheck.run(protectedDataAvailable: true, defaults: d, keychain: k, groups: [nil], widgetsDirectory: dir) == .done)
    #expect(FileManager.default.fileExists(atPath: dir.path))
  }

  @Test("no widget snapshot to remove is a clean first launch")
  func noWidgetSnapshot() throws {
    let k = KeychainSecretStore(accessGroup: nil, api: InMemoryKeychainAPI())
    let d = defaults()
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hasala-install-\(UUID().uuidString)", isDirectory: true)
    #expect(InstallCheck.run(protectedDataAvailable: true, defaults: d, keychain: k, groups: [nil], widgetsDirectory: dir) == .done)
    #expect(d.string(forKey: InstallCheck.installIDKey)?.count == 36)
  }

  @Test("a failed Keychain delete leaves the widget snapshot and installID for the next launch")
  func widgetSnapshotWaitsForThePurge() throws {
    let api = InMemoryKeychainAPI()
    let k = KeychainSecretStore(accessGroup: nil, api: api)
    api.locked = true
    let d = defaults()
    let dir = try widgets()
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    guard case .notNow = InstallCheck.run(protectedDataAvailable: true, defaults: d, keychain: k, groups: [nil], widgetsDirectory: dir)
    else { Issue.record("expected notNow"); return }
    #expect(FileManager.default.fileExists(atPath: dir.path) && d.string(forKey: InstallCheck.installIDKey) == nil)
  }

  @Test("a widget snapshot that cannot be removed never stops the boot, and the Keychain purge stands")
  func widgetSnapshotStuck() throws {
    let api = InMemoryKeychainAPI()
    let k = KeychainSecretStore(accessGroup: nil, api: api)
    try k.write(.accountBinding, Data("b".utf8))
    let d = defaults()
    let dir = try widgets()
    let parent = dir.deletingLastPathComponent()
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path)
      try? FileManager.default.removeItem(at: parent)
    }
    #expect(InstallCheck.run(protectedDataAvailable: true, defaults: d, keychain: k, groups: [nil], widgetsDirectory: dir) == .done)
    #expect(FileManager.default.fileExists(atPath: dir.path))
    #expect(api.count == 0 && d.string(forKey: InstallCheck.installIDKey)?.count == 36)
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

final class ScriptedKeychain: KeychainAPI, @unchecked Sendable {
  let inner = InMemoryKeychainAPI()
  var sessionReadFailure: OSStatus?
  var sessionWriteFailure: OSStatus?
  var failReadAfterWrite: OSStatus?
  var accountsFailure: OSStatus?
  var deleteFailure: OSStatus?
  private var failNextRead = false
  private(set) var deletes: [[String: Any]] = []

  private func isSession(_ q: [String: Any]) -> Bool { q[kSecAttrService as String] as? String == "app.hasala.session" }

  func sessionDeletes(of host: String) -> [[String: Any]] {
    deletes.filter { q in
      guard isSession(q) else { return false }
      guard let account = q[kSecAttrAccount as String] as? String else { return true }
      return account == host
    }
  }

  private func wrote(_ q: [String: Any], _ s: OSStatus) -> OSStatus {
    if s == errSecSuccess, isSession(q), failReadAfterWrite != nil { failNextRead = true }
    return s
  }

  func add(_ q: [String: Any]) -> OSStatus {
    if isSession(q), let f = sessionWriteFailure { return f }
    return wrote(q, inner.add(q))
  }

  func update(_ q: [String: Any], _ a: [String: Any]) -> OSStatus {
    if isSession(q), let f = sessionWriteFailure { return f }
    return wrote(q, inner.update(q, a))
  }

  func copyData(_ q: [String: Any]) -> (OSStatus, Data?) {
    if isSession(q), failNextRead, let f = failReadAfterWrite {
      failNextRead = false
      return (f, nil)
    }
    if isSession(q), let f = sessionReadFailure { return (f, nil) }
    return inner.copyData(q)
  }

  func accounts(_ q: [String: Any]) -> (OSStatus, [String]) {
    if let f = accountsFailure { return (f, []) }
    return inner.accounts(q)
  }

  func delete(_ q: [String: Any]) -> OSStatus {
    if let f = deleteFailure { return f }
    deletes.append(q)
    return inner.delete(q)
  }
}
