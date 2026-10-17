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
  let extra: MainHeader.Extra
  var onExtra: () -> Void
  var wash: HWash
  /// Between the title block and each section (Paper 32; Review draws 24).
  var spacing: CGFloat
  /// Between the large title and what sits under it (Paper 10; Review's count line 4).
  var titleGap: CGFloat
  @ViewBuilder let header: () -> Header
  @ViewBuilder let content: () -> Content

  init(
    app: AppModel, title: String?, extra: MainHeader.Extra, onExtra: @escaping () -> Void = {},
    wash: HWash = .onTrack, spacing: CGFloat = HSpacing.gapScreenSection, titleGap: CGFloat = 10,
    @ViewBuilder header: @escaping () -> Header, @ViewBuilder content: @escaping () -> Content
  ) {
    self.app = app
    self.title = title
    self.extra = extra
    self.onExtra = onExtra
    self.wash = wash
    self.spacing = spacing
    self.titleGap = titleGap
    self.header = header
    self.content = content
  }

  @State private var topInset: CGFloat = 0
  @State private var overscroll: CGFloat = 0

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: spacing) {
        if let title {
          VStack(alignment: .leading, spacing: titleGap) {
            Text(title)
              .hType(.largeTitle)
              .foregroundStyle(HColor.textPrimary)
              .accessibilityAddTraits(.isHeader)
            header()
          }
          .padding(.horizontal, HSpacing.insetPage)
        }
        content()
      }
      .padding(.top, 20)
      .padding(.bottom, HSpacing.scrollContentBottom)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(alignment: .top) {
        // The wash starts at the top of the screen, behind the header, and scrolls away with
        // the content (Paper: absolute, 420 tall). A pull past the top doesn't drag it down:
        // it stays where it is while the content moves.
        AmbientWash(wash).padding(.top, -topInset).offset(y: -overscroll)
      }
    }
    .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { topInset = $0 }
    .trackingOverscroll($overscroll)
    .refreshable { [app] in await app.refresh() }
    .scrollEdgeEffectStyle(.soft, for: .bottom)
    .background(HColor.surfaceSecondary)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      MainHeader(
        amountsHidden: app.amountsHidden,
        extra: extra,
        avatarInitial: app.avatarInitial,
        onToggleAmounts: { app.toggleAmountsHidden() },
        onExtra: onExtra,
        onProfile: { app.showingProfile = true }
      )
    }
    .overlay(alignment: .bottom) { ToastHost(app: app) }
  }
}

extension TabScreen where Header == EmptyView {
  init(
    app: AppModel, title: String?, extra: MainHeader.Extra, onExtra: @escaping () -> Void = {},
    wash: HWash = .onTrack, spacing: CGFloat = HSpacing.gapScreenSection, titleGap: CGFloat = 10,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.init(app: app, title: title, extra: extra, onExtra: onExtra, wash: wash, spacing: spacing,
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
