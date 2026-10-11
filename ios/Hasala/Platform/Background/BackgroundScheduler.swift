import BackgroundTasks
import Foundation
import os

/// The two BGTaskScheduler tasks of spec 04 §7.9 (identifiers listed in Info.plist's
/// `BGTaskSchedulerPermittedIdentifiers`):
///
/// - `app.hasala.ios.refresh` (BGAppRefreshTask): one 25 s run of the work coordinator, the
///   floor that keeps Gmail catch-up going when silent pushes are throttled or the app was
///   force-quit. Resubmitted on every run.
/// - `app.hasala.ios.processing` (BGProcessingTask, network required): first-connect scan and
///   backfill pages until iOS expires the task.
///
/// `register()` must run before the app finishes launching (the App's `init`). The work itself
/// is installed later, once an account runtime exists (`install(_:)`); a task that fires with no
/// work installed (signed out, or before first unlock) completes at once without failing.
nonisolated final class BackgroundScheduler: Sendable {
  enum Kind: Sendable { case refresh, processing }

  /// The work for one task: runs until `deadlineMs` (epoch ms; nil = until expiration) and
  /// returns whether more background work is pending (a backfill still running).
  typealias Work = @Sendable (_ kind: Kind, _ deadlineMs: Int64?) async -> Bool

  static let refreshID = "app.hasala.ios.refresh"
  static let processingID = "app.hasala.ios.processing"
  /// Earliest begin date of the next refresh.
  static let refreshInterval: TimeInterval = 15 * 60
  /// A refresh run's budget (spec 04 §3: start + 25 s).
  static let refreshBudgetMs: Int64 = 25_000

  static let shared = BackgroundScheduler()

  private let work = OSAllocatedUnfairLock<Work?>(initialState: nil)
  private let log = Logger(subsystem: "app.hasala.ios", category: "background")

  func install(_ w: Work?) { work.withLock { $0 = w } }

  /// Registers both launch handlers. Call once, from the App's `init`.
  func register() {
    BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshID, using: nil) { task in
      self.handle(task, kind: .refresh)
    }
    BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.processingID, using: nil) { task in
      self.handle(task, kind: .processing)
    }
  }

  func scheduleRefresh() {
    let r = BGAppRefreshTaskRequest(identifier: Self.refreshID)
    r.earliestBeginDate = Date(timeIntervalSinceNow: Self.refreshInterval)
    submit(r)
  }

  /// Asks for a processing window while a scan or backfill is pending.
  func scheduleProcessing() {
    let r = BGProcessingTaskRequest(identifier: Self.processingID)
    r.requiresNetworkConnectivity = true
    r.requiresExternalPower = false
    submit(r)
  }

  /// Cancels both (sign-out, "Remove this iPhone", §4.7).
  func cancelAll() {
    BGTaskScheduler.shared.cancelAllTaskRequests()
  }

  private func submit(_ r: BGTaskRequest) {
    do { try BGTaskScheduler.shared.submit(r) } catch {
      // Unavailable in the simulator and when Background App Refresh is off; foreground runs
      // still catch up.
      log.info("bg submit refused: \(String(describing: type(of: error)), privacy: .public)")
    }
  }

  private func handle(_ task: BGTask, kind: Kind) {
    if kind == .refresh { scheduleRefresh() }  // resubmitted every run
    guard let w = work.withLock({ $0 }) else {
      task.setTaskCompleted(success: true)
      return
    }
    let deadline: Int64? =
      kind == .refresh ? Int64(Date().timeIntervalSince1970 * 1000) + Self.refreshBudgetMs : nil
    let box = TaskBox(task)
    let job = Task {
      let pending = await w(kind, deadline)
      if pending { self.scheduleProcessing() }
      box.task.setTaskCompleted(success: !Task.isCancelled)
    }
    task.expirationHandler = { job.cancel() }
  }
}

/// BGTask is not Sendable; the system allows completing it from any thread.
nonisolated private final class TaskBox: @unchecked Sendable {
  let task: BGTask
  init(_ t: BGTask) { task = t }
}
