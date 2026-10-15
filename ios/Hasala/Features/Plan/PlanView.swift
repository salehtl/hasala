import HasalaDesign
import HasalaModels
import SwiftUI

#if HASALA_MOCKS
  import HasalaMocks
#endif

/// Plan · October (Paper board): one plan for the month. Ready to assign, the split,
/// the buckets with their budget rows, goals and projects.
struct PlanView: View {
  @Bindable var app: AppModel
  let model: any PlanModel

  var body: some View {
    NavigationStack(path: Bindable(app.router).plan) {
      TabScreen(app: app, title: "Plan", extra: .none) {
        PlanContent(model: model) { app.router.plan.append(.category($0)) }
      }
      .navigationDestination(for: PlanRoute.self) { route in
        switch route {
        case .category(let id): CategoryDetailView(app: app, category: id)
        case .project(let id): ProjectDetailView(app: app, project: id)
        }
      }
    }
  }
}

private struct PlanContent: View {
  let model: any PlanModel
  let open: (CategoryID) -> Void
  @Environment(\.dynamicTypeSize) private var typeSize

  private var snap: PlanSnapshot { model.snapshot }

  var body: some View {
    VStack(alignment: .leading, spacing: HSpacing.gapScreenSection) {
      MonthPill(month: snap.month)
        .padding(.horizontal, HSpacing.insetPage)
        .padding(.bottom, -16)
      readyToAssign
      split
      ForEach(snap.sections) { section in
        bucket(section)
      }
      if !snap.projects.isEmpty { projects }
    }
  }

  // MARK: Ready to assign

  private var readyToAssign: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 8) {
        // The overline wraps on its own at the accessibility sizes, without the glyph.
        if typeSize.isAccessibilitySize {
          Text("Ready to assign").hType(.overline).foregroundStyle(Hue.mint.ink)
        } else {
          HStack(spacing: 8) {
            Image(systemName: "wallet.bifold").font(.system(size: 15, weight: .semibold))
              .foregroundStyle(Hue.mint.ink).accessibilityHidden(true)
            Text("Ready to assign").hType(.overline).foregroundStyle(Hue.mint.ink)
          }
        }
        MoneyText(snap.readyToAssign, figure: .large, unit: .unit, hidden: model.hidden, hiddenGlyphs: 6,
                  color: snap.readyToAssign.isNegative ? HColor.statusErrorForeground : HColor.textPrimary,
                  unitGap: 5, sign: snap.readyToAssign.isNegative ? .debt : .none)
          .accessibilityIdentifier("plan.readyToAssign")
        PhraseText(snap.incomeLine, hidden: model.hidden).hType(.subheadline)
          .foregroundStyle(HColor.textOnHueSecondary)
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Hue.mint.gradient)
      VStack(alignment: .leading, spacing: 12) {
        // Side by side; stacked at the accessibility text sizes (spec 04 §17).
        // TODO(03a §6.11, spec 04 §16.2 P2): Auto-assign; a Release build offers Assign alone.
        let buttons = Group {
          Button("Assign") { model.moveMoney(to: nil) }
            .buttonStyle(.pill(.primary, size: .medium, fill: true))
            .disabled(snap.readyToAssign.minor <= 0)
            .accessibilityIdentifier("plan.assign")
          if BuildSurface.showsUnfinished {
            Button("Auto-assign") { model.autoAssign() }
              .buttonStyle(.pill(.secondary, size: .medium, fill: true))
          }
        }
        if typeSize.isAccessibilitySize {
          VStack(spacing: 8) { buttons }
        } else {
          HStack(spacing: 8) { buttons }
        }
        if BuildSurface.showsUnfinished {
          Text("Auto-assign funds targets first, then follows your \(snap.splitName) split.")
            .hType(.footnote).foregroundStyle(HColor.textSecondary)
        }
      }
      .padding(16)
    }
    .background(HColor.surfacePrimary)
    .clipShape(RoundedRectangle(cornerRadius: HRadius.listGroup, style: .continuous))
    .elevation()
    .padding(.horizontal, HSpacing.insetPage)
  }

  // MARK: Split

  private var split: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Your split").hType(.overline).foregroundStyle(HColor.textSecondary)
        Spacer()
        Text(snap.startedFrom).hType(.footnote).foregroundStyle(HColor.textSecondary)
      }
      GeometryReader { geo in
        HStack(spacing: 3) {
          ForEach(snap.split) { share in
            Capsule().fill(share.bucket.hue.end)
              .frame(width: max(4, (geo.size.width - 6) * share.share.fraction))
          }
        }
      }
      .frame(height: 8)
      .accessibilityHidden(true)
      HStack(alignment: .top) {
        ForEach(snap.split) { share in
          VStack(alignment: .leading, spacing: 0) {
            Text(share.bucket.title).hType(.footnote).foregroundStyle(HColor.textSecondary)
            Text(share.label).hType(.headline).foregroundStyle(HColor.textPrimary)
          }
          .accessibilityElement(children: .combine)
          if share.id != snap.split.last?.id { Spacer() }
        }
      }
    }
    .padding(.horizontal, HSpacing.insetPage)
  }

  // MARK: Buckets

  private func bucket(_ section: PlanSection) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      // The bucket's title and its figures stack at the accessibility sizes (spec 04 §17).
      let layout = typeSize.isAccessibilitySize
        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
        : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
      layout {
        HStack(spacing: 8) {
          Circle().fill(section.bucket.hue.end).frame(width: 10, height: 10)
          Text(section.bucket.title).hType(.title2).foregroundStyle(HColor.textPrimary)
        }
        .accessibilityAddTraits(.isHeader)
        if !typeSize.isAccessibilitySize { Spacer() }
        if section.done {
          Label("Done for \(snap.month.name)", systemImage: "checkmark")
            .hType(.subheadline.weight(.semibold)).foregroundStyle(HColor.statusSuccessForeground)
        } else {
          HStack(alignment: .firstTextBaseline, spacing: 4) {
            MoneyText(section.left, figure: .compact, hidden: model.hidden, color: HColor.textPrimary)
            PhraseText(MoneyPhrase([.text(section.left.isNegative ? "over " : "left of "),
                                    .amount(section.budget, .compact)]), hidden: model.hidden)
              .hType(.subheadline).foregroundStyle(HColor.textSecondary)
          }
          .accessibilityElement(children: .combine)
          .accessibilityAddTraits(.isStaticText)
        }
      }
      ListCard {
        ForEach(section.rows) { row in
          Button { open(row.id) } label: { BudgetRow(row: row, hidden: model.hidden) }
            .buttonStyle(.plain)
            .accessibilityIdentifier("plan.row.\(row.id)")
        }
      }
    }
    .padding(.horizontal, HSpacing.insetPage)
  }

  // MARK: Projects

  private var projects: some View {
    VStack(alignment: .leading, spacing: 12) {
      // TODO(spec 04 §16.2 P3): "New project" (ProjectEditSheet) and ProjectDetailView ("Project detail").
      SectionTitle(title: "Projects")
      ForEach(snap.projects) { p in
        VStack(alignment: .leading, spacing: 10) {
          HStack(spacing: 12) {
            Circle().fill(HColor.posterGlyph).frame(width: 40, height: 40)
              .overlay { Image(systemName: Glyph.flag.symbolName).foregroundStyle(Hue.peach.ink) }
              .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
              Text(p.name).hType(.rowTitle).foregroundStyle(HColor.textPrimary)
              Text(p.dates).hType(.footnote).foregroundStyle(HColor.textOnHueSecondary)
            }
          }
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            MoneyText(p.left, figure: .large, hidden: model.hidden, color: HColor.textPrimary)
            PhraseText(MoneyPhrase([.text("left of "), .amount(p.budget, .compact)]), hidden: model.hidden)
              .hType(.subheadline).foregroundStyle(HColor.textOnHueSecondary)
          }
          ProgressLine(p.progress, fill: HColor.actionAccent, track: HColor.progressTrackOnHue)
          if !p.countInPlan {
            Label("Not counted in your monthly plan", systemImage: "info.circle")
              .hType(.footnote).foregroundStyle(HColor.textOnHueSecondary)
          }
        }
        .padding(16)
        .background(Hue.peach.gradient, in: RoundedRectangle(cornerRadius: HRadius.listGroup, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("plan.project.\(p.id)")
      }
    }
    .padding(.horizontal, HSpacing.insetPage)
  }
}

/// A budget row: disc, name, the second line, "N left" (or ✓ Done / 77%), and a slim bar.
/// Bills and goals get no tick.
struct BudgetRow: View {
  let row: PlanRowModel
  let hidden: Bool
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    HStack(alignment: .top, spacing: HSpacing.listRowGap) {
      HueDisc(hue: row.hue, glyph: row.glyph)
      VStack(alignment: .leading, spacing: 6) {
        // The figure moves under the name at the accessibility sizes (spec 04 §17).
        if typeSize.isAccessibilitySize {
          Text(row.name).hType(.rowTitle).foregroundStyle(HColor.listRowTitle)
          trailing
        } else {
          HStack(alignment: .firstTextBaseline) {
            Text(row.name).hType(.rowTitle).foregroundStyle(HColor.listRowTitle)
            Spacer(minLength: 8)
            trailing
          }
        }
        DetailLine(parts: row.detail, hidden: hidden)
        ProgressLine(row.progress, fill: row.verdict.fill)
          .frame(height: 4)
      }
    }
    .padding(.horizontal, HSpacing.listRowInsetInline)
    .padding(.vertical, 12)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder private var trailing: some View {
    switch row.trailing {
    case .left(let m):
      HStack(alignment: .firstTextBaseline, spacing: 3) {
        MoneyText(m, figure: .row, hidden: hidden, hiddenGlyphs: 3,
                  color: m.isNegative ? HColor.statusErrorForeground : HColor.textPrimary)
        Text(m.isNegative ? "over" : "left").hType(.footnote).foregroundStyle(HColor.textSecondary)
      }
    case .done:
      Label("Done", systemImage: "checkmark").hType(.subheadline.weight(.semibold))
        .foregroundStyle(HColor.statusSuccessForeground)
    case .percent(let p):
      Text("\(p)%").hFigure(.row).foregroundStyle(HColor.textPrimary)
    }
  }
}

/// A category's month (in place of "Category detail" until it is built): the filtered list with its
/// pace summary, and the budget actions.
struct CategoryActivityView: View {
  @Bindable var app: AppModel
  let category: CategoryID
  let plan: any PlanModel
  @State private var model: ActivityViewModel?

  var body: some View {
    ScrollView {
      if let model {
        VStack(spacing: 20) {
          ActivityContent(model: model, showsChips: false)
          HStack(spacing: 8) {
            Button("Change budget") { plan.editBudget(category) }
              .buttonStyle(.pill(.primary, size: .medium, fill: true))
              .accessibilityIdentifier("category.changeBudget")
            Button("Move money in") { plan.moveMoney(to: category) }
              .buttonStyle(.pill(.tertiary, size: .medium, fill: true))
              .accessibilityIdentifier("category.moveMoney")
          }
          .padding(.horizontal, HSpacing.insetPage)
        }
        .padding(.vertical, 16)
      }
    }
    .background(alignment: .top) { AmbientWash(app.store.state.category(category)?.hue ?? .sky).ignoresSafeArea() }
    .background(HColor.surfaceSecondary)
    .navigationTitle(app.store.state.category(category)?.name ?? "Category")
    .navigationBarTitleDisplayMode(.inline)
    .overlay(alignment: .bottom) { ToastHost(app: app) }
    .onAppear {
      if model == nil { model = ActivityViewModel(app: app, filter: TxnFilter(category: category)) }
    }
  }
}

#if HASALA_MOCKS
  #Preview("Plan · October") {
    let app = AppModel(store: InMemoryLedger())
    PlanView(app: app, model: PlanViewModel(app: app))
  }
#endif
