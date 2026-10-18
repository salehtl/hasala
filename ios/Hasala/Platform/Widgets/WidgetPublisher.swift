import Foundation
import HasalaModels
import HasalaWidgetData
import Observation
import WidgetKit

@MainActor
final class WidgetPublisher {
  private let app: AppModel
  private let store: WidgetSnapshotStore?
  private let reload: @MainActor () -> Void
  private var last: Data?
  private var running = true

  init(
    app: AppModel, store: WidgetSnapshotStore? = WidgetSnapshotStore.shared(),
    reload: @escaping @MainActor () -> Void = { WidgetCenter.shared.reloadAllTimelines() }
  ) {
    self.app = app
    self.store = store
    self.reload = reload
    observe()
  }

  var snapshot: WidgetSnapshot {
    GlanceEngine.snapshot(app.store.state, now: app.store.now, home: app.snapshot, amountsHidden: app.amountsHidden)
  }

  func stop() {
    running = false
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
