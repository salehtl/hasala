import HasalaDesign
import HasalaModels
import SwiftUI

struct UnreadMailView: View {
  @Bindable var app: AppModel
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    let state = app.store.state
    let mail = ReviewEngine.unreadMail(state)
    let missed = ReviewEngine.notDownloaded(state)
    PushedPage(app: app, title: "Bank emails", spacing: 16) {
      if mail.isEmpty && missed == 0 {
        EmptyNote(systemImage: "checkmark.circle", message: "Every bank email is accounted for.")
          .padding(.horizontal, HSpacing.insetPage)
          .accessibilityIdentifier("unread.empty")
      } else {
        if !mail.isEmpty {
          Text(Self.intro)
            .hType(.subheadline).foregroundStyle(HColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, HSpacing.insetPage)
            .accessibilityIdentifier("unread.intro")
        }
        ForEach(mail) { card($0, today: app.store.now.date) }
        if missed > 0 {
          Text(ReviewEngine.notDownloadedLine(missed))
            .hType(.footnote).foregroundStyle(HColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, HSpacing.insetPage)
            .accessibilityIdentifier("unread.notDownloaded")
        }
      }
    }
  }

  static let intro = "Hasala couldn't turn these into a transaction. Add the amount yourself, or dismiss one you don't need."

  private func card(_ m: UnreadMail, today: LocalDate) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 12) {
        Circle().fill(Color(HRGBA(0xFF, 0xF3, 0xDC, 1))).frame(width: 32, height: 32)
          .overlay { HIconView(.envelope, size: 16, color: Color(HRGBA(0x9A, 0x64, 0x00, 1)), strokeWidth: 2) }
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 0) {
          Text(ReviewEngine.unreadTitle(m)).hType(.subheadline.weight(.semibold)).foregroundStyle(HColor.textPrimary)
          Text(ReviewEngine.unreadDetail(m, today: today))
            .hType(HType(size: 13, leading: 16, weight: .regular, textStyle: .footnote))
            .foregroundStyle(HColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .accessibilityElement(children: .combine)
      let layout = typeSize.isAccessibilitySize
        ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
      layout {
        Button("Add transaction") { app.router.open(.addFromEmail(m.id)) }
          .buttonStyle(.pill(.primary, fill: true))
          .pillHeight()
          .accessibilityIdentifier("unread.add.\(m.id)")
        Button("Dismiss") { app.perform(.archive(m.id, true)) }
          .buttonStyle(.pill(.secondary, fill: true))
          .pillHeight()
          .accessibilityIdentifier("unread.dismiss.\(m.id)")
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .listCard()
    .padding(.horizontal, HSpacing.insetPage)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("unread.row.\(m.id)")
  }
}
