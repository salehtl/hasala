import HasalaDesign
import HasalaModels
import SwiftUI

/// A tab's root screen (Paper "Template · Tab screen" K2-0; Plan · October, Activity ·
/// Overview, Review · Tab): the main header on the system bar, the wash that scrolls away
/// with the content, then a column 20 under the header: the large title block (34/40 bold,
/// with what sits under it, `header`, 10 below: the period pill or a count line), and the
/// sections, 32 apart. The column ends 160 above the bottom so the last card clears the tab
/// bar, under the soft scroll edge. Pull to refresh, and the toast 14 above the bar.
///
/// Home has no title (`title: nil`): it leads with the figure.
struct TabScreen<Header: View, Content: View>: View {
  @Bindable var app: AppModel
  let title: String?
  var wash: HWash
  /// Between the title block and each section (Paper 32; Review draws 24).
  var spacing: CGFloat
  /// Between the large title and what sits under it (Paper 10; Review's count line 4).
  var titleGap: CGFloat
  @ViewBuilder let header: () -> Header
  @ViewBuilder let content: () -> Content

  init(
    app: AppModel, title: String?,
    wash: HWash = .onTrack, spacing: CGFloat = HSpacing.gapScreenSection, titleGap: CGFloat = 10,
    @ViewBuilder header: @escaping () -> Header, @ViewBuilder content: @escaping () -> Content
  ) {
    self.app = app
    self.title = title
    self.wash = wash
    self.spacing = spacing
    self.titleGap = titleGap
    self.header = header
    self.content = content
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: spacing) {
        if let title {
          VStack(alignment: .leading, spacing: titleGap) {
            HStack(alignment: .center, spacing: 8) {
              Text(title)
                .hType(.largeTitle)
                .foregroundStyle(HColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
              Spacer(minLength: 0)
              SyncStatus(syncing: app.sync.isSyncing)
            }
            header()
          }
          .padding(.horizontal, HSpacing.insetPage)
        }
        content()
          .environment(\.periodRowSyncing, title == nil ? app.sync.isSyncing : nil)
      }
      .padding(.top, 20)
      .padding(.bottom, HSpacing.scrollContentBottom)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    // The wash starts at the top of the screen, behind the bar, and scrolls away with the
    // content (Paper: absolute, 420 tall); a pull or a refresh doesn't carry it down.
    .washBehind(wash)
    .settlesAfterRefresh()
    .refreshable { [app] in await app.pull() }
    .scrollEdgeEffectStyle(.soft, for: .bottom)
    .background(HColor.surfaceSecondary)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      MainHeader(
        amountsHidden: app.amountsHidden,
        unread: app.bellCount,
        avatarInitial: app.avatarInitial,
        avatarEmail: app.avatarEmail,
        onToggleAmounts: { app.toggleAmountsHidden() },
        onSearch: { app.router.open(.search) },
        onNotifications: { app.router.open(.notifications) },
        onProfile: { app.showingProfile = true }
      )
    }
    .overlay(alignment: .bottom) { ToastHost(app: app) }
  }
}

nonisolated enum RefreshSettle {
  static func isStuck(contentOffset: CGFloat, insetTop: CGFloat) -> Bool {
    contentOffset < -insetTop - 0.5
  }
}

private struct SettlesAfterRefresh: ViewModifier {
  @State private var position = ScrollPosition(edge: .top)
  @State private var stuck = false
  @State private var phase = ScrollPhase.idle
  @State private var settling = false
  @Environment(\.hMotion) private var policy
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    content
      .scrollPosition($position)
      .onScrollGeometryChange(for: Bool.self) { geo in
        RefreshSettle.isStuck(contentOffset: geo.contentOffset.y, insetTop: geo.contentInsets.top)
      } action: { _, value in
        stuck = value
        if !value { settling = false }
        settle()
      }
      .onScrollPhaseChange { _, value in
        phase = value
        settle()
      }
  }

  private func settle() {
    guard stuck, phase == .idle, !settling else { return }
    settling = true
    let still = policy.isStill || reduceMotion
    Task { @MainActor in
      guard stuck, phase == .idle else {
        settling = false
        return
      }
      withAnimation(still ? nil : HMotion.easeOutSoft(HMotion.sheetContent)) {
        position.scrollTo(edge: .top)
      }
    }
  }
}

extension View {
  fileprivate func settlesAfterRefresh() -> some View {
    modifier(SettlesAfterRefresh())
  }
}

struct SyncStatus: View {
  let syncing: Bool

  var body: some View {
    ZStack(alignment: .trailing) {
      if syncing {
        SyncStatusLabel()
          .hTransition(.fade)
      }
    }
    .hAnimation(.fade, value: syncing)
  }
}

private struct SyncStatusLabel: View {
  var compact = false

  var body: some View {
    HStack(spacing: 6) {
      ProgressView().controlSize(.mini)
      if !compact {
        Text("Updating…").hType(.footnote).foregroundStyle(HColor.textSecondary)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(SyncActivity.startedMessage)
    .accessibilityIdentifier("sync.status")
  }
}

extension EnvironmentValues {
  @Entry var periodRowSyncing: Bool? = nil
}

struct BackToThisMonthLink: View {
  var tint: Color = HColor.textLink
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text("Back to this month")
        .hType(.subheadline.weight(.medium))
        .foregroundStyle(tint)
        .frame(minHeight: HSpacing.targetMinimum)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

struct PeriodRowTrailing<Link: View>: View {
  var hasLink: Bool
  @ViewBuilder let link: () -> Link
  @Environment(\.periodRowSyncing) private var syncing

  var body: some View {
    HStack(spacing: 12) {
      if syncing == true {
        SyncStatusLabel(compact: hasLink)
          .frame(minHeight: HSpacing.targetMinimum)
          .hTransition(.fade)
      }
      if hasLink { link() }
    }
    .hAnimation(.fade, value: syncing)
  }
}

extension TabScreen where Header == EmptyView {
  init(
    app: AppModel, title: String?,
    wash: HWash = .onTrack, spacing: CGFloat = HSpacing.gapScreenSection, titleGap: CGFloat = 10,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.init(app: app, title: title, wash: wash, spacing: spacing,
              titleGap: titleGap, header: { EmptyView() }, content: content)
  }
}

extension HWash {
  /// The wash for a screen's hue: sky, sand and rose are the three verdict washes (on track,
  /// over pace, over budget); the other hues tint a category or project.
  init(_ hue: Hue) {
    switch hue {
    case .sky: self = .onTrack
    case .sand: self = .overPace
    case .rose: self = .overBudget
    default: self = .hue(hue)
    }
  }
}
