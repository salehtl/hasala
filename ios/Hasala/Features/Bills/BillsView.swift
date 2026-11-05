import HasalaDesign
import HasalaModels
import Observation
import SwiftUI

#if HASALA_MOCKS
  import HasalaMocks
#endif

/// Bills · Coming up and found (Paper 1K9-0) and one bill (Bills · AXA Insurance (late)).
@MainActor
protocol BillsModel: AnyObject, Observable {
  var snapshot: BillsSnapshot { get }
  var hidden: Bool { get }
  var holdsLate: Bool { get }
  var next14Estimates: Int { get }
  var incomeInNext14: Bool { get }
  func detail(_ bill: BillID) -> BillDetail?
  func setRange(_ range: BillsSnapshot.Range)
  func markPaid(_ bill: BillID)
  func remind(_ bill: BillID)
  func acceptAmount(_ bill: BillID)
  func stopTracking(_ bill: BillID)
  func track(_ candidate: String)
  func dismiss(_ candidate: String)
  func openPayment(_ txn: TxnID)
  @discardableResult func perform(_ edit: LedgerEdit) -> Bool
}

@MainActor
@Observable
final class BillsViewModel: BillsModel {
  private let app: AppModel
  private var range: BillsSnapshot.Range = .month
  @ObservationIgnored private var memo = Memo<[AnyHashable], BillsSnapshot>()

  init(app: AppModel) { self.app = app }

  var snapshot: BillsSnapshot {
    memo.value(for: [app.store.revision, range]) {
      Self.held(BillsEngine.snapshot(app.store.state, now: app.store.now, range: range),
                holdsLate: app.store.state.reading?.holdsLateBills == true)
    }
  }

  var holdsLate: Bool { app.store.state.reading?.holdsLateBills == true }

  static func held(_ snap: BillsSnapshot, holdsLate: Bool) -> BillsSnapshot {
    guard holdsLate else { return snap }
    var out = snap
    out.needsALook = snap.needsALook.filter { if case .late = $0.kind { false } else { true } }
    return out
  }
  var hidden: Bool { app.amountsHidden }
  var next14Estimates: Int { Self.estimatesDue(app.store.state, now: app.store.now) }
  var incomeInNext14: Bool { Self.incomeDue(app.store.state, now: app.store.now) }

  static func estimatesDue(_ s: LedgerState, now: LocalDateTime) -> Int {
    let in14 = now.date.adding(days: 14)
    return s.bills.filter { $0.state == .tracked && !$0.isIncome && $0.approximate && $0.nextDue <= in14 }.count
  }

  static func incomeDue(_ s: LedgerState, now: LocalDateTime) -> Bool {
    let today = now.date
    let next = s.bills.filter { $0.state == .tracked && $0.isIncome && $0.nextDue >= today }
      .min { $0.nextDue < $1.nextDue }
    return next.map { $0.nextDue <= today.adding(days: 14) } ?? false
  }

  static func estimatesCaption(_ n: Int) -> String? {
    n <= 0 ? nil : n == 1 ? "Includes 1 estimate" : "Includes \(n) estimates"
  }

  func detail(_ bill: BillID) -> BillDetail? {
    BillsEngine.detail(app.store.state, now: app.store.now, bill: bill)
  }

  func setRange(_ range: BillsSnapshot.Range) { self.range = range }

  // TODO(spec 04 §16.2 B1): "I paid it" opens FindPaymentSheet to link the payment; for now
  // it marks this occurrence paid (`bill_occurrence_set{paid}`), with Undo.
  func markPaid(_ bill: BillID) { app.perform(.markBillPaid(bill)) }

  // TODO(03b §3.3): "Remind me tomorrow" snoozes the occurrence (`bill_occurrence_set` snooze)
  // and plans a local notification (spec 04 §9).
  // Debug only: a Release build doesn't show "Remind me" (`BuildSurface`).
  func remind(_ bill: BillID) { app.say("Reminders aren't in this build yet", icon: .bell) }

  func acceptAmount(_ bill: BillID) { app.perform(.acceptBillAmount(bill)) }
  func stopTracking(_ bill: BillID) { app.perform(.stopTrackingBill(bill)) }
  func track(_ candidate: String) { app.perform(.trackCandidate(candidate)) }
  func dismiss(_ candidate: String) { app.perform(.dismissCandidate(candidate)) }
  func openPayment(_ txn: TxnID) { app.open(txn) }
  @discardableResult func perform(_ edit: LedgerEdit) -> Bool { app.perform(edit) }
}

/// Recurring, pushed from Home (the Next bill widget) and Profile › Recurring: the next 14 days, the bills
/// that need a decision, the ones found in the history, what's coming and what's been paid.
/// A row or "Details" opens the bill, on the stack the list is in.
struct BillsView: View {
  @Bindable var app: AppModel
  let model: any BillsModel
  /// Off inside the profile sheet, which hosts the toast itself (the page reads the sheet's
  /// environment too; this stays for the frozen `BillsScreen` initializer).
  var showsToast = true
  @Environment(\.inProfileSheet) private var inProfileSheet
  @Environment(\.dynamicTypeSize) private var typeSize
  @State private var sheet: RecurringSheet?
  @State private var showsEnded = false

  private var snap: BillsSnapshot { model.snapshot }
  private var unfinished: Bool { BuildSurface.showsUnfinished }

  var body: some View {
    // Sand while bills are due or need a look (Paper "Ambient wash · Bills due"); sky when
    // nothing is.
    PushedPage(app: app, title: "Recurring", wash: snap.next14.isZero && snap.needsALook.isEmpty ? .onTrack : .overPace,
               spacing: 28, top: 12) {
      hero.padding(.horizontal, HSpacing.insetPage)
      if !snap.needsALook.isEmpty { needsALook.padding(.horizontal, HSpacing.insetPage) }
      if !snap.found.isEmpty { found.padding(.horizontal, HSpacing.insetPage) }
      upcoming.padding(.horizontal, HSpacing.insetPage)
      if !snap.paused.isEmpty { paused.padding(.horizontal, HSpacing.insetPage) }
      if !snap.recentlyPaid.isEmpty { recentlyPaid.padding(.horizontal, HSpacing.insetPage) }
      if !snap.ended.isEmpty { ended.padding(.horizontal, HSpacing.insetPage) }
    }
    .sheet(item: $sheet) { RecurringSheetHost(app: app, sheet: $0) }
  }

  private func open(_ row: BillRowModel) {
    if row.isIncome {
      sheet = .salary(row.id)
    } else {
      open(row.id)
    }
  }

  private func open(_ bill: BillID) { app.router.openBill(bill, inProfileSheet: inProfileSheet) }

  private func rows(_ rows: [BillRowModel]) -> some View {
    HListCard {
      ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
        if index > 0 { HDivider(inset: .disc68) }
        Button { open(row) } label: { BillsListRow(row: row, hidden: model.hidden) }
          .buttonStyle(HRowPressStyle())
          .accessibilityIdentifier("bill.\(row.id)")
      }
    }
  }

  private var paused: some View {
    VStack(alignment: .leading, spacing: 12) {
      HSectionHeader("Paused", trailing: .fact("\(snap.paused.count)"))
      rows(snap.paused)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("bills.section.paused")
  }

  private var ended: some View {
    VStack(alignment: .leading, spacing: 12) {
      Button {
        withAnimation(.easeInOut(duration: 0.2)) { showsEnded.toggle() }
      } label: {
        HStack(spacing: 8) {
          Text("Ended").hType(.section).foregroundStyle(HColor.textPrimary)
          CountBadge(snap.ended.count, style: .title24)
          Spacer(minLength: 8)
          HIconView(showsEnded ? .chevronUp : .chevronDown, size: HSpacing.iconSmall, color: HColor.textLink)
        }
        .frame(minHeight: HSpacing.targetMinimum)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Ended, \(snap.ended.count)")
      .accessibilityValue(showsEnded ? "Shown" : "Hidden")
      .accessibilityAddTraits(.isHeader)
      .accessibilityIdentifier("bills.ended.toggle")
      if showsEnded { rows(snap.ended) }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("bills.section.ended")
  }

  // MARK: Next 14 days

  /// "NEXT 14 DAYS / AED 1,039.15 to pay / Salary +25,000.00 expected Wed 28 Oct".
  private var hero: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Next 14 days").hType(.overline).foregroundStyle(HColor.textOnWashSecondary)
        .accessibilityAddTraits(.isHeader)
      let figure = MoneyText(snap.next14, figure: .hero, unit: .unit, hidden: model.hidden, hiddenGlyphs: 6,
                             color: HColor.textPrimary)
        .accessibilityIdentifier("bills.next14")
      let toPay = Text("to pay").hType(.body).foregroundStyle(HColor.textOnWashSecondary)
      if typeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 2) { figure; toPay }
      } else {
        HStack(alignment: .firstTextBaseline, spacing: 8) { figure; toPay }
      }
      if let income = snap.income, model.incomeInNext14 {
        let label = Text(income.label).hType(.subheadline.weight(.semibold))
        let amount = MoneyText(income.amount, figure: .compact, hidden: model.hidden, hiddenGlyphs: 3,
                               color: HColor.moneyIn, sign: .income)
        let expected = Text(income.expected).hType(.subheadline)
        Group {
          if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 2) {
              ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 6) { label; amount.fixedSize() }
                VStack(alignment: .leading, spacing: 2) { label; amount }
              }
              expected
            }
          } else {
            HStack(alignment: .firstTextBaseline, spacing: 6) { label; amount; expected }
          }
        }
        .foregroundStyle(HColor.moneyIn)
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
      }
      if let caption = BillsViewModel.estimatesCaption(model.next14Estimates) {
        Text(caption).hType(.footnote).foregroundStyle(HColor.textOnWashSecondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("bills.next14.estimates")
      }
      if let mark = snap.next14Mark, let line = mark.line {
        NotCountedLine(mark, line: line, id: "bills.next14.notCounted", inProfileSheet: inProfileSheet, app: app)
      }
    }
  }

  // MARK: Needs a look

  private var needsALook: some View {
    VStack(alignment: .leading, spacing: 12) {
      HSectionHeader("Needs a look", trailing: .count(snap.needsALook.count))
      ForEach(snap.needsALook) { item in attentionCard(item) }
    }
  }

  /// A bill that may be late (rose: "I paid it", and "Remind me" in Debug) or that changed
  /// price (sand: "Accept new amount", "Details" opens the bill).
  private func attentionCard(_ item: BillAttention) -> some View {
    let isLate = if case .late = item.kind { true } else { false }
    let secondary: BillCard<EmptyView>.Action? = isLate
      ? (unfinished ? .init(title: "Remind me", id: "bills.remind.\(item.id)") { model.remind(item.id) } : nil)
      : .init(title: "Details", id: "bills.details.\(item.id)") { open(item.id) }
    return BillCard(
      hue: isLate ? .rose : .sand, glyph: Self.posterGlyph(item), name: item.name, pill: item.pill,
      amount: item.amount, message: item.body, hidden: model.hidden,
      primary: isLate
        ? .init(title: "I paid it", id: "bills.paid.\(item.id)") { model.markPaid(item.id) }
        : .init(title: "Accept new amount", id: "bills.accept.\(item.id)") { model.acceptAmount(item.id) },
      secondary: secondary, id: "bills.attention.\(item.id)")
  }

  static func posterGlyph(_ item: BillAttention) -> PosterGlyph { .icon(item.glyph.icon) }

  // MARK: Found in your history

  static let foundPill = "Looks recurring"
  static let trackTitle = "Track it"

  private var found: some View {
    VStack(alignment: .leading, spacing: 12) {
      HSectionHeader("Found in your history")
      ForEach(snap.found) { candidate in
        BillCard(
          hue: .sky, glyph: .icon(.subscriptions), name: candidate.name,
          pill: StatusPill(Self.foundPill, tone: .accent),
          amount: candidate.amount, caption: "every month", message: nil, hidden: model.hidden,
          primary: .init(title: Self.trackTitle, id: "bills.track.\(candidate.id)") { model.track(candidate.id) },
          secondary: .init(title: "Dismiss", id: "bills.dismiss.\(candidate.id)") { model.dismiss(candidate.id) },
          id: "bills.found.\(candidate.id)"
        ) {
          VStack(alignment: .leading, spacing: 12) {
            FlowLayout(spacing: 6) {
              ForEach(candidate.evidence, id: \.self) { InfoChip($0, style: .evidence) }
            }
            .accessibilityElement(children: .combine)
            if unfinished {
              // TODO(spec 04 §16.2 B1): the payments the detector saw.
              Button { app.say("The payments list comes in a later build", icon: .receipt) } label: {
                HStack(spacing: 2) {
                  Text("See the \(candidate.seenCount) payments").hType(.subheadline.weight(.semibold))
                  HIconView(.chevronRight, size: HSpacing.iconSmall, color: HColor.textLink)
                }
                .foregroundStyle(HColor.textLink)
                .frame(minHeight: HSpacing.targetMinimum)
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              // Paper's link is 24 tall; the target is 44, 10 over each edge.
              .padding(.vertical, -10)
            }
          }
        }
      }
    }
  }

  // MARK: Upcoming

  private var upcoming: some View {
    VStack(alignment: .leading, spacing: 12) {
      // TODO(spec 04 §16.2 B1): "All schedules · N ›" opens AllSchedulesView (Debug only until
      // it exists); a Release build says how many bills are tracked instead.
      if unfinished {
        ReflowingRow(alignment: .firstTextBaseline) {
          Text("Upcoming").hType(.section).foregroundStyle(HColor.textPrimary).accessibilityAddTraits(.isHeader)
        } trailing: {
          allSchedules
        }
      } else {
        HSectionHeader("Upcoming", trailing: .fact("\(snap.tracked) tracked"))
      }
      HStack(spacing: 8) {
        ForEach(BillsSnapshot.Range.allCases) { r in
          FilterChip(r.title, selected: snap.range == r) { model.setRange(r) }
            .accessibilityIdentifier("bills.range.\(r.rawValue)")
        }
      }
      if snap.upcoming.isEmpty {
        EmptyNote(systemImage: "calendar", message: "Nothing due in the next \(snap.range.rawValue) days.")
      }
      HListCard {
        ForEach(Array(snap.upcoming.enumerated()), id: \.element.id) { index, row in
          if index > 0 { HDivider(inset: .disc68) }
          Button { open(row) } label: { BillsListRow(row: row, hidden: model.hidden) }
            .buttonStyle(HRowPressStyle())
            .accessibilityIdentifier("bill.\(row.id)")
        }
        if !snap.upcoming.isEmpty { HDivider(inset: .disc68) }
        addRow
      }
    }
  }

  private var addRow: some View {
    Button { sheet = .add } label: {
      HStack(spacing: HSpacing.listRowGap) {
        Circle().fill(HColor.actionAccentSubtle).frame(width: 40, height: 40)
          .overlay { HIconView(.add, size: 20, color: HColor.textLink, strokeWidth: 1.9) }
          .accessibilityHidden(true)
        Text("Add recurring").hType(.rowTitle).foregroundStyle(HColor.textLink)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.horizontal, HSpacing.listRowInsetInline)
      .padding(.vertical, HSpacing.listRowInsetBlock)
      .frame(minHeight: HSpacing.listRowMinHeightTwoLine)
      .contentShape(Rectangle())
    }
    .buttonStyle(HRowPressStyle())
    .accessibilityLabel("Add recurring")
    .accessibilityIdentifier("bills.add")
  }

  /// Paper 7U6-0 "Link · All schedules": 17/24 500 in the link colour, then the 16 chevron,
  /// 2 apart (the kit's section link draws neither the size nor the chevron). 44 tall.
  private var allSchedules: some View {
    Button { app.say("Every schedule comes in a later build", icon: .calendar) } label: {
      HStack(spacing: 2) {
        Text("All schedules · \(snap.tracked)").hType(.body.weight(.medium))
        HIconView(.chevronRight, size: HSpacing.iconSmall, color: HColor.textLink)
      }
      .foregroundStyle(HColor.textLink)
      .frame(minHeight: HSpacing.targetMinimum)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("All schedules, \(snap.tracked)")
    .accessibilityIdentifier("bills.allSchedules")
  }

  // MARK: Recently paid

  private var recentlyPaid: some View {
    VStack(alignment: .leading, spacing: 12) {
      ReflowingRow(alignment: .bottom) {
        Text("Recently paid").hType(.section).foregroundStyle(HColor.textPrimary).accessibilityAddTraits(.isHeader)
      } trailing: {
        PhraseText(MoneyPhrase([.amount(snap.paidThisMonth), .text(" in \(app.store.now.date.yearMonth.name)")]
                               + (snap.paidMark?.caption.map { [.text(" · \($0)")] } ?? [])),
                   hidden: model.hidden)
          .hType(.subheadline).foregroundStyle(HColor.textSecondary)
      }
      HListCard {
        ForEach(Array(snap.recentlyPaid.enumerated()), id: \.element.id) { index, row in
          if index > 0 { HDivider(inset: .disc68) }
          Button { model.openPayment(row.id) } label: {
            BillsListRow(row: row, tag: snap.tags[row.id], hidden: model.hidden)
          }
          .buttonStyle(HRowPressStyle())
          .accessibilityIdentifier("bills.recentlyPaid.\(row.id)")
        }
      }
    }
  }
}

#if HASALA_MOCKS
  #Preview("Bills") {
    let app = AppModel(store: InMemoryLedger())
    NavigationStack { BillsView(app: app, model: BillsViewModel(app: app)) }
  }
#endif
