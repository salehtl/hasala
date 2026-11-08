import CoreAuth
import CoreCrypto
import CoreSoftAuth
import CoreSync
import CoreTestSupport
import Foundation
import Synchronization
import Testing

final class RefusingDeletes: SecretStore, Sendable {
  let inner: MemorySecretStore
  private let refused = Mutex<Set<String>>([])

  init(_ inner: MemorySecretStore) { self.inner = inner }

  func refuse(_ services: Set<String>) { refused.withLock { $0 = services } }

  func read(_ item: SecretItem) throws(SecretStoreError) -> Data? { try inner.read(item) }
  func write(_ item: SecretItem, _ value: Data) throws(SecretStoreError) { try inner.write(item, value) }
  func accounts(service: String) throws(SecretStoreError) -> [String] { try inner.accounts(service: service) }
  func delete(_ item: SecretItem) throws(SecretStoreError) {
    if refused.withLock({ $0.contains(item.service) }) { throw .failed(status: -1) }
    try inner.delete(item)
  }
}

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

  // MARK: The server's log generation

  func enrolledWithoutGeneration(_ w: World) async throws -> SyncContext {
    let a = w.phone("a")
    let (account, words, _) = try await w.passwordAccount(a)
    let b = w.phone("b")
    let r = try await AccountSignIn.withPassword(b.env, email: "maya@example.com", password: password, bound: nil)
    let body = try await Enrolment.unlockWithPhrase(b.env, userID: account.userID, typed: words.joined(separator: " "))
    defer { body.wipe() }
    w.server.refuseNext("GET /api/v1/meta", status: 503, code: "unavailable")
    let enrolled = try await Enrolment.enrolWriter(
      b.env, userID: account.userID, body: body, emailNorm: r.emailNorm, serverSalt: r.serverSalt)
    let ctx = Enrolment.context(b.env, account: enrolled)
    #expect(try ctx.store.syncState().logGeneration == nil)
    return ctx
  }

  @Test("an iPhone enrolled while /meta failed records the generation on its first run and can report a restore")
  func generationRecordedAfterEnrolment() async throws {
    let w = World()
    let ctx = try await enrolledWithoutGeneration(w)
    #expect(await SyncEngine(context: ctx).run(.launch).stop == nil)
    #expect(try ctx.store.syncState().logGeneration == 1)

    w.server.injectRow(
      user: ctx.userID, writerID: ctx.writerID.string, counter: 1, prevHash: Data(count: 32),
      blob: Data(repeating: 7, count: 1024), headSig: Data(repeating: 1, count: 64))
    w.server.setLogGeneration(2)
    let engine = SyncEngine(context: ctx)
    _ = await engine.run(.launch)
    #expect(await engine.status.phase == .halted(.serverRestored))
    #expect(try ctx.store.syncState().logGeneration == 1)
  }

  @Test("/meta failing again leaves the run alone, and a later run records the generation")
  func generationRetriedWhileMetaFails() async throws {
    let w = World()
    let ctx = try await enrolledWithoutGeneration(w)
    w.server.refuseNext("GET /api/v1/meta", status: 503, code: "unavailable")
    #expect(await SyncEngine(context: ctx).run(.launch).stop == nil)
    #expect(try ctx.store.syncState().logGeneration == nil)
    #expect(await SyncEngine(context: ctx).run(.foreground).stop == nil)
    #expect(try ctx.store.syncState().logGeneration == 1)
  }

  @Test("a recorded generation is never replaced by a later one")
  func recordedGenerationStays() async throws {
    let w = World()
    let (_, _, ctx) = try await w.passwordAccount(w.phone("a"))
    #expect(try ctx.store.syncState().logGeneration == 1)
    w.server.setLogGeneration(5)
    #expect(await SyncEngine(context: ctx).run(.launch).stop == nil)
    #expect(try ctx.store.syncState().logGeneration == 1)
  }

  // MARK: Remove this iPhone

  @Test("removal stops while ops wait behind a latch: the writer stays and every op and key is kept")
  func removalKeepsOpsBehindALatch() async throws {
    for fault in [false, true] {
      let w = World()
      let a = w.phone("a")
      let (_, _, ctx) = try await w.passwordAccount(a)
      try enqueue(ctx, [op(1)])
      if fault { try ctx.store.setLatch(.sealerFault) } else { try ctx.store.setLatch(.hardStop) }
      let held = a.keychain.count
      let binding = try #require(a.binding)
      do throws(CeremonyError) {
        try await AccountManagement.removeThisIPhone(
          a.env, engine: SyncEngine(context: ctx), factor: .device(password: password), binding: binding)
        Issue.record("removed with an op that never left this iPhone")
      } catch {
        guard case .badResponse = error else {
          Issue.record("\(error)")
          continue
        }
      }
      #expect(try ctx.store.pendingCount() == 1)
      #expect(a.keychain.count == held)
      let token = try #require(try a.env.secrets.session()).token
      let writers = try await a.env.client.writers(bearer: token).writers
      #expect(writers.first { $0.writer_id == ctx.writerID.string }?.revoked_at == nil)
    }
  }

  @Test("removal under a latch with nothing waiting goes ahead")
  func removalUnderALatchWithNothingWaiting() async throws {
    let w = World()
    let a = w.phone("a")
    let (_, _, ctx) = try await w.passwordAccount(a)
    try ctx.store.setLatch(.hardStop)
    try await AccountManagement.removeThisIPhone(
      a.env, engine: SyncEngine(context: ctx), factor: .device(password: password), binding: try #require(a.binding))
    #expect(a.keychain.count == 0)
  }

  // MARK: The local wipe and what boot finds after it

  @Test("a wipe the Keychain refused keeps the store of the iPhone still bound; the next wipe finishes")
  func refusedWipeKeepsTheStore() async throws {
    let w = World()
    let a = w.phone("a")
    let (account, words, _) = try await w.passwordAccount(a)
    let b = w.phone("b")
    let dir = temporaryDirectory("refused-wipe")
    defer { try? FileManager.default.removeItem(at: dir) }
    let keychain = RefusingDeletes(b.keychain)
    let env = onDisk(w, b, dir, secrets: keychain)
    let enrolled = try await enrol(env, account.userID, words)

    keychain.refuse(["app.hasala.session", "app.hasala.account", "app.hasala.epoch-key", "app.hasala.writer-key"])
    AccountWipe.wipe(env, userID: account.userID, writerID: enrolled.writerID)
    #expect(try hasLedger(env, account.userID))
    #expect(isOpening(env))
    #expect(Boot.decide(Boot.gather(env)) != .restoring)

    keychain.refuse([])
    AccountWipe.wipe(env, userID: account.userID, writerID: enrolled.writerID)
    #expect(try !hasLedger(env, account.userID))
    #expect(Boot.decide(Boot.gather(env)) == .signedOut)
  }

  @Test("a wipe that removed the binding removes the files even when another item stayed")
  func wipeWithBindingGoneRemovesTheFiles() async throws {
    let w = World()
    let a = w.phone("a")
    let (account, words, _) = try await w.passwordAccount(a)
    let b = w.phone("b")
    let dir = temporaryDirectory("partial-wipe")
    defer { try? FileManager.default.removeItem(at: dir) }
    let keychain = RefusingDeletes(b.keychain)
    let env = onDisk(w, b, dir, secrets: keychain)
    let enrolled = try await enrol(env, account.userID, words)
    keychain.refuse(["app.hasala.epoch-key"])
    AccountWipe.wipe(env, userID: account.userID, writerID: enrolled.writerID)
    #expect(try env.secrets.binding() == nil)
    #expect(try !hasLedger(env, account.userID))
  }
}
