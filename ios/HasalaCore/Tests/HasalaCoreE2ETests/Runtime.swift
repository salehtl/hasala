// One bound account composed as the app's AccountRuntime composes it (spec 04
// §3; Lane B's Live/Runtime), minus the platform: the store and secrets of the
// enrolled phone, a projection, the LedgerPageObserver, the SyncEngine that
// folds through it, and the Outbox. Runs are triggered by the tests (the
// outbox's debounce is effectively off).
import CoreCategorize
import CoreDomain
import CoreOutbox
import CoreProjection
import CoreReplay
import CoreSync
import CoreTestSupport
import Foundation

let bundledDictionary = (try? MerchantDictionary.bundled().get()) ?? .empty

final class Runtime: Sendable {
  let context: SyncContext
  let projection: ProjectionStore
  let observer: LedgerPageObserver
  let engine: SyncEngine
  let outbox: Outbox

  init(_ context: SyncContext, projection: ProjectionStore? = nil) throws {
    self.context = context
    self.projection = try projection ?? ProjectionStore.inMemory()
    observer = LedgerPageObserver(context: context, projection: self.projection, dictionary: bundledDictionary)
    engine = SyncEngine(context: context, observer: observer)
    outbox = Outbox(store: context.store, clock: context.clock, debounce: .seconds(3600), onAuthored: {})
  }

  var reader: LedgerReader { projection.reader }

  /// Builds one blob with the observer's author context, enqueues it and re-projects.
  @discardableResult
  func author(_ body: (inout OpAuthor) throws -> Void) async throws -> AuthoredBlob {
    var a = OpAuthor(try await observer.authorContext())
    try body(&a)
    let blob = try a.build()
    try await outbox.enqueue(blob.ops)
    await observer.noteAuthored(blob)
    try await observer.reproject()
    return blob
  }

  /// The account's open (04 §6.2): home currency AED and the USD peg.
  func bootstrap() async throws {
    try await author { a in
      a.setHomeCurrency("AED")
      try a.setRate(currency: "USD", rateMicro: 3_672_500)
    }
  }

  /// "Use sample data": the bundled seed, blob by blob, through the outbox.
  func loadSample() async throws -> Int {
    let ctx = try await observer.authorContext()
    let blobs = try SampleSeed.batches(try SampleSeed.bundled(), nowMs: ctx.nowMs, context: ctx)
    for b in blobs {
      try await outbox.enqueue(b.ops)
      await observer.noteAuthored(b)
    }
    try await observer.reproject()
    return blobs.reduce(0) { $0 + $1.ops.count }
  }

  @discardableResult
  func run(_ t: SyncTrigger) async -> RunOutcome { await engine.run(t) }

  func state() async throws -> State { try await observer.currentState() }
}

/// Two enrolled iPhones of one password account on FakeServer: A created it, B
/// signed in and unlocked with the twelve words.
func twoRuntimes(_ w: World = World()) async throws -> (World, Runtime, Runtime) {
  let a = w.phone("a")
  let (account, words, ctxA) = try await w.passwordAccount(a)
  let b = w.phone("b")
  let r = try await AccountSignIn.withPassword(b.env, email: "maya@example.com", password: password, bound: nil)
  let body = try await Enrolment.unlockWithPhrase(b.env, userID: account.userID, typed: words.joined(separator: " "))
  let enrolled = try await Enrolment.enrolWriter(b.env, userID: account.userID, body: body, emailNorm: r.emailNorm, serverSalt: r.serverSalt)
  let ra = try Runtime(ctxA)
  let rb = try Runtime(Enrolment.context(b.env, account: enrolled))
  try await ra.observer.open()
  try await rb.observer.open()
  return (w, ra, rb)
}
