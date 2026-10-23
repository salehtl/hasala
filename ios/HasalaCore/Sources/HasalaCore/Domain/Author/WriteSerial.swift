import Synchronization

public final class WriteSerial: Sendable {
  private let state = Mutex<(busy: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

  public init() {}

  public func run<T: Sendable>(_ body: () async throws -> T) async throws -> T {
    await acquire()
    defer { release() }
    return try await body()
  }

  public var isBusy: Bool { state.withLock { $0.busy } }

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
