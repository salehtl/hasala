import HasalaDesign
import SwiftUI

/// A tab whose screen is not built yet: the real header, a large title and the
/// sky wash (Paper board "Template · Tab screen"), with a placeholder card.
struct TabPlaceholder: View {
  @Bindable var app: AppModel
  let title: String
  let subtitle: String?
  let systemImage: String
  let message: String
  let extra: MainHeader.Extra
  let identifier: String

  @State private var topInset: CGFloat = 0

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          VStack(alignment: .leading, spacing: 8) {
            Text(title).hType(.largeTitle).foregroundStyle(HColor.textPrimary)
              .accessibilityAddTraits(.isHeader)
            if let subtitle {
              HStack(spacing: 4) {
                Text(subtitle).hType(.subheadline.weight(.semibold))
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
              }
              .foregroundStyle(HColor.textPrimary)
              .padding(.horizontal, 14)
              .frame(height: 36)
              .background(HColor.surfaceOnWash, in: Capsule())
            }
          }
          PlaceholderCard(systemImage: systemImage, title: "Coming soon", message: message)
            .accessibilityIdentifier(identifier)
        }
        .padding(.horizontal, HSpacing.insetPage)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .top) {
          AmbientWash(.sky).padding(.top, -topInset)
        }
      }
      .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { topInset = $0 }
      .background(HColor.surfaceSecondary)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        MainHeader(
          amountsHidden: app.amountsHidden,
          extra: extra,
          avatarInitial: app.snapshot.header.avatarInitial,
          onToggleAmounts: { app.toggleAmountsHidden() },
          onExtra: {},
          onProfile: { app.showingProfile = true }
        )
      }
      .overlay(alignment: .bottom) { ToastHost(app: app) }
    }
  }
}
