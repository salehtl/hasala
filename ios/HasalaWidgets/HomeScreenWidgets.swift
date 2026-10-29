import HasalaDesign
import HasalaModels
import HasalaWidgetData
import SwiftUI
import WidgetKit

enum WaitingCopy {
  static let firstAlert = "Your first bank alert will fill this in."
  static let stale = "Open Hasala to bring this up to date."
  static let bill = "Bills Hasala finds will show here."
  static let netWorth = "Your first account check-in will fill this in."
  static let project = "Start a project in Plan to see it here."
  static let goal = "Add a savings goal in Plan to see it here."
  static let category = "Set a budget in Plan to watch a category."
  static let projectGone = "Touch and hold to choose a project."
  static let goalGone = "Touch and hold to choose a goal."
}

struct GlanceCard<Content: View>: View {
  let link: WidgetLink
  let fill: AnyShapeStyle
  @ViewBuilder let content: () -> Content

  var body: some View {
    content()
      .environment(\.widgetHost, .system)
      .containerBackground(fill, for: .widget)
      .widgetURL(link.url)
  }
}

struct Waiting: View {
  let title: String
  let sentence: String
  let link: WidgetLink

  var body: some View {
    GlanceCard(link: link, fill: AnyShapeStyle(HColor.widgetSurfaceWaiting)) {
      WaitingWidgetView(title: title, sentence: sentence)
    }
  }
}

private let light = AnyShapeStyle(HColor.widgetSurface)
private let ink = AnyShapeStyle(HColor.widgetSurfaceInverse)

struct SpentSoFarEntryView: View {
  @Environment(\.widgetFamily) private var family
  let entry: GlanceEntry

  var body: some View {
    let model = entry.snapshot?.spentSoFar
    let showsAmounts = entry.snapshot?.lockShowsAmounts ?? false
    switch family {
    case .accessoryCircular:
      LockSpentRingView(model, showsAmounts: showsAmounts)
        .containerBackground(for: .widget) { AccessoryWidgetBackground() }
        .widgetURL(WidgetLink.home.url)
    case .accessoryRectangular:
      LockSpentRectView(model, showsAmounts: showsAmounts)
        .padding(.horizontal, 14)
        .containerBackground(for: .widget) { AccessoryWidgetBackground() }
        .widgetURL(WidgetLink.home.url)
    default:
      if let model {
        GlanceCard(link: .home, fill: ink) { SpentSoFarWidgetView(model, hidden: entry.hidden) }
      } else {
        Waiting(title: "Spent so far", sentence: entry.firstSentence, link: .home)
      }
    }
  }
}

struct SpentSoFarHomeWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "SpentSoFar", provider: GlanceProvider()) { SpentSoFarEntryView(entry: $0) }
      .configurationDisplayName("Spent so far")
      .description("The Home hero, anywhere: spent on needs and wants against the plan.")
      .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular])
      .contentMarginsDisabled()
  }
}

struct BudgetPaceEntryView: View {
  let entry: GlanceEntry

  var body: some View {
    if let model = entry.snapshot?.budgetPace {
      GlanceCard(link: .plan, fill: light) { BudgetPaceWidgetView(model, hidden: entry.hidden) }
    } else {
      Waiting(title: "Budget pace", sentence: entry.firstSentence, link: .plan)
    }
  }
}

struct BudgetPaceHomeWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "BudgetPace", provider: GlanceProvider()) { BudgetPaceEntryView(entry: $0) }
      .configurationDisplayName("Budget pace")
      .description("Needs, Wants and Savings against the plan.")
      .supportedFamilies([.systemMedium])
      .contentMarginsDisabled()
  }
}

struct CategoryWatchEntryView: View {
  let entry: GlanceEntry

  var body: some View {
    if let model = entry.snapshot?.category(entry.selection) {
      GlanceCard(link: .category(model.id), fill: light) { CategoryWatchWidgetView(model, hidden: entry.hidden) }
    } else {
      Waiting(title: "Category watch", sentence: entry.snapshot == nil ? entry.firstSentence : WaitingCopy.category,
              link: .plan)
    }
  }
}

struct CategoryWatchHomeWidget: Widget {
  var body: some WidgetConfiguration {
    AppIntentConfiguration(kind: "CategoryWatch", intent: CategoryWatchIntent.self, provider: CategoryProvider()) {
      CategoryWatchEntryView(entry: $0)
    }
    .configurationDisplayName("Category watch")
    .description("Any category you pick: what's left and what a day fits.")
    .supportedFamilies([.systemSmall])
    .contentMarginsDisabled()
  }
}

struct NextBillEntryView: View {
  let entry: GlanceEntry

  var body: some View {
    if let model = entry.snapshot?.nextBill {
      GlanceCard(link: .bills, fill: light) { NextBillWidgetView(model, hidden: entry.hidden) }
    } else {
      Waiting(title: "Next bill", sentence: entry.snapshot == nil ? entry.firstSentence : WaitingCopy.bill,
              link: .bills)
    }
  }
}

struct NextBillHomeWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "NextBill", provider: GlanceProvider()) { NextBillEntryView(entry: $0) }
      .configurationDisplayName("Next bill")
      .description("The next bill Hasala found, and when it's due.")
      .supportedFamilies([.systemSmall])
      .contentMarginsDisabled()
  }
}

struct NetWorthEntryView: View {
  let entry: GlanceEntry

  var body: some View {
    if let model = entry.snapshot?.netWorth {
      GlanceCard(link: .accounts, fill: ink) { NetWorthWidgetView(model, hidden: entry.hidden) }
    } else {
      Waiting(title: "Net worth", sentence: entry.stale ? WaitingCopy.stale : WaitingCopy.netWorth, link: .home)
    }
  }
}

struct NetWorthHomeWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "NetWorth", provider: GlanceProvider()) { NetWorthEntryView(entry: $0) }
      .configurationDisplayName("Net worth")
      .description("Your accounts together, after your first check-in.")
      .supportedFamilies([.systemSmall])
      .contentMarginsDisabled()
  }
}

struct ComingUpEntryView: View {
  let entry: GlanceEntry

  var body: some View {
    if let model = entry.snapshot?.comingUp {
      GlanceCard(link: .bills, fill: light) { ComingUpWidgetView(model, hidden: entry.hidden) }
    } else {
      Waiting(title: "Coming up", sentence: entry.snapshot == nil ? entry.firstSentence : WaitingCopy.bill,
              link: .bills)
    }
  }
}

struct ComingUpHomeWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "ComingUp", provider: GlanceProvider()) { ComingUpEntryView(entry: $0) }
      .configurationDisplayName("Coming up")
      .description("Bills and salary for the next 14 days.")
      .supportedFamilies([.systemMedium])
      .contentMarginsDisabled()
  }
}

struct ProjectEntryView: View {
  let entry: GlanceEntry

  var body: some View {
    if let model = entry.snapshot?.project(entry.selection) {
      GlanceCard(link: .plan, fill: light) { ProjectWidgetView(model, hidden: entry.hidden) }
    } else {
      Waiting(title: "Project", sentence: sentence, link: .plan)
    }
  }

  private var sentence: String {
    if entry.stale { return WaitingCopy.stale }
    return entry.snapshot?.projects.isEmpty == false ? WaitingCopy.projectGone : WaitingCopy.project
  }
}

struct ProjectHomeWidget: Widget {
  var body: some WidgetConfiguration {
    AppIntentConfiguration(kind: "Project", intent: ProjectWidgetIntent.self, provider: ProjectProvider()) {
      ProjectEntryView(entry: $0)
    }
    .configurationDisplayName("Project")
    .description("A project, once it starts: what's left of its budget.")
    .supportedFamilies([.systemSmall])
    .contentMarginsDisabled()
  }
}

struct GoalEntryView: View {
  let entry: GlanceEntry

  var body: some View {
    if let model = entry.snapshot?.goal(entry.selection) {
      GlanceCard(link: .plan, fill: AnyShapeStyle(Hue.mint.perceptualGradient)) {
        GoalWidgetView(model, hidden: entry.hidden)
      }
    } else {
      Waiting(title: "Goal", sentence: sentence, link: .plan)
    }
  }

  private var sentence: String {
    if entry.stale { return WaitingCopy.stale }
    return entry.snapshot?.goals.isEmpty == false ? WaitingCopy.goalGone : WaitingCopy.goal
  }
}

struct GoalHomeWidget: Widget {
  var body: some WidgetConfiguration {
    AppIntentConfiguration(kind: "Goal", intent: GoalWidgetIntent.self, provider: GoalProvider()) {
      GoalEntryView(entry: $0)
    }
    .configurationDisplayName("Goal")
    .description("A savings target with a date.")
    .supportedFamilies([.systemSmall])
    .contentMarginsDisabled()
  }
}

struct ToReviewEntryView: View {
  @Environment(\.widgetFamily) private var family
  let entry: GlanceEntry

  var body: some View {
    let model = entry.snapshot?.toReview
    switch family {
    case .accessoryCircular:
      LockReviewCircleView(model)
        .containerBackground(for: .widget) { AccessoryWidgetBackground() }
        .widgetURL(WidgetLink.review.url)
    default:
      if let model {
        GlanceCard(link: .review, fill: AnyShapeStyle(Hue.sky.perceptualGradient)) {
          ToReviewWidgetView(model, hidden: entry.hidden)
        }
      } else {
        Waiting(title: "To review", sentence: entry.firstSentence, link: .review)
      }
    }
  }
}

struct ToReviewHomeWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "ToReview", provider: GlanceProvider()) { ToReviewEntryView(entry: $0) }
      .configurationDisplayName("To review")
      .description("Transactions to sort. Opens the review deck.")
      .supportedFamilies([.systemSmall, .accessoryCircular])
      .contentMarginsDisabled()
  }
}

struct TodayEntryView: View {
  let entry: GlanceEntry

  var body: some View {
    if let model = entry.snapshot?.today {
      GlanceCard(link: .activity, fill: light) { TodayWidgetView(model, hidden: entry.hidden) }
    } else {
      Waiting(title: "Today", sentence: entry.firstSentence, link: .activity)
    }
  }
}

struct TodayHomeWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "Today", provider: GlanceProvider()) { TodayEntryView(entry: $0) }
      .configurationDisplayName("Today")
      .description("The day's transactions as they arrive.")
      .supportedFamilies([.systemMedium])
      .contentMarginsDisabled()
  }
}
