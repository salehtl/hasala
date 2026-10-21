#if HASALA_MOCKS
  import Foundation
  import Observation

  @MainActor
  @Observable
  final class MockCloudSortController: CloudSortControlling {
    static let argument = "-HasalaCloudSortPhase"

    var status: CloudSortStatus
    private(set) var refreshes = 0
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var undos = 0
    private(set) var sentBack = 0

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
      case "runCap": return .paused(.runCap)
      case "dayCap": return .paused(.dayCap)
      case "done": return .done
      default: return nil
      }
    }

    static func sample(_ phase: CloudSortStatus.Phase) -> CloudSortStatus {
      var s = CloudSortStatus.off
      s.phase = phase
      switch phase {
      case .off:
        return s
      case .idle:
        s.waitingNames = 147
        s.waitingPayments = 162
        s.leftForYou = 25
        s.staysOnDevice = 18
      case .running, .paused:
        s.waitingNames = 64
        s.waitingPayments = 71
        s.askedNames = 83
        s.totalNames = 147
        s.filed = 41
        s.suggested = 19
        s.leftForYou = 25
        s.staysOnDevice = 18
        s.pendingTxnIDs = ["apple", "steam"]
      case .done:
        s.askedNames = 147
        s.totalNames = 147
        s.filed = 104
        s.suggested = 33
        s.leftForYou = 25
        s.staysOnDevice = 18
        s.lastRunEndedMs = Int64(Date().timeIntervalSince1970 * 1000)
        s.canUndoLastRun = true
        s.cloudSortedCount = 104
      }
      if case .paused(.runCap) = phase {
        s.waitingNames = 147
        s.askedNames = 250
        s.totalNames = 250
      }
      s.remainingToday = phase == .paused(.dayCap) ? 0 : 400 - s.askedNames
      s.nextRunNames = min(s.waitingNames, 250, s.remainingToday)
      return s
    }

    func refresh() async { refreshes += 1 }

    func start() {
      starts += 1
      status = Self.sample(.running)
    }

    func stop() {
      stops += 1
      status = Self.sample(.done)
    }

    func undoLastRun() async -> Int {
      undos += 1
      let n = status.canUndoLastRun ? status.filed : 0
      status.canUndoLastRun = false
      status.suggested += n
      status.cloudSortedCount = max(0, status.cloudSortedCount - n)
      status.filed = 0
      return n
    }

    func sendAllBack() async -> Int {
      sentBack += 1
      let n = status.cloudSortedCount
      status.cloudSortedCount = 0
      status.canUndoLastRun = false
      return n
    }
  }
#endif
