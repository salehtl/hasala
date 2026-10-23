import Foundation
import Observation

@MainActor protocol CloudSortControlling: AnyObject, Observable {
  var status: CloudSortStatus { get }
  func refresh() async
  func start()
  func stop()
  func undoLastRun() async -> Int
  func sendAllBack() async -> Int
  func reviewOpened()
  func offerShown()
  func countsChanged()
}

nonisolated struct CloudSortStatus: Equatable, Sendable {
  enum Pause: Equatable, Sendable { case offline, background, busy(untilMs: Int64), rateLimited(untilMs: Int64), runCap, dayCap }
  enum Phase: Equatable, Sendable { case off, idle, running, paused(Pause), done }
  var phase: Phase
  var waitingNames: Int
  var waitingPayments: Int
  var askedNames: Int
  var totalNames: Int
  var filed: Int
  var suggested: Int
  var leftForYou: Int
  var staysOnDevice: Int
  var pendingTxnIDs: Set<String>
  var lastRunEndedMs: Int64?
  var canUndoLastRun: Bool
  var cloudSortedCount: Int
  var remainingToday: Int
  var nextRunNames: Int
  var offerDue = false
}

extension CloudSortStatus {
  static let off = CloudSortStatus(
    phase: .off, waitingNames: 0, waitingPayments: 0, askedNames: 0, totalNames: 0, filed: 0, suggested: 0, leftForYou: 0,
    staysOnDevice: 0, pendingTxnIDs: [], lastRunEndedMs: nil, canUndoLastRun: false, cloudSortedCount: 0, remainingToday: 0,
    nextRunNames: 0)
}
