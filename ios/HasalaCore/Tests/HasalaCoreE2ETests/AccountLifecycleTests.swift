import CoreAuth
import CoreCrypto
import CoreSoftAuth
import CoreSync
import CoreTestSupport
import Foundation
import Synchronization
import Testing

@Suite("Account lifecycle: enrolment, removal and the local wipe")
struct AccountLifecycleTests {
  func temporaryDirectory(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("hasala-\(name)-\(UUID().uuidString)")
  }

  func onDisk(_ w: World, _ p: Phone, _ dir: URL, secrets: (any SecretStore)? = nil) -> AccountEnvironment {
    AccountEnvironment(
      client: p.env.client, secrets: secrets.map { Secrets(store: $0, apiHost: "api.hasala.app") } ?? p.env.secrets,
      approvalKeys: p.dak, passkeys: p.passkeys, clock: w.clock, random: p.env.random, apiBase: p.env.apiBase,
      accountsDirectory: dir)
  }

  func enrol(_ env: AccountEnvironment, _ user: UserID, _ words: [String]) async throws -> EnrolledAccount {
    let r = try await AccountSignIn.withPassword(env, email: "maya@example.com", password: password, bound: nil)
    let body = try await Enrolment.unlockWithPhrase(env, userID: user, typed: words.joined(separator: " "))
    defer { body.wipe() }
    return try await Enrolment.enrolWriter(env, userID: user, body: body, emailNorm: r.emailNorm, serverSalt: r.serverSalt)
  }

  func isOpening(_ env: AccountEnvironment) -> Bool {
    if case .opening = Boot.decide(Boot.gather(env)) { return true }
    return false
  }

  func hasLedger(_ env: AccountEnvironment, _ user: UserID) throws -> Bool {
    FileManager.default.fileExists(atPath: try #require(env.storeDirectory(for: user)).appendingPathComponent("ledger.sqlite").path)
  }

  // MARK: Re-enrolment over an earlier writer's store

  @Test("a store of an earlier writer that cannot be removed stops the enrolment; a retry finishes it")
  func staleStoreThatCannotBeRemoved() async throws {
    let w = World()
    let (account, words, _) = try await w.passwordAccount(w.phone("a"))
    let dir = temporaryDirectory("stale-store")
    defer { try? FileManager.default.removeItem(at: dir) }
    let env = onDisk(w, w.phone("b"), dir)
    let first = try await enrol(env, account.userID, words)
    let storeDir = try #require(env.storeDirectory(for: account.userID))

    let r = try await AccountSignIn.withPassword(env, email: "maya@example.com", password: password, bound: nil)
    let body = try await Enrolment.unlockWithPhrase(env, userID: account.userID, typed: words.joined(separator: " "))
    defer { body.wipe() }
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: storeDir.path)
    var restored = false
    defer { if !restored { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: storeDir.path) } }

    do {
      _ = try await Enrolment.enrolWriter(
        env, userID: account.userID, body: body, emailNorm: r.emailNorm, serverSalt: r.serverSalt)
      Issue.record("enrolled over a store that still belongs to the earlier writer")
    } catch {
      guard case .store = error else {
        Issue.record("\(error)")
        return
      }
    }
    #expect(try env.secrets.binding()?.writerID == first.writerID)
    #expect(try first.store.meta()?.writerID == first.writerID)

    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: storeDir.path)
    restored = true
    let again = try await Enrolment.enrolWriter(
      env, userID: account.userID, body: body, emailNorm: r.emailNorm, serverSalt: r.serverSalt)
    #expect(again.writerID != first.writerID)
    #expect(try again.store.meta()?.writerID == again.writerID)
    #expect(try env.secrets.binding()?.writerID == again.writerID)
    #expect(try again.store.syncState().authoredHead == .genesis)
  }
}
