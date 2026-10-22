import HasalaDesign
import HasalaModels
import SwiftUI

/// Review · Tab · To sort (Paper NPV-0): the root of the Review tab, the queue Hasala
/// couldn't sort and the card that starts the swipe deck. With more than one month waiting, the
/// list runs the newest month first, each under its month.
///
/// Start opens the deck at the top of the list, the newest month's oldest card, and reads on
/// in the list's order; a row opens it at that row's card and reads on down the list. The
/// "couldn't read" line counts the bank emails Hasala kept as empty rows and the ones it could
/// not download; when there are rows, it opens the list where each is added by hand or dismissed,
/// and with none it opens Add a transaction.
struct ReviewTabView: View {
  @Bindable var app: AppModel
  @Environment(\.scenePhase) private var scenePhase
  @Environment(AccountSession.self) private var session: AccountSession?
  @AppStorage(CloudSortDismissal.key) private var dismissedRun = 0
  @State private var cloudSortAnswered = false

  init(app: AppModel) {
    self.app = app
  }

  var body: some View {
    NavigationStack(path: Bindable(app.router).review) {
      let cards = app.reviewCards
      let elsewhere = app.reviewElsewhere
      let isThisMonth = app.period == .month(app.store.now.date.yearMonth)
      let unread = ReviewEngine.unreadCount(app.store.state)
      TabScreen(app: app, title: "Review", spacing: 24, titleGap: 4) {
        Text(Self.countLine(cards.count, elsewhere: elsewhere, period: app.period.title))
          .hType(.subheadline)
          .foregroundStyle(HColor.textSecondary)
          .accessibilityIdentifier("review.tab.count")
      } content: {
        let sortState = app.cloudSort.flatMap { CloudSortCardState.of($0.status, dismissedRun: Int64(dismissedRun)) }
        VStack(alignment: .leading, spacing: 24) {
          if !cards.isEmpty || elsewhere != nil || !isThisMonth { periodRow(elsewhere, isThisMonth: isThisMonth) }
          if let sort = app.cloudSort, let sortState {
            CloudSortCard(app: app, sort: sort, state: sortState) {
              dismissedRun = Int(sort.status.lastRunEndedMs ?? 0)
            }
            .background(cardSurface)
          }
          if cards.isEmpty {
            caughtUp(elsewhere)
            if unread > 0 { unreadable(unread) }
          } else {
            if sortState == nil, asksCloudSort {
              CloudSortAskCard(turnOn: turnOnCloudSort, notNow: cloudSortNotNow)
            }
            startCard
            if app.suggestionCount > 0, sortState?.offersCheckSuggestions != true {
              CheckSuggestionsEntry(app: app, count: app.suggestionCount).background(cardSurface)
            }
            if unread > 0 { unreadable(unread) }
            list(cards)
          }
        }
        .padding(.horizontal, HSpacing.insetPage)
      }
      .navigationDestination(for: ReviewRoute.self) { route in
        switch route {
        case .unreadMail: UnreadMailView(app: app)
        }
      }
      .task { await app.cloudSort?.refresh() }
      .onChange(of: scenePhase) { _, phase in
        guard phase == .active, let sort = app.cloudSort else { return }
        Task { await sort.refresh() }
      }
    }
  }

  private var asksCloudSort: Bool {
    guard !cloudSortAnswered, let session else { return false }
    return Self.asksCloudSort(session.services.cloudSort, reviewAccount: session.reviewAccount,
                              toSort: app.reviewCards.count)
  }

  static func asksCloudSort(_ cloud: CloudSortOffering?, reviewAccount: Bool, toSort: Int) -> Bool {
    guard toSort > 0, !reviewAccount, let cloud else { return false }
    return cloud.isOffered && !cloud.answered
  }

  private func turnOnCloudSort() {
    session?.services.cloudSort?.turnOn()
    cloudSortAnswered = true
    if let sort = app.cloudSort { Task { await sort.refresh() } }
    app.say("Cloudflare AI is on. It sorts a few names at a time while Hasala is open.", icon: .cloud)
  }

  private func cloudSortNotNow() {
    session?.services.cloudSort?.notNow()
    cloudSortAnswered = true
  }

  /// "6 to sort · about a minute": about ten seconds a card.
  static func countLine(_ n: Int, elsewhere: ReviewElsewhere? = nil, period: String = "") -> String {
    guard n > 0 else { return elsewhere == nil ? "All caught up" : "Nothing to sort in \(period)" }
    let minutes = (n + 5) / 6
    return "\(n) to sort · " + (minutes == 1 ? "about a minute" : "about \(minutes) minutes")
  }

  static let emptyLine = "New transactions Hasala can't sort on its own show up here."

  static func orderLine(months: Int) -> String {
    months > 1 ? "Newest month first" : "Oldest first"
  }

  // MARK: Period

  private func periodRow(_ elsewhere: ReviewElsewhere?, isThisMonth: Bool) -> some View {
    ReflowingRow(spacing: 12) {
      PeriodPill(app.period.title, tinted: !isThisMonth) { app.sheet = .period }
        .accessibilityIdentifier("review.tab.period")
    } trailing: {
      if let elsewhere {
        Button { app.period = elsewhere.widened } label: {
          Text(elsewhere.line)
            .hType(.subheadline.weight(.medium))
            .foregroundStyle(HColor.textLink)
            .frame(minHeight: HSpacing.targetMinimum)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows \(elsewhere.widened.title)")
        .accessibilityIdentifier("review.tab.elsewhere")
      } else if !isThisMonth {
        Button { app.period = .month(app.store.now.date.yearMonth) } label: {
          Text("Back to this month")
            .hType(.subheadline.weight(.medium))
            .foregroundStyle(HColor.textLink)
            .frame(minHeight: HSpacing.targetMinimum)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("review.tab.backToThisMonth")
      }
    }
  }

  // MARK: Start card

  /// "Swipe through them" over a sky tint, the fanned cards and Start, the kit's Large pill
  /// (54; Paper draws 50, a height the pill set doesn't have).
  private var startCard: some View {
    VStack(alignment: .leading, spacing: 16) {
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
      Button("Start") { ReviewEntry.open(app, at: nil, inPeriod: true) }
        .buttonStyle(.pill(.primary, fill: true))
        .accessibilityIdentifier("review.tab.start")
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

  // MARK: To sort

  /// "To sort", oldest first within a month (Paper writes "Newest first"): each row opens the
  /// deck at its own card.
  private func list(_ cards: [ReviewCardModel]) -> some View {
    let months = ReviewEngine.months(cards, now: app.store.now)
    return VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline) {
        Text("To sort").hType(.subheadline.weight(.semibold)).foregroundStyle(HColor.textPrimary)
          .accessibilityAddTraits(.isHeader)
        Spacer()
        Text(Self.orderLine(months: months.count)).hType(.footnote).foregroundStyle(HColor.textSecondary)
      }
      .padding(.bottom, 4)
      ForEach(months) { month in
        if months.count > 1 {
          Text(month.title)
            .hType(.footnote.weight(.semibold))
            .foregroundStyle(HColor.textSecondary)
            .padding(.top, 10)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("review.tab.month.\(month.month)")
        }
        ForEach(month.cards) { card in
          Button { ReviewEntry.open(app, at: card.id, inPeriod: true) } label: { row(card) }
            .buttonStyle(HRowPressStyle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spoken(card))
            .accessibilityHint("Opens the deck at this one")
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("review.tab.row.\(card.id)")
        }
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
  private func caughtUp(_ elsewhere: ReviewElsewhere?) -> some View {
    VStack(spacing: 12) {
      Circle().fill(HColor.statusSuccessSurface).frame(width: 56, height: 56)
        .overlay { HIconView(.check, size: 26, color: HColor.statusSuccessForeground, strokeWidth: 2.2) }
        .accessibilityHidden(true)
      Text(elsewhere == nil ? "Nothing to sort" : "Nothing to sort in \(app.period.title)")
        .hType(HType.title3).foregroundStyle(HColor.textPrimary)
        .multilineTextAlignment(.center)
        .accessibilityAddTraits(.isHeader)
      Text(elsewhere.map { "\($0.line)." } ?? Self.emptyLine)
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

  @ViewBuilder private func unreadable(_ n: Int) -> some View {
    if app.store.state.unreadMail.isEmpty {
      Button {
        app.router.open(.addTransaction)
      } label: {
        unreadableRow(n, detail: Self.unreadableDetail, chevron: true)
      }
      .buttonStyle(HRowPressStyle())
      .accessibilityHint("Opens Add a transaction")
      .accessibilityIdentifier("review.tab.unreadable")
    } else {
      Button {
        app.router.review.append(.unreadMail)
      } label: {
        unreadableRow(n, detail: "Add each one by hand or dismiss it", chevron: true)
      }
      .buttonStyle(HRowPressStyle())
      .accessibilityIdentifier("review.tab.unreadable")
    }
  }

  static let unreadableDetail = "Add it yourself from your bank app"

  static func unreadableLine(_ n: Int) -> String { ReviewEngine.unreadLine(n) }

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
