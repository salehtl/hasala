import HasalaDesign
import HasalaModels
import SwiftUI

enum HomeGallery {
  static func kinds(showsUnfinished: Bool = BuildSurface.showsUnfinished) -> [HomeWidgetKind] {
    HomeWidgetKind.allCases.filter { showsUnfinished || $0.worksInRelease }
  }
}

extension HomeWidgetKind {
  var worksInRelease: Bool {
    switch self {
    case .spentSoFar, .budgetPace, .categoryWatch, .nextBill, .netWorth, .comingUp, .project, .goal, .toReview, .today:
      true
    }
  }
}

struct WidgetGallerySheet: View {
  @Bindable var app: AppModel
  @State private var path: [HomeWidgetKind] = []
  @Environment(\.dismiss) private var dismiss
  @Environment(\.dynamicTypeSize) private var typeSize

  private let kinds = HomeGallery.kinds()

  var body: some View {
    NavigationStack(path: $path) {
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          PlanSheetHeader(title: "Add a widget", closeID: "gallery.close") { dismiss() }
          Text("Tap a widget to put it at the end of Home. Amounts follow the eye, as on Home.")
            .hType(.subheadline).foregroundStyle(HColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
          ForEach(HomeWidgetKind.Group.allCases, id: \.self) { group in
            let available = group.kinds.filter(kinds.contains)
            let shown = available.filter { $0.size == .small } + available.filter { $0.size == .medium }
            if !shown.isEmpty { section(group, shown) }
          }
        }
        .padding(.horizontal, HSpacing.insetPage)
        .padding(.top, 21)
        .padding(.bottom, 40)
        .containerRelativeFrame(.horizontal)
      }
      .scrollBounceBehavior(.basedOnSize)
      .background(HColor.sheetSurfaceLarge)
      .toolbar(.hidden, for: .navigationBar)
      .navigationDestination(for: HomeWidgetKind.self) { kind in
        WidgetConfigPage(app: app, kind: kind, entry: nil, pushed: true) { app.sheet = nil }
          .toolbar(.hidden, for: .navigationBar)
      }
    }
    .accessibilityIdentifier("gallery.sheet")
    .planLargeSheet()
  }

  private func section(_ group: HomeWidgetKind.Group, _ shown: [HomeWidgetKind]) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(group.title).hType(.overline).foregroundStyle(HColor.textGroupedHeader)
        .accessibilityAddTraits(.isHeader)
      let rows = typeSize.isAccessibilitySize ? shown.map { [$0] } : shown.canvasRows
      ForEach(rows, id: \.first) { row in
        HStack(alignment: .top, spacing: HSpacing.widgetGutter) {
          ForEach(row, id: \.self) { cell($0) }
          if row.count == 1, row[0].size == .small, !typeSize.isAccessibilitySize {
            Color.clear.frame(maxWidth: .infinity)
          }
        }
      }
    }
  }

  private func cell(_ kind: HomeWidgetKind) -> some View {
    let onHome = app.currentHomeLayout.isOnHome(kind)
    return Button { choose(kind) } label: {
      VStack(alignment: .leading, spacing: 8) {
        preview(kind)
          .opacity(onHome ? 0.55 : 1)
          .overlay(alignment: .topLeading) {
            if !onHome {
              Circle().fill(HColor.actionAccent).frame(width: 28, height: 28)
                .overlay { HIconView(.add, size: 12, color: HColor.white, strokeWidth: 2.6) }
                .hElevation(.nearFar)
                .offset(x: -6, y: -6)
            }
          }
        VStack(alignment: .leading, spacing: 2) {
          Text(kind.title).hType(.subheadline.weight(.semibold)).foregroundStyle(HColor.textPrimary)
          if onHome {
            HStack(spacing: 4) {
              HIconView(.check, size: 12, color: HColor.statusSuccessForeground, strokeWidth: 2.6)
              Text("On Home").hType(.footnote.weight(.semibold)).foregroundStyle(HColor.statusSuccessForeground)
            }
          } else {
            Text(kind.caption).hType(.footnote).foregroundStyle(HColor.textSecondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(HPressStyle(in: RoundedRectangle(cornerRadius: HRadius.widget, style: .continuous)))
    .disabled(onHome)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(kind.title)
    .accessibilityValue(onHome ? "On Home" : kind.caption)
    .accessibilityHint(onHome ? "" : (kind.configurable ? "Choose what it shows, then add it" : "Adds it to Home"))
    .accessibilityAddTraits(.isButton)
    .accessibilityIdentifier("gallery.\(kind.rawValue)")
  }

  @ViewBuilder private func preview(_ kind: HomeWidgetKind) -> some View {
    let item = app.widgetPreviews[kind] ?? HomeCanvasItem(entry: HomeLayout.Entry(kind), widget: nil)
    HomeCanvasItemView(item, hidden: app.amountsHidden)
      .fixedSize(horizontal: false, vertical: true)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }

  private func choose(_ kind: HomeWidgetKind) {
    if kind.configurable {
      path.append(kind)
      return
    }
    if app.addWidget(HomeLayout.Entry(kind)) {
      app.sheet = nil
      app.say("\(kind.title) added to Home")
    }
  }
}

struct WidgetConfigSheet: View {
  let app: AppModel
  let kind: HomeWidgetKind
  let entry: String?
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    WidgetConfigPage(app: app, kind: kind, entry: entry, pushed: false) { dismiss() }
      .planLargeSheet()
  }
}

struct WidgetConfigPage: View {
  let app: AppModel
  let kind: HomeWidgetKind
  let entry: String?
  let pushed: Bool
  let done: () -> Void
  @State private var selected: HomeWidgetConfig?
  @Environment(\.dismiss) private var dismiss

  init(app: AppModel, kind: HomeWidgetKind, entry: String?, pushed: Bool, done: @escaping () -> Void) {
    self.app = app
    self.kind = kind
    self.entry = entry
    self.pushed = pushed
    self.done = done
    let layout = app.currentHomeLayout
    let current = entry.flatMap { id in layout.entries.first { $0.id == id }?.config }
    let options = kind.configKind.map(app.widgetOptions) ?? []
    let free = options.map(\.config).filter { !layout.contains(HomeLayout.Entry(kind, config: $0).id) }
    let suggested = kind.configKind.flatMap(app.suggestedWidgetConfig)
    _selected = State(initialValue: current ?? (suggested.flatMap { free.contains($0) ? $0 : nil } ?? free.first))
  }

  private var options: [HomeWidgetOption] { kind.configKind.map(app.widgetOptions) ?? [] }

  private var sections: [String] {
    var seen = Set<String>()
    return options.map(\.section).filter { seen.insert($0).inserted }
  }

  private func taken(_ option: HomeWidgetOption) -> Bool {
    let id = HomeLayout.Entry(kind, config: option.config).id
    return id != entry && app.currentHomeLayout.contains(id)
  }

  var body: some View {
    ScrollView {
      VStack(spacing: 20) {
        header
        VStack(spacing: 10) {
          HomeCanvasItemView(previewItem, hidden: app.amountsHidden)
            .frame(width: kind.size == .small ? HContainer.widgetUnit : nil)
            .fixedSize(horizontal: false, vertical: true)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
          Text(options.isEmpty ? kind.waitingSentence : hint)
            .hType(.footnote).foregroundStyle(HColor.textSecondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
        ForEach(sections, id: \.self) { section in
          VStack(alignment: .leading, spacing: 8) {
            Text(section).hType(.overline).foregroundStyle(HColor.textGroupedHeader)
              .padding(.leading, 4)
              .accessibilityAddTraits(.isHeader)
            HListCard {
              let rows = options.filter { $0.section == section }
              ForEach(Array(rows.enumerated()), id: \.element.id) { i, option in
                if i > 0 { HDivider() }
                row(option)
              }
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        if !options.isEmpty {
          Button(entry == nil ? "Add to Home" : "Save") { save() }
            .buttonStyle(PillButtonStyle(.primary, size: .large, fill: true))
            .disabled(selected == nil)
            .accessibilityIdentifier("widgetConfig.save")
        }
      }
      .padding(.horizontal, HSpacing.insetPage)
      .padding(.top, 21)
      .padding(.bottom, 40)
      .containerRelativeFrame(.horizontal)
    }
    .scrollBounceBehavior(.basedOnSize)
    .background(HColor.sheetSurfaceLarge)
    .accessibilityIdentifier("widgetConfig.sheet")
  }

  private var hint: String {
    switch kind.configKind {
    case .category?: "Pick the category this widget watches. You can change it later from Edit."
    case .project?: "Pick the project this widget follows. You can change it later from Edit."
    case .goal?: "Pick the savings goal this widget follows. You can change it later from Edit."
    case nil: ""
    }
  }

  @ViewBuilder private var header: some View {
    if pushed {
      HStack(spacing: 8) {
        GlassIconButton(.back, label: "Back") { dismiss() }
          .accessibilityIdentifier("widgetConfig.back")
        Text(kind.title).hType(.headline).foregroundStyle(HColor.textPrimary)
          .frame(maxWidth: .infinity)
          .accessibilityAddTraits(.isHeader)
        Color.clear.frame(width: HSpacing.glassButton, height: HSpacing.glassButton).accessibilityHidden(true)
      }
      .frame(minHeight: HSpacing.glassButton)
    } else {
      PlanSheetHeader(title: kind.title, closeID: "widgetConfig.close") { dismiss() }
    }
  }

  private var previewItem: HomeCanvasItem {
    guard let selected else { return HomeCanvasItem(entry: HomeLayout.Entry(kind), widget: nil) }
    return HomeEngine.canvas(HomeLayout([HomeLayout.Entry(kind, config: selected)]), app.store.state, now: app.store.now)
      .first ?? HomeCanvasItem(entry: HomeLayout.Entry(kind), widget: nil)
  }

  private func row(_ option: HomeWidgetOption) -> some View {
    let isTaken = taken(option)
    return Button { selected = option.config } label: {
      HListRow(
        leading: .disc(option.hue, option.glyph.icon), title: option.title,
        supporting: isTaken ? .text("On Home") : option.detail.map { .phrase($0) },
        trailing: .check(selected == option.config), hidden: app.amountsHidden)
    }
    .buttonStyle(HRowPressStyle())
    .disabled(isTaken)
    .accessibilityAddTraits(selected == option.config ? .isSelected : [])
    .accessibilityIdentifier("widgetConfig.option.\(option.id)")
  }

  private func save() {
    guard let selected else { return }
    if let entry {
      app.configureWidget(entry, selected)
    } else if app.addWidget(HomeLayout.Entry(kind, config: selected)) {
      app.say("\(kind.title) added to Home")
    }
    done()
  }
}
