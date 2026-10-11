import HasalaDesign
import HasalaModels
import SwiftUI

#if HASALA_MOCKS
  import HasalaMocks
#endif

/// Pushed destinations from Home that are not built yet (spec 04 §13.2).
enum HomeRoute: Hashable {
  case insights, needsYou, notifications, widget(String), editWidgets
}

/// Home · Default (Paper board): one question first, "am I okay this month?" The
/// hero shows what is left for everyday spending with its pace, then Needs you,
/// then the widgets Maya arranges.
struct HomeView: View {
  @Bindable var app: AppModel
  @State private var path: [HomeRoute] = []
  @State private var topInset: CGFloat = 0

  private var snapshot: HomeSnapshot { app.snapshot }
  private var hidden: Bool { app.amountsHidden }

  var body: some View {
    NavigationStack(path: $path) {
      ScrollView {
        VStack(alignment: .leading, spacing: HSpacing.gapScreenSection) {
          HeroSection(hero: snapshot.hero, hidden: hidden) { path.append(.insights) }
          NeedsYouSection(rail: snapshot.needsYou, hidden: hidden) { path.append(.needsYou) }
          WidgetCanvas(widgets: snapshot.widgets, hidden: hidden) { path.append($0) }
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
        HomeRouteView(route: route)
      }
    }
  }
}

// MARK: - Hero

private struct HeroSection: View {
  let hero: EverydayHero
  let hidden: Bool
  let seeMonth: () -> Void

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
        PaceBar(spent: hero.spent, today: hero.today, verdict: hero.verdict, onWash: true)
        HStack(spacing: 6) {
          Circle().fill(hero.verdict.foreground).frame(width: 8, height: 8)
          Text(hero.verdict.label).hType(.subheadline.weight(.semibold)).foregroundStyle(hero.verdict.foreground)
          Text(hero.verdictDetail.rendered(hidden: hidden))
            .hType(.subheadline).foregroundStyle(HColor.textOnWashSecondary).lineLimit(1)
            .accessibilityLabel(hero.verdictDetail.spoken(hidden: hidden))
          Spacer(minLength: 4)
          Button("See month", action: seeMonth)
            .buttonStyle(.plain)
            .hType(.subheadline.weight(.medium))
            .foregroundStyle(HColor.textOnWashLink)
            .accessibilityIdentifier("home.seeMonth")
        }
      }

      HStack(spacing: 8) {
        ForEach(hero.stats) { StatTile($0, hidden: hidden) }
      }
    }
    .padding(.horizontal, HSpacing.insetPage)
  }
}

// MARK: - Needs you

private struct NeedsYouSection: View {
  let rail: NeedsYouRail
  let hidden: Bool
  let seeAll: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      SectionHeader("Needs you", count: rail.count, subtitle: rail.subtitle, actionTitle: "See all", action: seeAll)
        .padding(.horizontal, HSpacing.insetPage)
      ScrollView(.horizontal) {
        HStack(alignment: .top, spacing: 12) {
          ForEach(rail.cards) { BriefCard($0, hidden: hidden) }
        }
        .padding(.horizontal, HSpacing.insetPage)
        .padding(.bottom, 8)
      }
      .scrollIndicators(.hidden)
      .scrollClipDisabled()
    }
  }
}

// MARK: - Widgets

private struct WidgetCanvas: View {
  let widgets: [HomeWidget]
  let hidden: Bool
  let open: (HomeRoute) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      SectionHeader("Your widgets", actionTitle: "Edit") { open(.editWidgets) }
      ForEach(Array(widgets.canvasRows.enumerated()), id: \.offset) { _, row in
        HStack(spacing: 12) {
          ForEach(row) { widget in
            Button { open(.widget(widget.id)) } label: { HomeWidgetView(widget, hidden: hidden) }
              .buttonStyle(.plain)
              .accessibilityIdentifier("widget.\(widget.id)")
          }
          if row.count == 1, row[0].size == .small { Color.clear.frame(maxWidth: .infinity) }
        }
      }
      AddWidgetTile { open(.editWidgets) }
        .padding(.top, 12)
    }
    .padding(.horizontal, HSpacing.insetPage)
  }
}

/// Placeholder destinations until those screens are built.
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
    MainView(app: AppModel(snapshot: Maya.home))
  }

  #Preview("Home · Amounts hidden") {
    MainView(app: AppModel(snapshot: Maya.home, amountsHidden: true))
  }
#endif
