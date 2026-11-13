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

  init(date: Date, stored: StoredWidgetSnapshot, selection: String?, isPreview: Bool = false) {
    let reading = WidgetPreview.reading(stored, at: date, isPreview: isPreview)
    self.init(date: date, snapshot: reading.snapshot, selection: reading.selection(selection), stale: reading.stale)
  }

  private static func stored() -> StoredWidgetSnapshot {
    WidgetSnapshotStore.shared()?.load() ?? .absent
  }

  static func current(selection: String? = nil, isPreview: Bool = false) -> GlanceEntry {
    GlanceEntry(date: .now, stored: stored(), selection: selection, isPreview: isPreview)
  }

  static func timeline(selection: String? = nil, now: Date = .now) -> Timeline<GlanceEntry> {
    let file = stored()
    let midnight = WidgetClock.nextMidnight(after: now)
    return Timeline(
      entries: [
        GlanceEntry(date: now, stored: file, selection: selection),
        GlanceEntry(date: midnight, stored: file, selection: selection),
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
    completion(.current(isPreview: context.isPreview))
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
    .current(selection: configuration.category?.id, isPreview: context.isPreview)
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
    .current(selection: configuration.project?.id, isPreview: context.isPreview)
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
    .current(selection: configuration.goal?.id, isPreview: context.isPreview)
  }

  func timeline(for configuration: GoalWidgetIntent, in context: Context) async -> Timeline<GlanceEntry> {
    GlanceEntry.timeline(selection: configuration.goal?.id)
  }
}
