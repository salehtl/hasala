import HasalaDesign
import HasalaModels
import SwiftUI

#if HASALA_MOCKS
  import HasalaMocks
#endif

/// Activity · Overview (Paper 1QG-0, 15M3-0): the register. The title with Home's period pill and
/// "26 transactions this month" (another period: the tinted pill and "Back to this month", the
/// count under History), the filter chips, then To review, Coming up and History by
/// day. Every row opens the transaction sheet; a Coming up row pushes its bill. A category
/// filter turns it into Activity · Filtered (7LT-0): the category's chip, its pace, and its
/// rows in one card.
struct ActivityView: View {
  @Bindable var app: AppModel
  let model: any ActivityModel

  var body: some View {
    NavigationStack(path: Bindable(app.router).activity) {
      TabScreen(app: app, title: "Activity", extra: .add,
                onExtra: { model.addTransaction() }) {
        ActivityFilterBar(model: model)
      } content: {
        ActivityContent(model: model, showsChips: false)
      }
      .searchable(
        text: Binding(get: { model.searchText }, set: { model.search($0) }),
        placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search transactions"
      )
      .navigationDestination(for: ActivityRoute.self) { route in
        switch route {
        case .bill(let id): BillDetailView(app: app, bill: id)
        }
      }
    }
    .onAppear(perform: takeRequest)
    .onChange(of: ActivityRequests.shared.pending?.filter) { takeRequest() }
  }

  /// A filter asked for from elsewhere (Search's rows, a Debug launch).
  private func takeRequest() {
    if let filter = ActivityRequests.shared.take(for: app) { model.apply(filter) }
  }
}

/// What sits under the large title: the period row and the chips (overview), or the period
/// pill and the category's own chip (filtered). The chips run to the screen's edge and scroll
/// sideways from the 20 inset.
struct ActivityFilterBar: View {
  let model: any ActivityModel

  private var snap: ActivitySnapshot { model.snapshot }

  var body: some View {
    if let summary = snap.summary, let category = snap.filter.category {
      VStack(alignment: .leading, spacing: 16) {
        periodRow
        ActiveFilterChip(title: summary.title, hue: summary.hue) { model.show(category: nil) }
          .accessibilityIdentifier("activity.filter.\(category)")
      }
    } else {
      VStack(alignment: .leading, spacing: 20) {
        periodRow
        chips
          .padding(.horizontal, -HSpacing.insetPage)
      }
    }
  }

  private var pill: some View {
    PeriodPill(snap.period.title, tinted: !snap.isThisMonth) { model.choosePeriod() }
      .accessibilityIdentifier("activity.period")
  }

  @ViewBuilder private var periodRow: some View {
    if snap.isThisMonth {
      HStack(spacing: 12) {
        pill
        if snap.summary == nil {
          Text(snap.countLine)
            .hType(.subheadline)
            .foregroundStyle(HColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("activity.count")
        }
      }
    } else {
      ReflowingRow(spacing: 12) {
        pill
      } trailing: {
        Button { model.backToThisMonth() } label: {
          Text("Back to this month")
            .hType(.subheadline.weight(.medium))
            .foregroundStyle(HColor.textLink)
            .frame(minHeight: HSpacing.targetMinimum)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("activity.backToThisMonth")
      }
    }
  }

  /// All · To review (accent count) · Bills (plain count) · Transfers · Income · Archived.
  private var chips: some View {
    ScrollView(.horizontal) {
      HStack(spacing: HSpacing.chipGap) {
        ForEach(snap.chips) { chip in
          FilterChip(chip.kind.title, count: chip.count.flatMap { $0 > 0 ? $0 : nil },
                     countStyle: chip.accentCount ? .accent : .plain,
                     selected: snap.filter.kind == chip.kind) { model.select(chip.kind) }
            .accessibilityIdentifier("activity.chip.\(chip.kind.rawValue)")
        }
      }
      .padding(.horizontal, HSpacing.insetPage)
      // The chips' 44 hit areas reach past their 40 drawing; keep them inside the scroller.
      .padding(.vertical, 2)
    }
    .scrollIndicators(.hidden)
  }
}

/// The ink chip of an applied category filter: its bucket dot, the name and a clear ×
/// (Paper "Active filters": 40 tall, 14 / 12, gap 7).
struct ActiveFilterChip: View {
  let title: String
  let hue: Hue
  let clear: () -> Void

  var body: some View {
    Button(action: clear) {
      HStack(spacing: 7) {
        Circle().fill(hue.dotGradient).frame(width: 8, height: 8)
        Text(title).hType(.smallButton).foregroundStyle(HColor.chipTextSelected)
        HIconView(.close, size: 16, color: HColor.widgetOnInverseSecondary, strokeWidth: 2.4)
      }
      .padding(.leading, 14)
      .padding(.trailing, 12)
      .frame(minHeight: HSpacing.chipHeight)
      .background(HColor.chipSurfaceSelected, in: Capsule())
      .contentShape(Capsule().inset(by: -2))
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Filtered by \(title)")
    .accessibilityHint("Shows every transaction again")
    .accessibilityAddTraits(.isSelected)
  }
}

/// The sections of Activity, shared by the overview and the filtered screen (and Plan's
/// category screen, which passes `showsChips: false` and a category filter).
struct ActivityContent: View {
  let model: any ActivityModel
  var showsChips = true

  private var snap: ActivitySnapshot { model.snapshot }

  var body: some View {
    VStack(alignment: .leading, spacing: HSpacing.gapScreenSection) {
      if showsChips {
        ActivityFilterBar(model: model).padding(.horizontal, HSpacing.insetPage)
      }
      if let summary = snap.summary {
        filtered(summary)
      } else {
        overview
      }
    }
  }

  // MARK: Overview

  @ViewBuilder private var overview: some View {
    if let review = snap.review {
      VStack(alignment: .leading, spacing: 12) {
        header("To review") {
          Text(Self.minutes(review.count)).hType(.subheadline).foregroundStyle(HColor.textSecondary)
        }
        ToReviewCard(review: review, hidden: model.hidden) { model.startReview() }
      }
      .padding(.horizontal, HSpacing.insetPage)
    }

    if !snap.comingUp.isEmpty {
      VStack(alignment: .leading, spacing: 12) {
        header("Coming up") {
          Text("next 7 days").hType(.subheadline).foregroundStyle(HColor.textSecondary)
        }
        HListCard {
          ForEach(Array(snap.comingUp.enumerated()), id: \.element.id) { i, row in
            if i > 0 { HDivider(inset: .disc68) }
            Button { model.openBill(row.id) } label: {
              BillRowView(row, hidden: model.hidden).contentShape(Rectangle())
            }
            .buttonStyle(HRowPressStyle())
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("bill.\(row.id)")
          }
        }
      }
      .padding(.horizontal, HSpacing.insetPage)
    }

    VStack(alignment: .leading, spacing: 12) {
      header(model.searchText.isEmpty ? "History" : "Results") {
        ExportLink(rows: model.exportRows, title: "Export")
      }
      if !snap.isThisMonth, snap.filter.kind == .all, !snap.filter.isSearching {
        Text(snap.countLine)
          .hType(.subheadline)
          .foregroundStyle(HColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("activity.count")
      }
      if snap.days.isEmpty {
        EmptyListCard(kind: snap.filter.kind, query: model.searchText, period: snap.period, isThisMonth: snap.isThisMonth)
      } else {
        LazyVStack(alignment: .leading, spacing: 20) {
          ForEach(snap.days) { day in
            VStack(alignment: .leading, spacing: 8) {
              DayHeader(day: day, hidden: model.hidden)
              rows(day.rows)
            }
          }
        }
      }
    }
    .padding(.horizontal, HSpacing.insetPage)
  }

  /// "about 1 minute": about ten seconds a card.
  static func minutes(_ n: Int) -> String {
    let m = max(1, (n + 5) / 6)
    return "about \(m) minute\(m == 1 ? "" : "s")"
  }

  // MARK: Filtered

  private func filtered(_ summary: FilterSummary) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      FilterSummaryCard(summary: summary, hidden: model.hidden)
      if !snap.rows.isEmpty {
        rows(snap.rows)
        ExportLink(rows: model.exportRows, title: "Export these \(snap.rows.count)", prominent: true)
      } else {
        EmptyListCard(kind: .all, query: "", period: snap.period, isThisMonth: snap.isThisMonth,
                      category: summary.title)
      }
    }
    .padding(.horizontal, HSpacing.insetPage)
  }

  // MARK: Parts

  /// A section title (22/28 bold) with its quiet fact or link on the same baseline.
  private func header<Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
    ReflowingRow(alignment: .firstTextBaseline) {
      Text(title).hType(.section).foregroundStyle(HColor.textPrimary).accessibilityAddTraits(.isHeader)
    } trailing: {
      trailing()
    }
  }

  /// A white card of transaction rows, 64 tall, divided at 68. A row is one button.
  private func rows(_ rows: [MiniTxnRow]) -> some View {
    HListCard {
      ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
        if i > 0 { HDivider(inset: .disc68) }
        Button { model.open(row.id) } label: {
          TransactionRow(row, hidden: model.hidden).contentShape(Rectangle())
        }
        .buttonStyle(HRowPressStyle())
        // One element per row: the amount must not be its own tiny target.
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("txn.\(row.id)")
      }
    }
  }
}

/// "TODAY ……… 91.50": a day's overline with its total, 8 above its card.
private struct DayHeader: View {
  let day: DayGroup
  let hidden: Bool

  var body: some View {
    OverlineHeader(day.title) {
      MoneyText(day.total, figure: HFigure.badge.weight(.semibold), hidden: hidden, hiddenGlyphs: 3,
                color: HColor.textSecondary, sign: day.total.isNegative ? .income : .none, approx: day.approx)
    }
    // One heading per day, not a small static figure on its own.
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isHeader)
  }
}

/// An empty list (Paper page 15 §04, Proposed): one line saying what will appear and when.
/// The section header stays; no illustration inside a list card.
private struct EmptyListCard: View {
  let kind: TxnFilter.Kind
  let query: String
  let period: Period
  let isThisMonth: Bool
  var category: String?

  private var when: String { isThisMonth ? "this month" : "in \(period.title)" }

  var body: some View {
    VStack(spacing: 8) {
      Text(copy.title).hType(.rowTitle).foregroundStyle(HColor.textPrimary)
      Text(copy.detail).hType(.footnote).foregroundStyle(HColor.textSecondary)
    }
    .multilineTextAlignment(.center)
    .fixedSize(horizontal: false, vertical: true)
    .padding(.vertical, 24)
    .padding(.horizontal, 20)
    .frame(maxWidth: .infinity)
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.listGroup, style: .continuous))
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("activity.empty")
  }

  private var copy: (title: String, detail: String) {
    if !query.trimmingCharacters(in: .whitespaces).isEmpty {
      return ("No matches for “\(query)”", "Try a merchant name or a category.")
    }
    if let category {
      return ("Nothing in \(category) \(when)", "Transactions you sort into \(category) show here.")
    }
    switch kind {
    case .all:
      return (isThisMonth ? "Nothing yet this month" : "Nothing \(when)",
              "Card payments show here, usually within a minute of your bank's email.")
    case .toReview: return ("Nothing to sort", "New transactions Hasala can't sort on its own show up here.")
    case .bills:
      return (isThisMonth ? "No bills paid this month yet" : "No bills paid \(when)",
              "Payments to a bill you track show here.")
    case .transfers: return ("No transfers \(when)", "Money moved between your own accounts shows here.")
    case .income:
      return (isThisMonth ? "No income this month yet" : "No income \(when)",
              "Salary and other money in show here once they arrive.")
    case .archived: return ("Nothing archived", "Transactions you archive leave your plan and wait here.")
    }
  }
}

/// To review (Paper "Review card"): the deck picture, "6 to sort", what isn't in the plan
/// yet, and "Start review" (44).
struct ToReviewCard: View {
  let review: ReviewSummary
  let hidden: Bool
  let start: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 16) {
        ReviewDeckArt()
        VStack(alignment: .leading, spacing: 2) {
          Text("\(review.count) to sort").hFigure(.small).foregroundStyle(HColor.textPrimary)
          PhraseText(MoneyPhrase([.text("AED "), .amount(review.unplanned), .text(" still to check")]
                                 + (review.mark?.caption.map { [.text(" · \($0)")] } ?? [])),
                     hidden: hidden)
            .hType(.subheadline).foregroundStyle(HColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      Button("Start review", action: start)
        .buttonStyle(.pill(.primary, size: .medium, fill: true))
        .accessibilityIdentifier("activity.startReview")
    }
    .padding(16)
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
  }
}

/// The summary card of a category filter (Paper "Activity · Filtered"): the count, the total
/// at large size, the category's pace bar with today's tick, and its share of the budget
/// beside the verdict. The bar fills once each time the card appears.
struct FilterSummaryCard: View {
  let summary: FilterSummary
  let hidden: Bool
  @State private var phase = PaceFillPhase()
  @Environment(\.hMotion) private var policy

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text("\(summary.count) transaction\(summary.count == 1 ? "" : "s")").hType(.subheadline)
          .foregroundStyle(HColor.textSecondary)
        MoneyText(summary.total, figure: .large, unit: .unit, hidden: hidden, color: HColor.moneyOut,
                  unitColor: HColor.textPrimary, unitGap: 5, approx: summary.approx)
          .accessibilityIdentifier("activity.summary.total")
      }
      CategoryPaceBar(spent: summary.progress, tick: summary.today, verdict: summary.verdict, phase: phase)
        .paceFillSequence($phase, target: min(1, summary.progress.fraction), policy: policy)
      ReflowingRow(spacing: 12) {
        PhraseText(summary.caption, hidden: hidden).hType(.footnote).foregroundStyle(HColor.textSecondary)
      } trailing: {
        StatusDotLine(words: summary.verdict.label, verdict: summary.verdict)
      }
    }
    .padding(16)
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
  }
}

/// "● Over pace": a 7 dot in the verdict's fill and the words 13/18 600 in its colour
/// (Paper "StatusDot"; colour never alone).
struct StatusDotLine: View {
  let words: String
  let verdict: Verdict
  var large = false

  var body: some View {
    HStack(spacing: 6) {
      Circle().fill(verdict == .overPace ? HColor.paceFillOverPace : verdict.foreground).frame(width: 7, height: 7)
      Text(words)
        .hType(large ? .subheadline.weight(.semibold) : .footnote.weight(.semibold))
        .foregroundStyle(verdict.foreground)
    }
    .accessibilityElement(children: .combine)
  }
}

/// "Export" / "⤓ Export these 5": shares the rows as a CSV file (spec 04 §16.2 T5). The
/// plain form is the section's link (17/24 medium); the prominent one is the white Large pill
/// with the download glyph.
struct ExportLink: View {
  let rows: [ExportRow]
  let title: String
  var prominent = false

  var body: some View {
    let file = CSVFile(rows: rows, name: CSVExport.fileName(rows.first?.date ?? LocalDate(2026, 1, 1)))
    Group {
      if prominent {
        ShareLink(item: file, preview: SharePreview(file.name)) { Text(title) }
          .buttonStyle(.pill(.onGrouped, fill: true, leadingIcon: .download))
      } else {
        ShareLink(item: file, preview: SharePreview(file.name)) {
          Text(title).hType(.textButton).foregroundStyle(HColor.textLink)
            .frame(minHeight: HSpacing.targetMinimum)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    }
    .disabled(rows.isEmpty)
    .accessibilityIdentifier("activity.export")
  }
}

#if HASALA_MOCKS
  #Preview("Activity · Overview") {
    let app = AppModel(store: InMemoryLedger())
    ActivityView(app: app, model: ActivityViewModel(app: app))
  }
#endif
