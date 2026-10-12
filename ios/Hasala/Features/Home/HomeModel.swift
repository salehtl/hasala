import HasalaModels
import Observation

/// Pushed destinations from Home (spec 04 §13.2).
enum HomeRoute: Hashable {
  case insights, needsYou, notifications, widget(String), editWidgets, bills
}

/// Home · Default (spec 04 §15.1 `HomeModel`, §16.1 "Home · Default").
@MainActor
protocol HomeModel: AnyObject, Observable {
  var snapshot: HomeSnapshot { get }
  var hidden: Bool { get }
  /// A Needs-you card's primary ("Start", "I paid it") or secondary ("Later", "Details")
  /// action; returns a screen to push, if any.
  func needsYou(_ card: String, primary: Bool) -> HomeRoute?
  /// A widget tap; returns a screen to push, if any.
  func openWidget(_ id: String) -> HomeRoute?
  /// Whether tapping the widget leads anywhere in this build (`BuildSurface`): a Release
  /// build doesn't make a widget tappable when its detail screen isn't built yet.
  func widgetOpens(_ id: String) -> Bool
}

@MainActor
@Observable
final class HomeViewModel: HomeModel {
  private let app: AppModel

  init(app: AppModel) { self.app = app }

  var snapshot: HomeSnapshot {
    var snap = app.snapshot
    snap.needsYou.cards.removeAll { app.snoozed.contains($0.id) }
    return snap
  }

  var hidden: Bool { app.amountsHidden }

  func needsYou(_ card: String, primary: Bool) -> HomeRoute? {
    if card == "review" {
      if primary { app.startReview() } else { app.snooze(card) }
      return nil
    }
    if card.hasPrefix("bill.") {
      let bill = String(card.dropFirst("bill.".count))
      if primary {
        // TODO(spec 04 §16.2 B1): FindPaymentSheet links the payment that arrived.
        app.perform(.markBillPaid(bill))
        return nil
      }
      // TODO(spec 04 §16.1 "Bill detail"): BillDetailView; Bills shows the bill meanwhile.
      return .bills
    }
    return .needsYou
  }

  func openWidget(_ id: String) -> HomeRoute? {
    switch id {
    case "budgetPace":
      app.tab = .plan
      return nil
    case "today":
      app.tab = .activity
      return nil
    case "nextBill":
      return .bills
    default:
      // TODO(spec 04 §16.1 "Accounts", "Project detail", §16.2 P4): Accounts, Project and Goal detail.
      return .widget(id)
    }
  }

  /// The widgets with a built destination: Plan, Activity and Bills.
  static let widgetsWithDestinations: Set<String> = ["budgetPace", "today", "nextBill"]

  func widgetOpens(_ id: String) -> Bool {
    BuildSurface.showsUnfinished || Self.widgetsWithDestinations.contains(id)
  }
}
