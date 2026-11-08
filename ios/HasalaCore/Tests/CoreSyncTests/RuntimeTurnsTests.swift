import Synchronization
import Testing

@testable import CoreSync

@MainActor
@Suite("CoreSync: RuntimeTurns")
struct RuntimeTurnsTests {
  final class Fake: Sendable {
    let name: String
    init(_ name: String) { self.name = name }
  }

  final class Log: Sendable {
    let entries = Mutex<[String]>([])
    func add(_ s: String) { entries.withLock { $0.append(s) } }
    var all: [String] { entries.withLock { $0 } }
  }

  final class Gate: Sendable {
    let state = Mutex<(open: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    func wait() async {
      await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
        let now = state.withLock { s -> Bool in
          if s.open { return true }
          s.waiters.append(k)
          return false
        }
        if now { k.resume() }
      }
    }

    func release() {
      for k in state.withLock({ s -> [CheckedContinuation<Void, Never>] in
        s.open = true
        defer { s.waiters = [] }
        return s.waiters
      }) { k.resume() }
    }
  }

  static func settle() async {
    for _ in 0..<40 { await Task.yield() }
  }

  static func openGated(_ turns: RuntimeTurns<Fake>, _ name: String, gate: Gate, log: Log) {
    turns.open { turn in
      log.add("\(name).start")
      await gate.wait()
      log.add("\(name).made")
      guard turns.isCurrent(turn) else {
        log.add("\(name).closed")
        return nil
      }
      turns.finishOpening(turn)
      return Fake(name)
    }
  }

  @Test func anOpeningLeftBehindIsOverBeforeTheNextOneStarts() async {
    let turns = RuntimeTurns<Fake>()
    let log = Log()
    let slow = Gate()
    let quick = Gate()
    quick.release()
    Self.openGated(turns, "first", gate: slow, log: log)
    await Self.settle()
    #expect(log.all == ["first.start"])

    let closed = Task { await turns.close(nil) { _ in } }
    await Self.settle()
    Self.openGated(turns, "second", gate: quick, log: log)
    await Self.settle()
    #expect(log.all == ["first.start"])

    slow.release()
    await closed.value
    await Self.settle()
    #expect(log.all == ["first.start", "first.made", "first.closed", "second.start", "second.made"])
  }

  @Test func closingWaitsForAnOpeningItLeftBehind() async {
    let turns = RuntimeTurns<Fake>()
    let log = Log()
    let slow = Gate()
    Self.openGated(turns, "first", gate: slow, log: log)
    await Self.settle()
    let closed = Task {
      await turns.close(nil) { _ in }
      log.add("closed")
    }
    await Self.settle()
    #expect(log.all == ["first.start"])
    slow.release()
    await closed.value
    #expect(log.all == ["first.start", "first.made", "first.closed", "closed"])
  }

  @Test func closingWithNothingOpenWaitsForTheCloseBeforeIt() async {
    let turns = RuntimeTurns<Fake>()
    let log = Log()
    let slow = Gate()
    let first = Task {
      await turns.close(Fake("a")) { _ in
        await slow.wait()
        log.add("a.closed")
      }
    }
    await Self.settle()
    let second = Task {
      await turns.close(nil) { _ in }
      log.add("second.done")
    }
    await Self.settle()
    #expect(log.all.isEmpty)
    slow.release()
    await first.value
    await second.value
    #expect(log.all == ["a.closed", "second.done"])
  }

  @Test func closesRunOneAfterAnother() async {
    let turns = RuntimeTurns<Fake>()
    let log = Log()
    let slow = Gate()
    let first = Task {
      await turns.close(Fake("a")) { _ in
        log.add("a.start")
        await slow.wait()
        log.add("a.end")
      }
    }
    await Self.settle()
    let second = Task {
      await turns.close(Fake("b")) { _ in log.add("b") }
    }
    await Self.settle()
    #expect(log.all == ["a.start"])
    slow.release()
    await first.value
    await second.value
    #expect(log.all == ["a.start", "a.end", "b"])
  }

  @Test func aNewOpeningWaitsForTheClose() async {
    let turns = RuntimeTurns<Fake>()
    let log = Log()
    let slow = Gate()
    let quick = Gate()
    quick.release()
    let closed = Task {
      await turns.close(Fake("a")) { _ in
        await slow.wait()
        log.add("a.closed")
      }
    }
    await Self.settle()
    Self.openGated(turns, "b", gate: quick, log: log)
    await Self.settle()
    #expect(log.all.isEmpty)
    slow.release()
    await closed.value
    await Self.settle()
    #expect(log.all == ["a.closed", "b.start", "b.made"])
  }

  @Test func aCloseEndsTheTurnOfWhatItClosed() async {
    let turns = RuntimeTurns<Fake>()
    let quick = Gate()
    quick.release()
    Self.openGated(turns, "a", gate: quick, log: Log())
    let turn = turns.turn
    #expect(turns.isCurrent(turn))
    #expect(await turns.opened()?.name == "a")
    #expect(!turns.isOpening)
    #expect(turns.isCurrent(turn))
    await turns.close(Fake("a")) { _ in }
    #expect(!turns.isCurrent(turn))
  }

  @Test func anOpeningNothingWaitsForAnswersNil() async {
    let turns = RuntimeTurns<Fake>()
    #expect(await turns.opened() == nil)
    await turns.close(nil) { _ in }
    #expect(!turns.isOpening)
  }
}
