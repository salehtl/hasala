import Foundation
import Observation

@MainActor protocol CloudSortControlling: AnyObject, Observable {
  var status: CloudSortStatus { get }
  func refresh() async
  func sendAllBack() async -> Int
  func countsChanged()
}

nonisolated struct CloudSortStatus: Equatable, Sendable {
  enum Pause: Equatable, Sendable { case offline, background, busy(untilMs: Int64), rateLimited(untilMs: Int64), dayCap }
  enum Phase: Equatable, Sendable { case off, idle, running, paused(Pause), done }
  var phase: Phase
  var cloudSortedCount: Int
}

extension CloudSortStatus {
  static let off = CloudSortStatus(phase: .off, cloudSortedCount: 0)
}
