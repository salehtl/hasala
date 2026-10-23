#if HASALA_MOCKS
  import Foundation
  import Observation

  @MainActor
  @Observable
  final class MockCloudSortController: CloudSortControlling {
    static let argument = "-HasalaCloudSortPhase"

    var status: CloudSortStatus
    private(set) var refreshes = 0
    private(set) var sentBack = 0
    private(set) var recounts = 0

    init(_ status: CloudSortStatus = MockCloudSortController.sample(.idle)) {
      self.status = status
    }

    static func fromLaunchArguments(_ arguments: [String]) -> MockCloudSortController? {
      guard let i = arguments.firstIndex(of: argument), i + 1 < arguments.count, let phase = phase(arguments[i + 1]) else {
        return nil
      }
      return MockCloudSortController(sample(phase))
    }

    static func phase(_ code: String) -> CloudSortStatus.Phase? {
      let inAWhile = Int64(Date().timeIntervalSince1970 * 1000) + 15 * 60_000
      switch code {
      case "off": return .off
      case "idle": return .idle
      case "running": return .running
      case "offline": return .paused(.offline)
      case "background": return .paused(.background)
      case "busy": return .paused(.busy(untilMs: inAWhile))
      case "rateLimited": return .paused(.rateLimited(untilMs: inAWhile))
      case "dayCap": return .paused(.dayCap)
      case "done": return .done
      default: return nil
      }
    }

    static func sample(_ phase: CloudSortStatus.Phase) -> CloudSortStatus {
      var s = CloudSortStatus.off
      s.phase = phase
      switch phase {
      case .off, .idle:
        break
      case .running, .paused:
        s.pendingTxnIDs = ["apple", "steam"]
      case .done:
        s.cloudSortedCount = 104
      }
      return s
    }

    func refresh() async { refreshes += 1 }

    func countsChanged() { recounts += 1 }

    func sendAllBack() async -> Int {
      sentBack += 1
      let n = status.cloudSortedCount
      status.cloudSortedCount = 0
      return n
    }
  }
#endif
