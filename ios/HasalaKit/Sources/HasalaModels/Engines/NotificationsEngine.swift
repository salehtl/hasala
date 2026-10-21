// Home · Notifications (Paper 11Y9-0, 12AC-0; spec 10 §4, page 15 §15.2, page 18 §14): what
// needs a look, from the ledger. The bell on every tab counts these items; its large sheet lists
// them newest first under "Needs a look". Notifications never follow the period; the review item counts the deck it opens.
//
// The mailbox item ("Connect your email", "Sign in again to …") comes from the mail lane, not
// the ledger, so the app appends it (`HomeViewModel`). "Earlier" needs a notification history
// that doesn't exist yet: only a Debug feed draws it (plan B7.6, decision 12).

/// Where a notification row goes when tapped (spec 10 §4.4: "Tapping an item opens its screen").
public enum NotificationDestination: Sendable, Hashable {
  /// The review deck, over the Review tab.
  case review
  /// One bill (Bills · AXA Insurance): one that may be late, or a new price to accept or check.
  case bill(BillID)
  /// Bills · Coming up and found (a found bill).
  case bills
  /// A category's detail in Plan ("Groceries is running fast").
  case category(CategoryID)
  /// Profile › Bank alerts (connect, sign in again, a quiet bank).
  case bankAlerts
  case unreadMail
}

/// One row of the Notifications sheet (page 15 §15.2 NotificationRow): a 40 disc in the item's
/// hue, the title, one supporting line (optionally after a status dot), and when it happened.
public struct NotificationItem: Sendable, Hashable, Identifiable {
  /// The leading disc: a hue with its ink glyph, or the neutral grey plate (a mailbox, a bank).
  public enum Disc: Sendable, Hashable {
    case hue(Hue, Glyph)
    case neutral(Glyph)
  }

  /// "review", "bill.axa", "price.du", "found.apple-bill", "mail.connect" (`bell.row.<id>`).
  public var id: String
  public var disc: Disc
  /// Names the thing, as a push with details on does: "AXA Insurance may be late".
  public var title: String
  /// "Usually on the 7th · no email yet"; amounts in it hide with the eye.
  public var line: MoneyPhrase
  /// A 7 dot before the line: red for a bill that may be late, green for a fixed problem.
  public var status: StatusTone?
  /// "Today", "Thu", "28 Sep", "9:12"; nil when the item has no moment of its own.
  public var when: String?
  public var destination: NotificationDestination

  public init(
    id: String, disc: Disc, title: String, line: MoneyPhrase, status: StatusTone? = nil, when: String?,
    destination: NotificationDestination
  ) {
    self.id = id
    self.disc = disc
    self.title = title
    self.line = line
    self.status = status
    self.when = when
    self.destination = destination
  }
}

/// The ledger's "Needs a look" list, newest first. Its count is the bell's badge (Maya: 4).
public struct NotificationsSnapshot: Sendable, Hashable {
  public var needsALook: [NotificationItem]

  public init(needsALook: [NotificationItem]) {
    self.needsALook = needsALook
  }

  public var count: Int { needsALook.count }
}

public enum NotificationsEngine {
  public static func snapshot(_ s: LedgerState, now: LocalDateTime, review window: ReviewWindow = .all)
    -> NotificationsSnapshot
  {
    let today = now.date
    // Items in the order the plan lists their kinds; the sort below is stable, so items of
    // the same day keep it: transactions to sort, late bills, new prices, found bills.
    var dated: [(date: LocalDate, item: NotificationItem)] = []

    // Transactions to sort: one item for the deck it opens, the same queue in the same window.
    let queue = ReviewEngine.queue(s, in: window)
    if !queue.isEmpty {
      let newest = queue.map(\.postedAt.date).max() ?? today
      let unplanned = Fils.sum(queue.filter { $0.direction == .out && !$0.isHeldCopy }) { $0.homeMinor ?? 0 }
      dated.append((newest, NotificationItem(
        id: "review", disc: .hue(.sky, .review),
        title: "\(queue.count) transaction\(queue.count == 1 ? "" : "s") to sort",
        line: MoneyPhrase([.text("AED "), .amount(.aed(unplanned), hidden: 3), .text(" still to check")]),
        when: when(newest, today: today), destination: .review
      )))
    }

    let unread = ReviewEngine.unreadMail(s)
    if let newest = unread.first {
      dated.append((newest.receivedOn, NotificationItem(
        id: "unread", disc: .neutral(.envelope), title: ReviewEngine.unreadLine(unread.count),
        line: "Add each one by hand or dismiss it", when: when(newest.receivedOn, today: today), destination: .unreadMail
      )))
    }

    let tracked = s.bills.filter { $0.state == .tracked && !$0.isIncome }

    // A bill may be late from the day after it was due with no payment read. Hasala can't
    // know for sure, so it never says "is late" (page 18 §14).
    for b in tracked.filter({ $0.nextDue < today }).sorted(by: { $0.nextDue < $1.nextDue }) {
      let since = b.nextDue.adding(days: 1)
      let c = s.category(b.categoryID)
      dated.append((since, NotificationItem(
        id: "bill.\(b.id)", disc: .hue(c?.hue ?? .sand, c?.glyph ?? .bill),
        title: "\(b.name) may be late",
        line: MoneyPhrase(stringLiteral: "Usually on the \(PlanEngine.ordinal(b.usualDay)) · no email yet"),
        status: .error, when: when(since, today: today), destination: .bill(b.id)
      )))
    }

    // A tracked bill charged outside its usual amount: accept the new price or check it, on the bill.
    for b in tracked {
      guard let usual = b.priceChangeFrom else { continue }
      let charged = b.history.first ?? today
      let c = s.category(b.categoryID)
      dated.append((charged, NotificationItem(
        id: "price.\(b.id)", disc: .hue(c?.hue ?? .sand, c?.glyph ?? .bill),
        title: "\(b.name) has a new price",
        line: MoneyPhrase([
          .amount(b.amount, hidden: 3), .text(" from "), .amount(usual, hidden: 3), .text(" · accept or check"),
        ]),
        when: when(charged, today: today), destination: .bill(b.id)
      )))
    }

    // A merchant that repeats on a steady rhythm: track it, in Bills.
    for c in s.billCandidates {
      let cat = s.category(c.categoryID)
      dated.append((c.last, NotificationItem(
        id: "found.\(c.id)", disc: .hue(cat?.hue ?? .lilac, .subscriptions),
        title: "Found a bill: \(c.name)",
        line: MoneyPhrase(stringLiteral: "Seen \(c.seenCount)× · every ~\(c.everyDays) days"),
        when: when(c.last, today: today), destination: .bills
      )))
    }

    // Newest first; a stable sort keeps the kind order within a day.
    let ordered = dated.enumerated().sorted { a, b in
      a.element.date == b.element.date ? a.offset < b.offset : b.element.date < a.element.date
    }
    return NotificationsSnapshot(needsALook: ordered.map(\.element.item))
  }

  /// When something happened, as the sheet writes it (page 06 §6.6): "Today", "Yesterday", the
  /// weekday within the week ("Thu"), then the day and month ("28 Sep").
  public static func when(_ date: LocalDate, today: LocalDate) -> String {
    let days = date.days(until: today)
    switch days {
    case ...0: return "Today"
    case 1: return "Yesterday"
    case 2...6: return date.weekdayShort
    default: return date.dayMonth
    }
  }
}
