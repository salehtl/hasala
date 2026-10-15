import HasalaDesign
import HasalaModels
import SwiftUI

/// Review · Tab · To sort (Paper NPV-0): the root of the Review tab, the queue Hasala
/// couldn't sort and the Start button that opens the swipe deck. Its queue is always now:
/// no period pill, and the tab badge counts the same transactions.
///
/// The foundation's version (plan B7.3): the title, the count, Start and the list, on
/// today's parts. The to-sort rows don't open the deck at their card yet, and "Use N
/// suggestions" and the "couldn't read" card are not drawn.
struct ReviewTabView: View {
  @Bindable var app: AppModel

  init(app: AppModel) {
    self.app = app
  }

  private var cards: [ReviewCardModel] { ReviewEngine.cards(app.store.state) }

  var body: some View {
    NavigationStack {
      TabScreen(app: app, title: "Review", extra: .none) {
        let cards = cards
        VStack(alignment: .leading, spacing: 24) {
          Text(Self.countLine(cards.count))
            .hType(.subheadline)
            .foregroundStyle(HColor.textSecondary)
            .padding(.horizontal, HSpacing.insetPage)
            .padding(.top, -14)
            .accessibilityIdentifier("review.tab.count")
          if cards.isEmpty {
            EmptyNote(systemImage: "checkmark.circle", message: "Nothing to sort. New transactions show up here.")
              .padding(.horizontal, HSpacing.insetPage)
          } else {
            startCard
            list(cards)
          }
        }
      }
    }
  }

  /// "6 to sort · about a minute": about ten seconds a card.
  static func countLine(_ n: Int) -> String {
    guard n > 0 else { return "All caught up" }
    let minutes = (n + 5) / 6
    return "\(n) to sort · " + (minutes == 1 ? "about a minute" : "about \(minutes) minutes")
  }

  private var startCard: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Swipe through them").hType(.title3).foregroundStyle(HColor.textPrimary)
        Text("Need, want or save. One card at a time.").hType(.footnote).foregroundStyle(HColor.textSecondary)
      }
      Button("Start") { app.startReview() }
        .buttonStyle(.pill(.primary, fill: true))
        .accessibilityIdentifier("review.tab.start")
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .listCard()
    .padding(.horizontal, HSpacing.insetPage)
  }

  private func list(_ cards: [ReviewCardModel]) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline) {
        Text("To sort").hType(.rowTitle).foregroundStyle(HColor.textPrimary)
        Spacer()
        Text("Oldest first").hType(.footnote).foregroundStyle(HColor.textSecondary)
      }
      .padding(.bottom, 4)
      ForEach(cards) { card in
        // A row opens the deck (at its own card once the deck can start anywhere).
        Button { app.startReview() } label: { row(card) }
          .buttonStyle(.plain)
          .accessibilityLabel(spoken(card))
          .accessibilityIdentifier("review.tab.row.\(card.id)")
      }
    }
    .padding(.horizontal, 16)
    .padding(.top, 14)
    .padding(.bottom, 8)
    .listCard()
    .padding(.horizontal, HSpacing.insetPage)
  }

  private func row(_ card: ReviewCardModel) -> some View {
    HStack(spacing: 12) {
      MonogramDisc(card.monogram, size: 32)
      VStack(alignment: .leading, spacing: 0) {
        Text(card.merchant).hType(.rowTitle).foregroundStyle(HColor.textPrimary)
        Text(Self.supporting(card)).hType(.footnote)
          .foregroundStyle(card.suggestion == nil ? HColor.textSecondary : HColor.actionAccent)
      }
      Spacer(minLength: 8)
      MoneyText(card.amount, figure: .row, hidden: app.amountsHidden, hiddenGlyphs: 3,
                color: card.isIncome ? HColor.moneyIn : HColor.moneyOut, sign: card.isIncome ? .income : .none)
    }
    .frame(minHeight: 52)
    .contentShape(Rectangle())
  }

  private func spoken(_ card: ReviewCardModel) -> String {
    let amount = app.amountsHidden
      ? "Amount hidden"
      : (card.isIncome ? "plus " : "") + "\(card.amount.currency) \(MoneyFormat.string(card.amount.minor))"
    return [card.merchant, Self.supporting(card), amount].joined(separator: ", ")
  }

  /// "Looks like Groceries", or what the person decides.
  static func supporting(_ card: ReviewCardModel) -> String {
    if let s = card.suggestion { return "Looks like \(s.name)" }
    if card.isIncome { return "Income or a transfer?" }
    return card.isNewMerchant ? "New merchant · you decide" : "You decide"
  }
}
