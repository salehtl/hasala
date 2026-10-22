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
  func detail(_ bill: BillID) -> BillDetail?
  func setRange(_ range: BillsSnapshot.Range)
  func markPaid(_ bill: BillID)
  func remind(_ bill: BillID)
  func acceptAmount(_ bill: BillID)
  func stopTracking(_ bill: BillID)
  func track(_ candidate: String)
  func dismiss(_ candidate: String)
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
      BillsEngine.snapshot(app.store.state, now: app.store.now, range: range)
    }
  }
  var hidden: Bool { app.amountsHidden }

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
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button { sheet = .add } label: {
          HIconView(.add, size: HSpacing.iconGlass, color: HColor.iconGlass, strokeWidth: 2.3)
        }
        .accessibilityLabel("Add recurring")
        .accessibilityIdentifier("bills.add")
      }
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
      if let income = snap.income {
        let line = HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text(income.label).hType(.subheadline.weight(.semibold))
          MoneyText(income.amount, figure: .compact, hidden: model.hidden, hiddenGlyphs: 3, color: HColor.moneyIn,
                    sign: .income)
          Text(income.expected).hType(.subheadline)
        }
        Group {
          if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 2) { line }
          } else {
            line
          }
        }
        .foregroundStyle(HColor.moneyIn)
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
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

  /// On a poster, insurance draws the plain shield (Paper's AXA card) and a phone or internet
  /// bill the wifi arcs (du's card, spec 13 B1); rows and the bill's own hero keep the
  /// category's glyph (the shield with its tick, du's bolt). Live bills are named by their
  /// category ("Utilities"), so there du keeps the bolt.
  static func posterGlyph(_ item: BillAttention) -> PosterGlyph {
    if item.glyph == .insurance { return .icon(.shield) }
    if item.glyph == .utilities, isConnectivity(item.billKind) { return .wifi }
    return .icon(item.glyph.icon)
  }

  private static func isConnectivity(_ kind: String) -> Bool {
    let words = kind.lowercased()
    return ["internet", "mobile", "phone", "telecom", "broadband"].contains { words.contains($0) }
  }

  // MARK: Found in your history

  private var found: some View {
    VStack(alignment: .leading, spacing: 12) {
      HSectionHeader("Found in your history")
      ForEach(snap.found) { candidate in
        BillCard(
          hue: .sky, glyph: .icon(.subscriptions), name: candidate.name,
          pill: StatusPill("New bill found", tone: .accent),
          amount: candidate.amount, caption: "every month", message: nil, hidden: model.hidden,
          primary: .init(title: "Track this bill", id: "bills.track.\(candidate.id)") { model.track(candidate.id) },
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
      } else {
        rows(snap.upcoming)
      }
    }
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
          BillsListRow(row: row, tag: snap.tags[row.id], hidden: model.hidden)
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
