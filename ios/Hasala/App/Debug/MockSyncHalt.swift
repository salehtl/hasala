#if HASALA_MOCKS
  import CoreSync
  import Foundation
  import Observation

  @MainActor
  @Observable
  final class MockSyncHalt {
    static let argument = "-HasalaSyncHalt"

    private(set) var halt: HaltKind?
    private(set) var retrying = false

    init(_ arguments: [String]) {
      halt = arguments.launchValue(after: Self.argument).flatMap(Self.halt)
    }

    func tryAgain() {
      guard halt != nil, !retrying else { return }
      retrying = true
      Task {
        try? await Task.sleep(for: .milliseconds(300))
        retrying = false
        halt = nil
      }
    }

    static let kinds: [HaltKind] =
      TamperReason.allCases.map(HaltKind.tampered) + [.tamperedResend, .serverRestored, .inconsistent("mock"), .rosterInvalid, .unprovedRevocation, .unexpectedGone]

    static func halt(_ code: String) -> HaltKind? {
      kinds.first { SyncHaltWall.code($0) == code }
    }
  }
#endif
