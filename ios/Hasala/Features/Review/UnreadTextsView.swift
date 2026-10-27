import HasalaDesign
import HasalaModels
import SwiftUI

struct UnreadTextsView: View {
  @Bindable var app: AppModel
  @Environment(\.dynamicTypeSize) private var typeSize
  @State private var pasting = false

  var body: some View {
    let texts = ReviewEngine.unreadTexts(app.store.state)
    let canPaste = app.offersBankTextPaste && app.bankTexts != nil
    PushedPage(app: app, title: "Bank texts", spacing: 16) {
      if texts.isEmpty {
        EmptyNote(systemImage: "checkmark.circle", message: "Every bank text is accounted for.")
          .padding(.horizontal, HSpacing.insetPage)
          .accessibilityIdentifier("unreadTexts.empty")
      } else {
        Text(Self.intro)
          .hType(.subheadline).foregroundStyle(HColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, HSpacing.insetPage)
          .accessibilityIdentifier("unreadTexts.intro")
        ForEach(texts) { card($0, today: app.store.now.date, canPaste: canPaste) }
      }
    }
    .sheet(isPresented: $pasting) {
      if let lane = app.bankTexts {
        PasteBankTextSheet(lane: lane, hidden: app.amountsHidden) { app.say("Added to Review") }
      }
    }
  }

  static let intro = "Hasala couldn't turn these texts into a payment. Paste each one again, add it yourself, or dismiss one you don't need."

  private func card(_ m: UnreadText, today: LocalDate, canPaste: Bool) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 12) {
        Circle().fill(Color(HRGBA(0xFF, 0xF3, 0xDC, 1))).frame(width: 32, height: 32)
          .overlay { HIconView(.chat, size: 16, color: Color(HRGBA(0x9A, 0x64, 0x00, 1)), strokeWidth: 2) }
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 0) {
          Text(ReviewEngine.unreadTextTitle(m)).hType(.subheadline.weight(.semibold)).foregroundStyle(HColor.textPrimary)
          Text(ReviewEngine.unreadTextDetail(m, today: today))
            .hType(HType(size: 13, leading: 16, weight: .regular, textStyle: .footnote))
            .foregroundStyle(HColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .accessibilityElement(children: .combine)
      Text(ReviewEngine.unreadTextBody(m, today: today, canPaste: canPaste))
        .hType(.subheadline).foregroundStyle(HColor.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("unreadTexts.body.\(m.id)")
      let layout = typeSize.isAccessibilitySize
        ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
      layout {
        if canPaste {
          Button("Paste text") { pasting = true }
            .buttonStyle(.pill(.primary, fill: true))
            .pillHeight()
            .accessibilityIdentifier("unreadTexts.paste.\(m.id)")
        } else {
          addButton(m, .primary)
        }
        Button("Dismiss") { app.perform(.archive(m.id, true)) }
          .buttonStyle(.pill(.secondary, fill: true))
          .pillHeight()
          .accessibilityIdentifier("unreadTexts.dismiss.\(m.id)")
      }
      if canPaste { addButton(m, .tertiary) }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .listCard()
    .padding(.horizontal, HSpacing.insetPage)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("unreadTexts.row.\(m.id)")
  }

  private func addButton(_ m: UnreadText, _ kind: PillButtonStyle.Kind) -> some View {
    Button("Add it myself") { app.router.open(.addFromEmail(m.id)) }
      .buttonStyle(.pill(kind, fill: true))
      .pillHeight()
      .accessibilityIdentifier("unreadTexts.add.\(m.id)")
  }
}
