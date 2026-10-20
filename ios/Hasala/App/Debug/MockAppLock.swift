#if HASALA_MOCKS
  import Foundation
  import HasalaModels

  struct MockAppLock {
    static let argument = "-HasalaAppLock"
    static let graceArgument = "-HasalaAppLockGrace"

    var armed = false
    var available = true
    var system = false
    var checks: [LockCheck] = []
    var grace: Duration = AppLockController.grace

    init() {}

    init(_ arguments: [String]) {
      if let i = arguments.firstIndex(of: Self.argument), i + 1 < arguments.count {
        armed = true
        let value = arguments[i + 1]
        if value == "none" {
          available = false
        } else if value == "system" {
          system = true
        } else {
          checks = value.split(separator: ",").compactMap { Self.check(String($0)) }
        }
      }
      if let i = arguments.firstIndex(of: Self.graceArgument), i + 1 < arguments.count,
        let seconds = Int(arguments[i + 1])
      {
        grace = .seconds(seconds)
      }
    }

    func controller(store: any LedgerStore) -> AppLockController {
      let script = Script(checks: checks)
      let available = available
      let armed = armed
      let system = system
      return AppLockController(
        makeContext: { system ? SystemLockContext() as any LockContext : MockLockContext(available: available, script: script) },
        isEnabled: { armed && store.state.prefs.faceIDLock }, grace: grace)
    }

    private static func check(_ name: String) -> LockCheck? {
      switch name {
      case "pass": .passed
      case "cancel": .cancelled
      case "fail": .failed
      default: nil
      }
    }

    final class Script {
      var checks: [LockCheck]
      init(checks: [LockCheck]) { self.checks = checks }
      func next() -> LockCheck { checks.isEmpty ? .passed : checks.removeFirst() }
    }
  }

  struct MockLockContext: LockContext {
    let available: Bool
    let script: MockAppLock.Script

    var biometry: LockBiometry { .faceID }
    func canEvaluate() -> Bool { available }

    func evaluate(reason: String) async -> LockCheck {
      try? await Task.sleep(for: .milliseconds(150))
      return script.next()
    }
  }
#endif
