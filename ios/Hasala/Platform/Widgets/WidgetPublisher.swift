import Foundation
import HasalaModels
import HasalaWidgetData
import Observation
import OSLog
import UIKit
import WidgetKit

@MainActor
final class WidgetPublisher {
  private let app: AppModel
  private let store: WidgetSnapshotStore?
  private let reload: @MainActor () -> Void
  private let today: @MainActor () -> LocalDate
  private let center: NotificationCenter
  private var last: Data?
  private var running = true
  private var observers: [NSObjectProtocol] = []

  init(
    app: AppModel, store: WidgetSnapshotStore? = WidgetSnapshotStore.shared(),
    center: NotificationCenter = .default,
    reload: @escaping @MainActor () -> Void = { WidgetCenter.shared.reloadAllTimelines() },
    today: @escaping @MainActor () -> LocalDate = { WidgetClock.today() }
  ) {
    self.app = app
    self.store = store
    self.today = today
    self.center = center
    self.reload = reload
    if store == nil { Self.log.notice("no App Group container: widgets get no snapshot") }
    for name in [
      UIApplication.significantTimeChangeNotification, UIApplication.willEnterForegroundNotification,
      UIApplication.protectedDataDidBecomeAvailableNotification,
    ] {
      observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.timeMoved() }
      })
    }
    observe()
  }

  private static let log = Logger(subsystem: "app.hasala.ios", category: "widgets")

  func timeMoved() {
    guard running else { return }
    if today() != app.store.now.date {
      let app = self.app
      Task { await app.refresh() }
    }
    publish()
  }

  var snapshot: WidgetSnapshot {
    GlanceEngine.snapshot(app.store.state, now: app.store.now, home: app.thisMonthSnapshot, amountsHidden: app.amountsHidden)
  }

  func stop() {
    running = false
    observers.forEach(center.removeObserver)
    observers = []
  }

  func publish() {
    guard running, let store else { return }
    guard let data = try? WidgetSnapshotStore.encode(snapshot), data != last else { return }
    do {
      try store.write(data)
      last = data
      reload()
    } catch {
      last = nil
    }
  }

  static func clear(
    store: WidgetSnapshotStore? = WidgetSnapshotStore.shared(),
    reload: @MainActor () -> Void = { WidgetCenter.shared.reloadAllTimelines() }
  ) {
    store?.clear()
    reload()
  }

  private func observe() {
    guard running else { return }
    withObservationTracking {
      publish()
    } onChange: { [weak self] in
      Task { @MainActor in self?.observe() }
    }
  }
}
