import HasalaDesign
import HasalaModels
import SwiftUI

/// Review · Tab · To sort (Paper NPV-0): the root of the Review tab, the queue Hasala
/// couldn't sort and the card that starts the swipe deck. Its queue covers `AppModel.reviewWindow`
/// (Home's period, this month unless another is chosen), and the tab's badge counts the same transactions
/// (`AppModel.reviewCount`).
///
/// Start opens the deck at the oldest card; a row opens it at that row's card and reads on
/// down the list. "Use N suggestions" is Debug only, and the "couldn't read" card opens only
/// in Debug: the first would be several edits in one gesture and the second needs Add a
/// transaction, neither of which exists yet (plan D.2).
struct ReviewTabView: View {
  @Bindable var app: AppModel
  @Environment(\.dynamicTypeSize) private var typeSize

  init(app: AppModel) {
    self.app = app
  }

  var body: some View {
    NavigationStack {
      let cards = ReviewEngine.cards(app.store.state, in: app.reviewWindow)
      TabScreen(app: app, title: "Review", spacing: 24, titleGap: 4) {
        Text(Self.countLine(cards.count))
          .hType(.subheadline)
          .foregroundStyle(HColor.textSecondary)
          .accessibilityIdentifier("review.tab.count")
      } content: {
        VStack(alignment: .leading, spacing: 24) {
          if cards.isEmpty {
            caughtUp
          } else {
            startCard(cards)
            list(cards)
          }
          if app.store.state.mailbox.unreadable > 0 {
            unreadable(app.store.state.mailbox.unreadable)
          }
        }
        .padding(.horizontal, HSpacing.insetPage)
      }
    }
  }

  /// "6 to sort · about a minute": about ten seconds a card.
  static func countLine(_ n: Int) -> String {
    guard n > 0 else { return "All caught up" }
    let minutes = (n + 5) / 6
    return "\(n) to sort · " + (minutes == 1 ? "about a minute" : "about \(minutes) minutes")
  }

  static func emptyLine(_ period: Period) -> String {
    "Nothing in \(period.title) needs a look."
  }

  // MARK: Start card

  /// "Swipe through them" over a sky tint, the fanned cards, Start, and in Debug "Use N
  /// suggestions" beside it. The pair are the kit's Large pills (54; Paper draws 50, a height
  /// the pill set doesn't have).
  private func startCard(_ cards: [ReviewCardModel]) -> some View {
    let suggestions = cards.filter { $0.suggestion != nil }.count
    return VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .top, spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Swipe through them")
            .hType(HType.title3.weight(.bold))
            .foregroundStyle(HColor.textPrimary)
            .accessibilityAddTraits(.isHeader)
          Text("Need, want or save. One card at a time.")
            .hType(.footnote)
            .foregroundStyle(HColor.textSecondary)
            .frame(maxWidth: 200, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
        CardStackArt()
      }
      // Side by side, stacked at the accessibility sizes: one layout, so the pills stay the
      // same views as the text grows.
      let layout = typeSize.isAccessibilitySize
        ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
      layout { startButtons(suggestions) }
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background {
      RoundedRectangle(cornerRadius: HRadius.widget, style: .continuous)
        .fill(HColor.widgetSurface)
        .overlay {
          RoundedRectangle(cornerRadius: HRadius.widget, style: .continuous)
            .fill(.linearGradient(
              Gradient(stops: [.init(color: Hue.sky.start, location: 0),
                               .init(color: HColor.white.opacity(0), location: 0.7)])
                .colorSpace(.perceptual),
              startPoint: UnitPoint(x: 0.33, y: 0), endPoint: UnitPoint(x: 0.67, y: 1)))
        }
        .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
        .shadow(color: .black.opacity(0.08), radius: 12, y: 8)
    }
  }

  @ViewBuilder
  private func startButtons(_ suggestions: Int) -> some View {
    Button("Start") { ReviewEntry.open(app, at: nil) }
      .buttonStyle(.pill(.primary, fill: true))
      .accessibilityIdentifier("review.tab.start")
    if BuildSurface.showsUnfinished, suggestions > 0 {
      // TODO(plan D.2 "Use N suggestions"): one gesture would author several edits.
      Button {
        app.say("Using every suggestion at once comes in a later build", icon: .info)
      } label: {
        // Paper sets this one smaller than Start (15/18 600, NTB-0) so the pair fits side by
        // side; on one line it may shrink a little more, and at the larger sizes it wraps
        // instead, as every pill does.
        Text("Use \(suggestions) suggestion\(suggestions == 1 ? "" : "s")")
          .hType(HType(size: 15, leading: 18, weight: .semibold, textStyle: .subheadline))
          .minimumScaleFactor(0.8)
      }
      .buttonStyle(.pill(.secondary, fill: true))
      .accessibilityIdentifier("review.tab.useSuggestions")
    }
  }

  // MARK: To sort

  /// "To sort", oldest first: each row opens the deck at its own card.
  private func list(_ cards: [ReviewCardModel]) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline) {
        Text("To sort").hType(.subheadline.weight(.semibold)).foregroundStyle(HColor.textPrimary)
          .accessibilityAddTraits(.isHeader)
        Spacer()
        // The queue runs oldest first, so nothing waits longest (Paper writes "Newest first").
        Text("Oldest first").hType(.footnote).foregroundStyle(HColor.textSecondary)
      }
      .padding(.bottom, 4)
      ForEach(cards) { card in
        Button { ReviewEntry.open(app, at: card.id) } label: { row(card) }
          .buttonStyle(HRowPressStyle())
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(spoken(card))
          .accessibilityHint("Opens the deck at this one")
          .accessibilityAddTraits(.isButton)
          .accessibilityIdentifier("review.tab.row.\(card.id)")
      }
    }
    .padding(.top, 14)
    .padding(.horizontal, 16)
    .padding(.bottom, 8)
    .background(cardSurface)
  }

  /// Monogram 32 (no ring), name 15/20 600 over "Looks like Groceries" in accent (or what the
  /// person decides, in grey), the amount 15/20 bold. 52 tall.
  private func row(_ card: ReviewCardModel) -> some View {
    HStack(spacing: 12) {
      MerchantMonogram(letter: card.monogram, size: 32, ring: false)
      VStack(alignment: .leading, spacing: 0) {
        Text(card.merchant).hType(.subheadline.weight(.semibold)).foregroundStyle(HColor.textPrimary)
          .fixedSize(horizontal: false, vertical: true)
        Text(Self.supporting(card))
          .hType(HType(size: 13, leading: 16, weight: card.reviewReason != nil ? .medium : .regular, textStyle: .footnote))
          .foregroundStyle(supportingColor(card))
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      MoneyText(card.amount, figure: .compact, hidden: app.amountsHidden, hiddenGlyphs: 3,
                color: card.isIncome ? HColor.moneyIn : HColor.moneyOut, sign: card.isIncome ? .income : .none)
        .fixedSize()
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

  private func supportingColor(_ card: ReviewCardModel) -> Color {
    if let reason = card.reviewReason { return ReviewReasonStyle.ink(reason) }
    return card.suggestion == nil ? HColor.textSecondary : HColor.actionAccent
  }

  /// "Looks like Groceries", or what the person decides.
  static func supporting(_ card: ReviewCardModel) -> String {
    if let reason = card.reviewReason { return "\(reason.label) · you decide" }
    if let s = card.suggestion { return "Looks like \(s.name)" }
    if card.isIncome { return "Income or a transfer?" }
    return card.isNewMerchant ? "New merchant · you decide" : "You decide"
  }

  // MARK: Others

  /// Nothing to sort: good news, said plainly, with the way to everything that was sorted.
  private var caughtUp: some View {
    VStack(spacing: 12) {
      Circle().fill(HColor.statusSuccessSurface).frame(width: 56, height: 56)
        .overlay { HIconView(.check, size: 26, color: HColor.statusSuccessForeground, strokeWidth: 2.2) }
        .accessibilityHidden(true)
      Text("Nothing to sort").hType(HType.title3).foregroundStyle(HColor.textPrimary)
        .accessibilityAddTraits(.isHeader)
      Text(Self.emptyLine(app.period))
        .hType(.subheadline).foregroundStyle(HColor.textSecondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.horizontal, 24)
    .padding(.top, 28)
    .padding(.bottom, 24)
    .frame(maxWidth: .infinity)
    .background(cardSurface)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("review.tab.empty")
  }

  /// "1 bank email we couldn't read · Add the amount yourself": a button in Debug until Add a
  /// transaction exists; Release shows the count alone.
  @ViewBuilder private func unreadable(_ n: Int) -> some View {
    if BuildSurface.showsUnfinished {
      Button {
        // TODO(plan D.2 "Add a transaction"): add the amount from the unread email.
        app.say("Adding the amount yourself comes in a later build", icon: .info)
      } label: {
        unreadableRow(n, detail: "Add the amount yourself", chevron: true)
      }
      .buttonStyle(HRowPressStyle())
      .accessibilityIdentifier("review.tab.unreadable")
    } else {
      unreadableRow(n, detail: "Kept for you to sort by hand", chevron: false)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("review.tab.unreadable")
    }
  }

  static func unreadableLine(_ n: Int) -> String {
    "\(n) bank email\(n == 1 ? "" : "s") we couldn't read"
  }

  private func unreadableRow(_ n: Int, detail: String, chevron: Bool) -> some View {
    HStack(spacing: 12) {
      Circle().fill(Color(HRGBA(0xFF, 0xF3, 0xDC, 1))).frame(width: 32, height: 32)
        .overlay { HIconView(.envelope, size: 16, color: Color(HRGBA(0x9A, 0x64, 0x00, 1)), strokeWidth: 2) }
      VStack(alignment: .leading, spacing: 0) {
        Text(Self.unreadableLine(n))
          .hType(.subheadline.weight(.semibold)).foregroundStyle(HColor.textPrimary)
        Text(detail)
          .hType(HType(size: 13, leading: 16, weight: .regular, textStyle: .footnote))
          .foregroundStyle(HColor.textSecondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if chevron {
        HIconView(.chevronRight, size: HSpacing.iconSmall, color: HColor.iconSecondary)
      }
    }
    .padding(.vertical, 14)
    .padding(.horizontal, 16)
    .background(cardSurface)
    .contentShape(Rectangle())
  }

  /// The tab's cards: widget white, radius 26, near and far shadows.
  private var cardSurface: some View {
    RoundedRectangle(cornerRadius: HRadius.widget, style: .continuous)
      .fill(HColor.widgetSurface)
      .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
      .shadow(color: .black.opacity(0.08), radius: 12, y: 8)
  }
}
