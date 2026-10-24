#if HASALA_MOCKS
  import Foundation
  import Observation

  @MainActor
  @Observable
  final class MockCloudSortController: CloudSortControlling {
    static let argument = "-HasalaCloudSortPhase"

    var status: CloudSortStatus
    private(set) var sentBack = 0

    init(_ status: CloudSortStatus = MockCloudSortController.sample(.idle)) {
      self.status = status
    }

    static func fromLaunchArguments(_ arguments: [String]) -> MockCloudSortController? {
      guard let code = arguments.launchValue(after: argument), let phase = phase(code) else { return nil }
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
      CloudSortStatus(phase: phase, cloudSortedCount: phase == .done ? 104 : 0)
    }

    func refresh() async {}

    func countsChanged() {}

    func sendAllBack() async -> Int {
      sentBack += 1
      let n = status.cloudSortedCount
      status.cloudSortedCount = 0
      return n
    }
  }
#endif
