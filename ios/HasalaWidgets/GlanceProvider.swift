import AppIntents
import HasalaModels
import HasalaWidgetData
import WidgetKit

struct GlanceEntry: TimelineEntry {
  let date: Date
  let snapshot: WidgetSnapshot?
  var selection: String?

  static func current(selection: String? = nil) -> GlanceEntry {
    GlanceEntry(date: .now, snapshot: WidgetSnapshotStore.shared()?.read(), selection: selection)
  }

  var hidden: Bool { snapshot?.amountsHidden ?? false }
}

struct GlanceProvider: TimelineProvider {
  func placeholder(in context: Context) -> GlanceEntry {
    GlanceEntry(date: .now, snapshot: nil)
  }

  func getSnapshot(in context: Context, completion: @escaping (GlanceEntry) -> Void) {
    completion(.current())
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<GlanceEntry>) -> Void) {
    completion(Timeline(entries: [.current()], policy: .never))
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
    Timeline(entries: [.current(selection: configuration.category?.id)], policy: .never)
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
    Timeline(entries: [.current(selection: configuration.project?.id)], policy: .never)
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
    Timeline(entries: [.current(selection: configuration.goal?.id)], policy: .never)
  }
}
