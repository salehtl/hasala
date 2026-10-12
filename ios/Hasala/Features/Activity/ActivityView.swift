import HasalaDesign
import HasalaModels
import SwiftUI

#if HASALA_MOCKS
  import HasalaMocks
#endif

/// Activity · Overview (Paper board): the register. To review first, then what is
/// coming up, then history by local day. Every row opens the transaction sheet.
struct ActivityView: View {
  @Bindable var app: AppModel
  let model: any ActivityModel

  var body: some View {
    NavigationStack {
      // TODO(spec 04 §16.1 "Add transaction"): until AddTransactionSheet exists, Release has no "+".
      TabScreen(app: app, title: "Activity", extra: BuildSurface.showsUnfinished ? .add : .none,
                onExtra: { model.addTransaction() }) {
        ActivityContent(model: model)
      }
      .searchable(
        text: Binding(get: { model.searchText }, set: { model.search($0) }),
        placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search transactions"
      )
    }
  }
}

/// The body of Activity, shared by the overview and the filtered screen.
struct ActivityContent: View {
  let model: any ActivityModel
  var showsChips = true

  private var snap: ActivitySnapshot { model.snapshot }

  var body: some View {
    VStack(alignment: .leading, spacing: HSpacing.gapScreenSection) {
      VStack(alignment: .leading, spacing: 14) {
        if showsChips {
          HStack(spacing: 10) {
            MonthPill(month: snap.month)
            Text(snap.countLine).hType(.subheadline).foregroundStyle(HColor.textSecondary)
              .accessibilityIdentifier("activity.count")
          }
          .padding(.horizontal, HSpacing.insetPage)
          chips
        }
        if let summary = snap.summary {
          FilterSummaryCard(summary: summary, hidden: model.hidden)
            .padding(.horizontal, HSpacing.insetPage)
        }
      }

      if let review = snap.review {
        VStack(alignment: .leading, spacing: 12) {
          SectionTitle(title: "To review", note: "about \(max(1, review.count / 6)) minute\(review.count > 11 ? "s" : "")")
          ToReviewCard(review: review, hidden: model.hidden) { model.startReview() }
        }
        .padding(.horizontal, HSpacing.insetPage)
      }

      if !snap.comingUp.isEmpty {
        VStack(alignment: .leading, spacing: 12) {
          SectionTitle(title: "Coming up", note: "next 7 days")
          ListCard {
            ForEach(snap.comingUp) { BillRow(row: $0, hidden: model.hidden) }
          }
        }
        .padding(.horizontal, HSpacing.insetPage)
      }

      VStack(alignment: .leading, spacing: 12) {
        if snap.summary == nil {
          HStack {
            SectionTitle(title: model.searchText.isEmpty ? "History" : "Results")
            Spacer()
            ExportLink(rows: model.exportRows, title: "Export")
          }
        }
        if snap.days.isEmpty {
          EmptyNote(systemImage: "tray", message: model.searchText.isEmpty
            ? "Nothing here yet. Bank alerts fill this in as they arrive."
            : "No transactions match “\(model.searchText)”.")
            .accessibilityIdentifier("activity.empty")
        }
        VStack(alignment: .leading, spacing: 20) {
          ForEach(snap.days) { day in
            VStack(alignment: .leading, spacing: 8) {
              DayOverline(title: day.title, total: day.total, hidden: model.hidden)
              ListCard {
                ForEach(day.rows) { row in
                  Button { model.open(row.id) } label: {
                    TxnRow(row, hidden: model.hidden)
                      .padding(.horizontal, HSpacing.listRowInsetInline)
                      .contentShape(Rectangle())
                  }
                  .buttonStyle(.plain)
                  // One element per row: the amount must not be its own tiny target.
                  .accessibilityElement(children: .combine)
                  .accessibilityIdentifier("txn.\(row.id)")
                }
              }
            }
          }
        }
        if snap.summary != nil, !snap.days.isEmpty {
          ExportLink(rows: model.exportRows, title: "Export these \(snap.rowCount)", prominent: true)
            .frame(maxWidth: .infinity)
        }
      }
      .padding(.horizontal, HSpacing.insetPage)
    }
  }

  private var chips: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 8) {
        ForEach(snap.chips) { chip in
          FilterChip(chip.kind.title, count: chip.count.flatMap { $0 > 0 ? $0 : nil },
                     selected: snap.filter.kind == chip.kind) { model.select(chip.kind) }
            .accessibilityIdentifier("activity.chip.\(chip.kind.rawValue)")
        }
      }
      .padding(.horizontal, HSpacing.insetPage)
    }
    .scrollIndicators(.hidden)
  }
}

/// "6 to sort · AED 827.28 isn't in your plan yet · Start review".
struct ToReviewCard: View {
  let review: ReviewSummary
  let hidden: Bool
  let start: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 16) {
        ZStack {
          RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Hue.sky.gradient)
            .frame(width: 72, height: 72)
          Image(systemName: "rectangle.stack.fill")
            .font(.system(size: 28, weight: .semibold)).foregroundStyle(Hue.sky.ink)
        }
        .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text("\(review.count) to sort").hType(.title3).foregroundStyle(HColor.textPrimary)
          PhraseText(MoneyPhrase([.text("AED "), .amount(review.unplanned), .text(" isn't in your plan yet")]),
                     hidden: hidden)
            .hType(.subheadline).foregroundStyle(HColor.textSecondary)
        }
      }
      Button("Start review", action: start)
        .buttonStyle(.pill(.primary, size: .medium, fill: true))
        .accessibilityIdentifier("activity.startReview")
    }
    .padding(16)
    .listCard()
  }
}

/// A bill or income row: disc, name over detail, the amount with its note under it.
struct BillRow: View {
  let row: BillRowModel
  let hidden: Bool

  var body: some View {
    HStack(spacing: HSpacing.listRowGap) {
      HueDisc(hue: row.hue, glyph: row.glyph)
      VStack(alignment: .leading, spacing: 0) {
        Text(row.name).hType(.rowTitle).foregroundStyle(HColor.listRowTitle)
        DetailLine(parts: row.detail, hidden: hidden)
      }
      Spacer(minLength: 8)
      VStack(alignment: .trailing, spacing: 0) {
        HStack(spacing: 0) {
          if row.approximate && !hidden {
            Text(verbatim: "~").hFigure(.row).foregroundStyle(HColor.moneyOut).accessibilityLabel("about")
          }
          MoneyText(row.amount, figure: .row, hidden: hidden, hiddenGlyphs: 3,
                    color: row.isIncome ? HColor.moneyIn : HColor.moneyOut, sign: row.isIncome ? .income : .none)
        }
        if let note = row.trailingNote { DetailLine(parts: [note], hidden: hidden) }
      }
      .fixedSize()
    }
    .padding(.horizontal, HSpacing.listRowInsetInline)
    .frame(minHeight: HSpacing.listRowMinHeightTwoLine)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("bill.\(row.id)")
  }
}

/// The summary card of a category filter ("Activity · Filtered"): count, total, pace, share of budget.
struct FilterSummaryCard: View {
  let summary: FilterSummary
  let hidden: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("\(summary.count) transaction\(summary.count == 1 ? "" : "s")").hType(.subheadline)
        .foregroundStyle(HColor.textSecondary)
      MoneyText(summary.total, figure: .large, unit: .unit, hidden: hidden, color: HColor.textPrimary, unitGap: 5)
        .accessibilityIdentifier("activity.summary.total")
      PaceBar(summary.title, spent: summary.progress, today: summary.today, verdict: summary.verdict)
      HStack {
        PhraseText(summary.caption, hidden: hidden).hType(.footnote).foregroundStyle(HColor.textSecondary)
        Spacer()
        DetailLine(parts: [.status(summary.verdict.label, summary.verdict.tone)], hidden: hidden)
      }
    }
    .padding(16)
    .listCard()
  }
}

/// "Export" / "⤓ Export these 5": shares the rows as a CSV file (spec 04 §16.2 T5).
struct ExportLink: View {
  let rows: [ExportRow]
  let title: String
  var prominent = false

  var body: some View {
    let file = CSVFile(rows: rows, name: CSVExport.fileName(rows.first?.date ?? LocalDate(2026, 1, 1)))
    ShareLink(item: file, preview: SharePreview(file.name)) {
      if prominent {
        Label(title, systemImage: "square.and.arrow.down")
      } else {
        Text(title)
      }
    }
    .buttonStyle(.plain)
    .hType(prominent ? .button : .body.weight(.medium))
    .foregroundStyle(HColor.textLink)
    .padding(.horizontal, prominent ? 20 : 0)
    .frame(minHeight: prominent ? HSpacing.buttonHeightMedium : nil)
    .background(prominent ? HColor.surfacePrimary : .clear, in: Capsule())
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
