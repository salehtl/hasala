import CoreAuth
import CoreCrypto
import CoreJSON
import CoreSoftAuth
import CoreTestSupport
import CoreWire
import Foundation
import Testing

@testable import CoreSync

@Suite("Pull: the plaintext one page may hold")
struct PagePlaintextTests {
  func twoPhones() async throws -> (World, SyncContext, SyncContext) {
    let w = World()
    let a = w.phone("a")
    let (account, words, ctxA) = try await w.passwordAccount(a)
    let b = w.phone("b")
    let r = try await AccountSignIn.withPassword(b.env, email: "maya@example.com", password: password, bound: nil)
    let body = try await Enrolment.unlockWithPhrase(b.env, userID: account.userID, typed: words.joined(separator: " "))
    let enrolled = try await Enrolment.enrolWriter(
      b.env, userID: account.userID, body: body, emailNorm: r.emailNorm, serverSalt: r.serverSalt)
    return (w, ctxA, Enrolment.context(b.env, account: enrolled))
  }

  func alone(_ i: Int) -> Op {
    Op(
      v: 4, type: .merchantCategoryRejected, opID: "01J0000000000000000000A0\(String(format: "%02d", i))",
      authoredAt: "2026-10-11T08:00:00.000Z", payload: .object(JSONObject([("merchant", .string("SYNTHETIC")), ("category", .string("food"))])))
  }

  @Test("over budget, a pull stores what it read, then the rest; one batch may span two pulled pages")
  func shorterPages() async throws {
    let (w, a, b) = try await twoPhones()
    try enqueue(a, (1...3).map(alone))
    #expect(await SyncEngine(context: a).run(.authored).stop == nil)
    #expect(w.server.storedRowCount(user: a.userID) == 3)

    let out = try await Puller.pull(b, observer: nil, plaintextBudget: 1)
    #expect(out.pages == 3 && out.rowsStored == 3 && out.opsOpened == 3)
    #expect(try b.store.wireRowCount() == 3)
    #expect(try b.store.chainHeads()[a.writerID]?.counter == 3)
    #expect(try await Puller.pull(b, observer: nil, plaintextBudget: 1).rowsStored == 0)
  }

  @Test("within budget, one pull stores the page whole")
  func wholePage() async throws {
    let (_, a, b) = try await twoPhones()
    try enqueue(a, (1...3).map(alone))
    #expect(await SyncEngine(context: a).run(.authored).stop == nil)
    let out = try await Puller.pull(b, observer: nil)
    #expect(out.pages == 1 && out.rowsStored == 3)
  }

  @Test("the cold fold reaches the same state when it folds in smaller slices")
  func coldFoldSlices() async throws {
    let (_, a, b) = try await twoRuntimes()
    try await a.bootstrap()
    #expect(await a.run(.authored).stop == nil)
    #expect(await b.run(.launch).stop == nil)
    let cursor = try b.context.store.syncState().cursorHot
    let whole = try await b.observer.coldFold(cursor: cursor)
    let sliced = try await b.observer.coldFold(cursor: cursor, plaintextBudget: 1)
    #expect(whole.serialized() == sliced.serialized() && cursor > 0)
  }
}
