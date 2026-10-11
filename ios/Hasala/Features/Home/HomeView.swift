import HasalaDesign
import HasalaModels
import SwiftUI

#if HASALA_MOCKS
  import HasalaMocks
#endif

/// Home · Default (Paper board): one question first, "am I okay this month?" The
/// hero shows what is left for everyday spending with its pace, then Needs you,
/// then the widgets Maya arranges.
struct HomeView: View {
  @Bindable var app: AppModel
  let model: any HomeModel
  @State private var path: [HomeRoute] = []
  @State private var topInset: CGFloat = 0

  private var snapshot: HomeSnapshot { model.snapshot }
  private var hidden: Bool { model.hidden }

  var body: some View {
    NavigationStack(path: $path) {
      ScrollView {
        VStack(alignment: .leading, spacing: HSpacing.gapScreenSection) {
          HeroSection(hero: snapshot.hero, hidden: hidden) { path.append(.insights) }
          NeedsYouSection(rail: snapshot.needsYou, hidden: hidden, seeAll: { path.append(.needsYou) }) { card, primary in
            if let route = model.needsYou(card, primary: primary) { path.append(route) }
          }
          WidgetCanvas(widgets: snapshot.widgets, hidden: hidden) { route in
            if case .widget(let id) = route {
              if let next = model.openWidget(id) { path.append(next) }
            } else {
              path.append(route)
            }
          }
        }
        .padding(.top, 24)
        .padding(.bottom, 32)
        .background(alignment: .top) {
          // The wash starts at the top of the screen, behind the header, and
          // scrolls away with the content (Paper: absolute, 420 tall).
          AmbientWash(snapshot.hero.wash, height: 420)
            .padding(.top, -topInset)
        }
      }
      .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { topInset = $0 }
      .scrollEdgeEffectStyle(.soft, for: .bottom)
      .background(HColor.surfaceSecondary)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        MainHeader(
          amountsHidden: hidden,
          extra: .bell(unread: snapshot.header.unreadNotifications),
          avatarInitial: snapshot.header.avatarInitial,
          onToggleAmounts: { app.toggleAmountsHidden() },
          onExtra: { path.append(.notifications) },
          onProfile: { app.showingProfile = true }
        )
      }
      .overlay(alignment: .bottom) { ToastHost(app: app) }
      .navigationDestination(for: HomeRoute.self) { route in
        if route == .bills {
          BillsScreen(app: app)
        } else {
          HomeRouteView(route: route)
        }
      }
    }
  }
}

// MARK: - Hero

/// The verdict line and the stat tiles stack vertically when they do not fit on one line,
/// and always at the accessibility text sizes (spec 04 §17); the hero figure stops growing
/// at `.accessibility3` (§14.4).
private struct HeroSection: View {
  let hero: EverydayHero
  let hidden: Bool
  let seeMonth: () -> Void
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 6) {
        Text(hero.overline).hType(.overline).foregroundStyle(HColor.textOnWashSecondary)
        MoneyText(hero.left, figure: .display, unit: .displayUnit, hidden: hidden, hiddenGlyphs: 6,
                  color: HColor.textPrimary)
          .accessibilityIdentifier("home.hero.left")
        Text(hero.caption).hType(.body).foregroundStyle(HColor.textOnWashSecondary)
      }

      VStack(alignment: .leading, spacing: 10) {
        PaceBar("Everyday spending", spent: hero.spent, today: hero.today, verdict: hero.verdict, onWash: true)
        // One line while it fits; otherwise the sentence and "See month" stack.
        if typeSize.isAccessibilitySize {
          verdictStacked
        } else {
          ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
              verdictDot
              verdictLabel
              verdictDetail(separated: true)
              Spacer(minLength: 4)
              seeMonthButton
            }
            verdictStacked
          }
        }
      }

      // Three tiles side by side while their labels and figures fit; stacked at the
      // accessibility sizes (spec 04 §17) or when they would truncate.
      if typeSize.isAccessibilitySize {
        statsStacked
      } else {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 8) {
            ForEach(hero.stats) { StatTile($0, hidden: hidden) }
          }
          statsStacked
        }
      }
    }
    .padding(.horizontal, HSpacing.insetPage)
  }

  private var verdictStacked: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        verdictDot
        verdictLabel
      }
      verdictDetail(separated: false)
      seeMonthButton
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var statsStacked: some View {
    VStack(spacing: 8) {
      ForEach(hero.stats) { StatTile($0, hidden: hidden) }
    }
  }

  private var verdictDot: some View {
    Circle().fill(hero.verdict.foreground).frame(width: 8, height: 8)
  }

  private var verdictLabel: some View {
    Text(hero.verdict.label).hType(.subheadline.weight(.semibold)).foregroundStyle(hero.verdict.foreground)
  }

  /// "· about AED 337 a day" on the verdict line; without the "·" on its own line.
  private func verdictDetail(separated: Bool) -> some View {
    Text((separated ? "· " : "") + hero.verdictDetail.rendered(hidden: hidden))
      .hType(.subheadline).foregroundStyle(HColor.textOnWashSecondary).singleLineAtDefaultTextSize()
      .accessibilityLabel(hero.verdictDetail.spoken(hidden: hidden))
  }

  /// A 20 pt line of text with a 44 pt target (spec 04 §17): the padding is inside the
  /// button and taken back outside it, so the layout does not move.
  private var seeMonthButton: some View {
    Button(action: seeMonth) {
      Text("See month")
        .hType(.subheadline.weight(.medium))
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(HColor.textOnWashLink)
    .padding(.vertical, -12)
    .accessibilityIdentifier("home.seeMonth")
  }
}

// MARK: - Needs you

/// A horizontal rail of brief cards; at the accessibility text sizes the cards are full
/// width, one under another (spec 04 §17).
private struct NeedsYouSection: View {
  let rail: NeedsYouRail
  let hidden: Bool
  let seeAll: () -> Void
  let act: (String, Bool) -> Void
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      SectionHeader("Needs you", count: rail.count, subtitle: rail.subtitle, actionTitle: "See all", action: seeAll)
        .padding(.horizontal, HSpacing.insetPage)
      if typeSize.isAccessibilitySize {
        VStack(spacing: 12) {
          ForEach(rail.cards) { card(for: $0) }
        }
        .padding(.horizontal, HSpacing.insetPage)
      } else {
        ScrollView(.horizontal) {
          HStack(alignment: .top, spacing: 12) {
            ForEach(rail.cards) { card(for: $0) }
          }
          .padding(.horizontal, HSpacing.insetPage)
          .padding(.bottom, 8)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
      }
    }
  }

  private func card(for c: NeedsYouCard) -> some View {
    BriefCard(c, hidden: hidden, onPrimary: { act(c.id, true) }, onSecondary: { act(c.id, false) })
  }
}

// MARK: - Widgets

/// Small widgets pair up two to a row; at the accessibility text sizes the canvas is one
/// column (spec 04 §17).
private struct WidgetCanvas: View {
  let widgets: [HomeWidget]
  let hidden: Bool
  let open: (HomeRoute) -> Void
  @Environment(\.dynamicTypeSize) private var typeSize

  private var rows: [[HomeWidget]] {
    typeSize.isAccessibilitySize ? widgets.map { [$0] } : widgets.canvasRows
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      SectionHeader("Your widgets", actionTitle: "Edit") { open(.editWidgets) }
      ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
        HStack(spacing: 12) {
          ForEach(row) { widget in
            Button { open(.widget(widget.id)) } label: { HomeWidgetView(widget, hidden: hidden) }
              .buttonStyle(.plain)
              .accessibilityIdentifier("widget.\(widget.id)")
          }
          if row.count == 1, row[0].size == .small, !typeSize.isAccessibilitySize {
            Color.clear.frame(maxWidth: .infinity)
          }
        }
        // Small widgets fill the row's height (at least 175 pt), so a pair stays even.
        .fixedSize(horizontal: false, vertical: true)
      }
      AddWidgetTile { open(.editWidgets) }
        .padding(.top, 12)
    }
    .padding(.horizontal, HSpacing.insetPage)
  }
}

/// Bills with its view model kept for as long as it is pushed.
struct BillsScreen: View {
  @Bindable var app: AppModel
  var showsToast = true
  @State private var model: BillsViewModel

  init(app: AppModel, showsToast: Bool = true) {
    self.app = app
    self.showsToast = showsToast
    _model = State(initialValue: BillsViewModel(app: app))
  }

  var body: some View { BillsView(app: app, model: model, showsToast: showsToast) }
}

/// Placeholder destinations until those screens are built.
// TODO(spec 04 §16.1 "Insights", §16.2 H1 Needs you list, H2 widget gallery, H3
// notifications list; "Accounts", "Project detail", P4 Goal).
private struct HomeRouteView: View {
  let route: HomeRoute

  var body: some View {
    let (title, image): (String, String) =
      switch route {
      case .insights: ("October so far", "chart.line.uptrend.xyaxis")
      case .needsYou: ("Needs you", "tray.full")
      case .notifications: ("Notifications", "bell")
      case .widget: ("Details", "square.grid.2x2")
      case .editWidgets: ("Your widgets", "square.grid.2x2")
      case .bills: ("Bills", "doc.text")
      }
    ScrollView {
      PlaceholderCard(systemImage: image, title: title, message: "This screen comes in a later build.")
        .padding(HSpacing.insetPage)
    }
    .background(HColor.surfaceSecondary)
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
  }
}

/// Floats the app's toast above the tab bar.
struct ToastHost: View {
  let app: AppModel

  var body: some View {
    if let toast = app.toast {
      GlassToast(systemImage: toast.systemImage, title: toast.title, subtitle: toast.subtitle,
                 actionTitle: toast.actionTitle) { app.toastAction() }
        .padding(.horizontal, HSpacing.insetPage)
        .padding(.bottom, 12)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityIdentifier("toast")
    }
  }
}

#if HASALA_MOCKS
  #Preview("Home · Default") {
    MainView(app: AppModel(store: InMemoryLedger()))
  }

  #Preview("Home · Amounts hidden") {
    MainView(app: AppModel(store: InMemoryLedger(), amountsHidden: true))
  }
#endif
