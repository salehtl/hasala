import HasalaDesign
import HasalaModels
import SwiftUI

struct InsightsView: View {
  @Bindable var app: AppModel
  @State private var model: InsightsModel
  @Environment(\.dynamicTypeSize) private var typeSize

  init(app: AppModel) {
    self.app = app
    _model = State(initialValue: InsightsModel(app: app))
  }

  private var hidden: Bool { model.hidden }
  private var unfinished: Bool { BuildSurface.showsUnfinished }

  var body: some View {
    let snap = model.snapshot
    PushedPage(app: app, title: "Insights", wash: .onTrack) {
      VStack(alignment: .leading, spacing: 12) {
        periodRow(snap)
        InsightsSummaryCard(summary: snap.summary, comparison: snap.comparison, hidden: hidden) { model.open($0) }
      }
      .padding(.horizontal, HSpacing.insetPage)
      analyze(snap).padding(.horizontal, HSpacing.insetPage)
      changes(snap).padding(.horizontal, HSpacing.insetPage)
      InsightsFlowCard(flow: snap.flow, empty: snap.flowEmpty, focus: snap.focus, hidden: hidden,
                       showsTable: $model.showsTable)
        .padding(.horizontal, HSpacing.insetPage)
      reports(snap).padding(.horizontal, HSpacing.insetPage)
    }
    .accessibilityIdentifier("insights.screen")
    .toolbar {
      if !hidden {
        ToolbarItem(placement: .topBarTrailing) {
          ShareLink(item: snap.share.rendered(hidden: false)) {
            HIconView(.share, size: HSpacing.iconGlass, color: HColor.iconGlass, strokeWidth: 1.9)
          }
          .accessibilityLabel("Share \(snap.title)")
          .accessibilityIdentifier("insights.share")
        }
      }
    }
    .sheet(item: $model.sheet) { sheet in
      switch sheet {
      case .period:
        InsightsPeriodSheet(selected: model.months, current: model.current, earliest: model.earliest) {
          model.choose($0)
        }
      case .drill(let target):
        InsightsDrillSheet(model: model, target: target)
      }
    }
  }

  private func periodRow(_ snap: InsightsSnapshot) -> some View {
    let layout = typeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
      : AnyLayout(HStackLayout(spacing: 8))
    return layout {
      PeriodPill(snap.title) { model.sheet = .period }
        .accessibilityIdentifier("insights.period")
      if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
      status(snap)
    }
  }

  private func status(_ snap: InsightsSnapshot) -> some View {
    Text(snap.status).hType(.subheadline).foregroundStyle(HColor.textSecondary)
      .accessibilityIdentifier("insights.status")
  }

  // MARK: Analyze by

  private func analyze(_ snap: InsightsSnapshot) -> some View {
    let all = snap.rows(model.lens)
    let collapsible = model.lens == .categories && all.count > InsightsEngine.collapsedCategories
    let rows = collapsible && !model.showsAllCategories ? Array(all.prefix(InsightsEngine.collapsedCategories)) : all
    return VStack(alignment: .leading, spacing: 12) {
      SectionTitle(title: "Analyze by", note: snap.lensNote)
      HSegmentedControl(InsightsLens.allCases, selection: $model.lens) { $0.title }
        .accessibilityIdentifier("insights.lens")
      Group {
        if rows.isEmpty {
          EmptyNote(systemImage: "chart.bar", message: snap.lensEmpty)
        } else {
          VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
              if i > 0 { InsightsSeparator() }
              Button { model.open(row.target) } label: {
                InsightsLensRow(row: row, comparison: snap.comparison, hidden: hidden)
              }
              .buttonStyle(HRowPressStyle())
              .accessibilityIdentifier("insights.row.\(row.id)")
            }
            if collapsible {
              footer(count: all.count)
            }
          }
          .listCard()
        }
      }
      .id(model.lens)
      .hTransition(.fade)
      .hAnimation(.stateSwap, value: model.lens)
      if !rows.isEmpty {
        Text(snap.lensFooter.rendered(hidden: hidden))
          .hType(.footnote).foregroundStyle(HColor.textSecondary)
          .padding(.horizontal, 4)
          .accessibilityLabel(snap.lensFooter.spoken(hidden: hidden))
      }
    }
  }

  private func footer(count: Int) -> some View {
    VStack(spacing: 0) {
      InsightsSeparator(inset: HSpacing.listRowInsetInline)
      Button {
        withAnimation(nil) { model.showsAllCategories.toggle() }
      } label: {
        HStack {
          Text(model.showsAllCategories ? "Show top \(InsightsEngine.collapsedCategories)" : "All \(count) categories")
            .hType(.rowTitle).foregroundStyle(HColor.textLink)
          Spacer(minLength: 8)
          HIconView(model.showsAllCategories ? .chevronUp : .chevronRight, size: 16, color: HColor.listRowChevron)
        }
        .padding(.horizontal, HSpacing.listRowInsetInline)
        .frame(minHeight: HSpacing.listRowMinHeight)
        .contentShape(Rectangle())
      }
      .buttonStyle(HRowPressStyle())
      .accessibilityIdentifier("insights.allCategories")
    }
  }

  // MARK: Biggest changes

  @ViewBuilder private func changes(_ snap: InsightsSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      SectionTitle(title: "Biggest changes", note: snap.comparison?.label)
      if let notice = snap.changesNotice {
        VStack(alignment: .leading, spacing: 4) {
          Text(notice.title).hType(.rowTitle).foregroundStyle(HColor.textPrimary)
          Text(notice.message).hType(.subheadline).foregroundStyle(HColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(HSpacing.insetCard)
        .listCard()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("insights.changes.empty")
      } else if let comparison = snap.comparison {
        VStack(spacing: 0) {
          ForEach(Array(snap.changes.enumerated()), id: \.element.id) { i, change in
            if i > 0 { InsightsSeparator() }
            InsightsChangeRow(change: change, comparison: comparison, hidden: hidden)
          }
        }
        .listCard()
        .accessibilityIdentifier("insights.changes")
      }
    }
  }

  // MARK: Reports

  private func reports(_ snap: InsightsSnapshot) -> some View {
    let tiles = snap.reports.filter { unfinished || $0.opens }
    return Group {
      if !tiles.isEmpty {
        VStack(alignment: .leading, spacing: 12) {
          Text("Reports").hType(.section).foregroundStyle(HColor.textPrimary).accessibilityAddTraits(.isHeader)
          if typeSize.isAccessibilitySize {
            VStack(spacing: 12) { ForEach(tiles) { tile($0) } }
          } else {
            VStack(spacing: 12) {
              ForEach(Array(stride(from: 0, to: tiles.count, by: 2)), id: \.self) { i in
                HStack(alignment: .top, spacing: 12) {
                  tile(tiles[i])
                  if i + 1 < tiles.count { tile(tiles[i + 1]) } else { Color.clear.frame(maxWidth: .infinity) }
                }
                .fixedSize(horizontal: false, vertical: true)
              }
            }
          }
        }
      }
    }
  }

  private func tile(_ report: InsightsReport) -> some View {
    Button { model.openReport(report.kind) } label: {
      InsightsReportTile(report: report, hidden: hidden, chevron: true)
    }
    .buttonStyle(HPressStyle())
    .accessibilityIdentifier("insights.report.\(report.kind.rawValue)")
  }
}
