import HasalaDesign
import HasalaModels
import SwiftUI

/// Home · Notifications (Paper 11Y9-0): the bell's large sheet, "Needs a look" first, then
/// "Earlier". The bell counts the items that need a look; the Review tab's badge counts only
/// the transactions to sort.
///
/// The foundation's version (plan B7.3): Home's Needs-you cards as a read-only list.
// TODO(spec 10 §5): the NotificationsEngine items newest first, the mailbox item from
// `AppModel.mailOffer`, row taps that open their screen, "Earlier" (Debug), all clear.
struct NotificationsSheet: View {
  @Bindable var app: AppModel
  @Environment(\.dismiss) private var dismiss

  init(app: AppModel) {
    self.app = app
  }

  private var cards: [NeedsYouCard] { app.snapshot.needsYou.cards }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          SectionTitle(title: "Needs a look")
          if cards.isEmpty {
            EmptyNote(systemImage: "checkmark.circle", message: "All clear. Nothing needs a look.")
              .accessibilityIdentifier("bell.allClear")
          } else {
            ListCard {
              ForEach(cards) { card in
                VStack(alignment: .leading, spacing: 2) {
                  Text(card.title).hType(.rowTitle).foregroundStyle(HColor.listRowTitle)
                  PhraseText(card.subtitle, hidden: app.amountsHidden)
                    .hType(.footnote).foregroundStyle(HColor.listRowSupporting)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, HSpacing.listRowInsetInline)
                .frame(minHeight: HSpacing.listRowMinHeightTwoLine)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("bell.row.\(card.id)")
              }
            }
          }
        }
        .padding(HSpacing.insetPage)
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("bell.sheet")
      .background(HColor.surfaceSecondary)
      .navigationTitle("Notifications")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { SheetCloseButton(identifier: "bell.close") { dismiss() } }
    }
  }
}
