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
    // A card put off with "Later" leaves the rail's count and subtitle as they were.
    if let offer = app.gmailOffer, !app.snoozed.contains(offer.cardID) {
      snap.needsYou = offer.adding(to: snap.needsYou)
    }
    snap.needsYou.cards.removeAll { app.snoozed.contains($0.id) }
    return snap
  }

  var hidden: Bool { app.amountsHidden }

  func needsYou(_ card: String, primary: Bool) -> HomeRoute? {
    if let offer = GmailOffer(cardID: card) {
      if primary { app.sheet = .connectGmail(offer) } else { app.snooze(card) }
      return nil
    }
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

/// Home's Gmail card (spec 04 §6.6 row 4: Gmail was skipped; §7.4: Google wants a new
/// sign-in), first in Needs you.
extension GmailOffer {
  var cardID: String { "gmail.\(rawValue)" }

  init?(cardID: String) {
    guard cardID.hasPrefix("gmail.") else { return nil }
    self.init(rawValue: String(cardID.dropFirst("gmail.".count)))
  }

  var card: NeedsYouCard {
    switch self {
    case .connect:
      NeedsYouCard(
        id: cardID, hue: .sky, glyph: .envelope, label: "Bank alerts",
        status: StatusPill("Not connected", tone: .warning), figure: .word("Gmail"),
        title: "Connect Gmail", subtitle: "Your bank alerts aren't read yet",
        primaryAction: "Connect", secondaryAction: "Later")
    case .reconnect:
      NeedsYouCard(
        id: cardID, hue: .rose, glyph: .envelope, label: "Bank alerts",
        status: StatusPill("Stopped", tone: .error), figure: .word("Gmail"),
        title: "Reconnect Gmail", subtitle: "New bank alerts aren't read",
        primaryAction: "Reconnect", secondaryAction: "Later")
    }
  }

  /// `rail` with this card first; "All caught up" no longer holds.
  func adding(to rail: NeedsYouRail) -> NeedsYouRail {
    var r = rail
    r.cards.insert(card, at: 0)
    r.count += 1
    if rail.cards.isEmpty { r.subtitle = status }
    return r
  }
}
