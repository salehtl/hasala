import AppIntents
import HasalaModels
import HasalaWidgetData
import WidgetKit

struct GlanceEntry: TimelineEntry {
  let date: Date
  let snapshot: WidgetSnapshot?
  var selection: String?
  var stale = false

  init(date: Date, snapshot: WidgetSnapshot?, selection: String? = nil, stale: Bool = false) {
    self.date = date
    self.snapshot = snapshot
    self.selection = selection
    self.stale = stale
  }

  init(date: Date, stored: WidgetSnapshot?, selection: String?) {
    let reading = WidgetReading(stored, at: date)
    self.init(date: date, snapshot: reading.snapshot, selection: selection, stale: reading.stale)
  }

  static func current(selection: String? = nil) -> GlanceEntry {
    GlanceEntry(date: .now, stored: WidgetSnapshotStore.shared()?.read(), selection: selection)
  }

  static func timeline(selection: String? = nil, now: Date = .now) -> Timeline<GlanceEntry> {
    let stored = WidgetSnapshotStore.shared()?.read()
    let midnight = WidgetClock.nextMidnight(after: now)
    return Timeline(
      entries: [
        GlanceEntry(date: now, stored: stored, selection: selection),
        GlanceEntry(date: midnight, stored: stored, selection: selection),
      ],
      policy: .after(midnight))
  }

  var hidden: Bool { snapshot?.amountsHidden ?? false }

  var firstSentence: String { stale ? WaitingCopy.stale : WaitingCopy.firstAlert }
}

struct GlanceProvider: TimelineProvider {
  func placeholder(in context: Context) -> GlanceEntry {
    GlanceEntry(date: .now, snapshot: nil)
  }

  func getSnapshot(in context: Context, completion: @escaping (GlanceEntry) -> Void) {
    completion(.current())
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<GlanceEntry>) -> Void) {
    completion(GlanceEntry.timeline())
  }
}

struct CategoryProvider: AppIntentTimelineProvider {
  func placeholder(in context: Context) -> GlanceEntry {
    GlanceEntry(date: .now, snapshot: nil)
  }

  func snapshot(for configuration: CategoryWatchIntent, in context: Context) async -> GlanceEntry {
    .current(selection: configuration.category?.id)
  }

  func timeline(for configuration: CategoryWatchIntent, in context: Context) async -> Timeline<GlanceEntry> {
    GlanceEntry.timeline(selection: configuration.category?.id)
  }
}

struct ProjectProvider: AppIntentTimelineProvider {
  func placeholder(in context: Context) -> GlanceEntry {
    GlanceEntry(date: .now, snapshot: nil)
  }

  func snapshot(for configuration: ProjectWidgetIntent, in context: Context) async -> GlanceEntry {
    .current(selection: configuration.project?.id)
  }

  func timeline(for configuration: ProjectWidgetIntent, in context: Context) async -> Timeline<GlanceEntry> {
    GlanceEntry.timeline(selection: configuration.project?.id)
  }
}

struct GoalProvider: AppIntentTimelineProvider {
  func placeholder(in context: Context) -> GlanceEntry {
    GlanceEntry(date: .now, snapshot: nil)
  }

  func snapshot(for configuration: GoalWidgetIntent, in context: Context) async -> GlanceEntry {
    .current(selection: configuration.goal?.id)
  }

  func timeline(for configuration: GoalWidgetIntent, in context: Context) async -> Timeline<GlanceEntry> {
    GlanceEntry.timeline(selection: configuration.goal?.id)
  }
}
