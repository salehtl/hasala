#if HASALA_MOCKS
  import Foundation
  import HasalaModels

  struct MockAppLock {
    static let argument = "-HasalaAppLock"
    static let graceArgument = "-HasalaAppLockGrace"
    static let issueArgument = "-HasalaAppLockIssue"

    var armed = false
    var available = true
    var system = false
    var checks: [LockCheck] = []
    var grace: Duration = AppLockController.grace
    var issue: BiometryIssue?

    init() {}

    init(_ arguments: [String]) {
      if let value = arguments.launchValue(after: Self.argument) {
        armed = true
        if value == "none" {
          available = false
        } else if value == "system" {
          system = true
        } else {
          checks = value.split(separator: ",").compactMap { Self.check(String($0)) }
        }
      }
      if let value = arguments.launchValue(after: Self.issueArgument) {
        switch value {
        case "notEnrolled": issue = .notEnrolled
        case "denied": issue = .denied
        case "lockedOut": issue = .lockedOut
        default: break
        }
      }
      if let seconds = arguments.launchValue(after: Self.graceArgument).flatMap({ Int($0) }) {
        grace = .seconds(seconds)
      }
    }

    func controller(store: any LedgerStore) -> AppLockController {
      let script = Script(checks: checks)
      let available = available
      let armed = armed
      let system = system
      let issue = issue
      return AppLockController(
        makeContext: {
          system ? SystemLockContext() as any LockContext : MockLockContext(available: available, issue: issue, script: script)
        },
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
    var issue: BiometryIssue?
    let script: MockAppLock.Script

    var biometry: LockBiometry { .faceID }
    var biometryIssue: BiometryIssue? { issue }
    func canEvaluate() -> Bool { available }

    func evaluate(reason: String) async -> LockCheck {
      try? await Task.sleep(for: .milliseconds(150))
      return script.next()
    }
  }
#endif
