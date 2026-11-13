import Synchronization

public final class WriteSerial: Sendable {
  public struct Held: Error {}

  private let state = Mutex<(busy: Bool, held: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, false, []))

  public init() {}

  public func run<T: Sendable>(_ body: () async throws -> T) async throws -> T {
    await acquire()
    defer { release() }
    if state.withLock({ $0.held }) { throw Held() }
    return try await body()
  }

  public func finished() async {
    await acquire()
    release()
  }

  public func hold() async {
    state.withLock { $0.held = true }
    await finished()
  }

  public func releaseHold() {
    state.withLock { $0.held = false }
  }

  public var isBusy: Bool { state.withLock { $0.busy } }

  var queued: Int { state.withLock { $0.waiters.count } }

  private func acquire() async {
    await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
      let now = state.withLock { s -> Bool in
        if s.busy {
          s.waiters.append(k)
          return false
        }
        s.busy = true
        return true
      }
      if now { k.resume() }
    }
  }

  private func release() {
    let next = state.withLock { s -> CheckedContinuation<Void, Never>? in
      if s.waiters.isEmpty {
        s.busy = false
        return nil
      }
      return s.waiters.removeFirst()
    }
    next?.resume()
  }
}
