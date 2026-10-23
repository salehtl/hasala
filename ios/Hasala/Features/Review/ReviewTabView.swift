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
  @Environment(\.dynamicTypeSize) private var typeSize
  @Environment(AccountSession.self) private var session: AccountSession?
  @AppStorage(CloudSortDismissal.key) private var dismissedRun = 0
  @State private var cloudSortAnswered = false
  @State private var foregrounds = SortSlot.Foregrounds()

  init(app: AppModel) {
    self.app = app
  }

  var body: some View {
    NavigationStack(path: Bindable(app.router).review) {
      let cards = app.reviewCards
      let items = app.reviewItems
      let elsewhere = app.reviewElsewhere
      let isThisMonth = app.period == .month(app.store.now.date.yearMonth)
      let unread = ReviewEngine.unreadCount(app.store.state)
      TabScreen(app: app, title: "Review", spacing: 24, titleGap: 4) {
        Text(Self.countLine(items, elsewhere: elsewhere, period: app.period.title))
          .hType(.subheadline)
          .foregroundStyle(HColor.textSecondary)
          .accessibilityLabel(ReviewEngine.toSortSpoken(items) ?? Self.countLine(items, elsewhere: elsewhere, period: app.period.title))
          .accessibilityIdentifier("review.tab.count")
      } content: {
        let slot = SortSlot.of(SortSlot.Facts(
          asks: asksCloudSort, status: app.cloudSort?.status, dismissedRun: Int64(dismissedRun),
          importing: app.mailbox?.importing, suggestions: app.suggestionCount))
        VStack(alignment: .leading, spacing: 24) {
          if !cards.isEmpty || elsewhere != nil || !isThisMonth { periodRow(elsewhere, isThisMonth: isThisMonth) }
          if let row = app.sortResult {
            SortResultRowView(
              row: row, undo: { app.undoSortResult() }, stopRule: { app.stopSortResultRule() }, dismiss: { app.dismissSortResult() })
          }
          slotCard(slot)
          if cards.isEmpty {
            caughtUp(elsewhere)
          } else {
            startCard
          }
          if unread > 0 { unreadable(unread) }
          if !items.isEmpty { list(items) }
        }
        .padding(.horizontal, HSpacing.insetPage)
        .onChange(
          of: SortSlot.offerSeen(slot, onReview: app.tab == .review, phase: scenePhase, covered: app.router.cover != nil),
          initial: true
        ) { _, seen in
          if seen { app.cloudSort?.offerShown() }
        }
      }
      .navigationDestination(for: ReviewRoute.self) { route in
        switch route {
        case .unreadMail: UnreadMailView(app: app)
        }
      }
      .onChange(of: app.tab == .review, initial: true) { _, open in
        guard open, let sort = app.cloudSort else { return }
        sort.reviewOpened()
        Task { await sort.refresh() }
      }
      .task { await app.cloudSort?.refresh() }
      .onChange(of: cards.count) {
        app.cloudSort?.countsChanged()
      }
      .onChange(of: scenePhase) { _, phase in
        guard foregrounds.note(phase), let sort = app.cloudSort else { return }
        if app.tab == .review { sort.reviewOpened() }
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

  static func countLine(_ items: [ReviewItem], elsewhere: ReviewElsewhere? = nil, period: String = "") -> String {
    guard let line = ReviewEngine.toSortLine(items) else {
      return elsewhere == nil ? "All caught up" : "Nothing to sort in \(period)"
    }
    return line
  }

  static let emptyLine = "New transactions Hasala can't sort on its own show up here."

  static func orderLine(months: Int, grouped: Bool = false) -> String {
    if months > 1 { return "Newest month first" }
    return grouped ? "Most payments first" : "Oldest first"
  }

  @ViewBuilder private func slotCard(_ slot: SortSlot?) -> some View {
    switch slot {
    case .ask?:
      CloudSortAskCard(turnOn: turnOnCloudSort, notNow: cloudSortNotNow)
    case .importing(let mail)?:
      importingCard(mail, queued: !app.reviewCards.isEmpty)
    case let slot?:
      if let sort = app.cloudSort, let state = slot.card {
        CloudSortCard(app: app, sort: sort, state: state) {
          dismissedRun = Int(sort.status.lastRunEndedMs ?? 0)
        }
        .background(cardSurface)
      }
    case nil:
      EmptyView()
    }
  }

  private func importingCard(_ mail: MailImport, queued: Bool) -> some View {
    let disc = Circle().fill(HColor.reviewSuggestionSurface).frame(width: 32, height: 32)
      .overlay { HIconView(.envelope, size: 16, color: HColor.actionAccent, strokeWidth: 2) }
    let text = VStack(alignment: .leading, spacing: 4) {
      Text(SortSlot.importingTitle(mail))
        .hType(.headline)
        .foregroundStyle(HColor.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
      Text(SortSlot.importingLine(mail, queued: queued))
        .hType(.footnote)
        .foregroundStyle(HColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    return Group {
      if typeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 12) {
          HStack(alignment: .center, spacing: 12) {
            disc
            Spacer(minLength: 0)
            if mail.busy { Spinner(size: 20, track: HColor.feedbackProgressTrack) }
          }
          text
        }
      } else {
        HStack(alignment: .top, spacing: 12) {
          disc
          text
          if mail.busy { Spinner(size: 20, track: HColor.feedbackProgressTrack) }
        }
      }
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(cardSurface)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(SortSlot.importingSpoken(mail, queued: queued))
    .accessibilityAddTraits(.updatesFrequently)
    .accessibilityIdentifier("review.slot.importing")
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
        BackToThisMonthLink { app.period = .month(app.store.now.date.yearMonth) }
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
          Text("Need, want or save. One card per merchant.")
            .hType(.footnote)
            .foregroundStyle(HColor.textSecondary)
            .frame(maxWidth: 200, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
        CardStackArt()
      }
      Button("Start") { ReviewEntry.open(app, at: nil) }
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

  private func list(_ items: [ReviewItem]) -> some View {
    let months = ReviewEngine.itemMonths(items, now: app.store.now)
    let grouped = items.contains { if case .group = $0 { true } else { false } }
    return VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline) {
        Text("To sort").hType(.subheadline.weight(.semibold)).foregroundStyle(HColor.textPrimary)
          .accessibilityAddTraits(.isHeader)
        Spacer()
        Text(Self.orderLine(months: months.count, grouped: grouped)).hType(.footnote).foregroundStyle(HColor.textSecondary)
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
        ForEach(month.items) { item in
          let r = ReviewEngine.tabRow(item, app.store.state)
          Button { ReviewEntry.open(app, at: r.item) } label: { row(r) }
            .buttonStyle(HRowPressStyle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(r.spoken(hidden: app.amountsHidden))
            .accessibilityHint("Opens the cards")
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier(r.identifier)
        }
      }
    }
    .padding(.top, 14)
    .padding(.horizontal, 16)
    .padding(.bottom, 8)
    .background(cardSurface)
  }

  private func row(_ r: ReviewTabRow) -> some View {
    let text = VStack(alignment: .leading, spacing: 0) {
      Text(r.title).hType(.subheadline.weight(.semibold)).foregroundStyle(HColor.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
      Text(r.subtitle)
        .hType(HType(size: 13, leading: 16, weight: r.tone == .reason ? .medium : .regular, textStyle: .footnote))
        .foregroundStyle(r.reason.map(ReviewReasonStyle.ink) ?? tone(r.tone))
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    let trailing = VStack(alignment: typeSize.isAccessibilitySize ? .leading : .trailing, spacing: 0) {
      PhraseText(r.amount, hidden: app.amountsHidden)
        .hFigure(.compact)
        .foregroundStyle(r.isIncome ? HColor.moneyIn : HColor.moneyOut)
      if !r.detail.isEmpty {
        Text(r.detail)
          .hType(HType(size: 13, leading: 16, weight: .regular, textStyle: .footnote))
          .foregroundStyle(HColor.textSecondary)
      }
    }
    return Group {
      if typeSize.isAccessibilitySize {
        HStack(alignment: .top, spacing: 12) {
          MerchantMonogram(letter: r.monogram, size: 32, ring: false)
          VStack(alignment: .leading, spacing: 4) {
            text
            trailing
          }
        }
      } else {
        HStack(spacing: 12) {
          MerchantMonogram(letter: r.monogram, size: 32, ring: false)
          text
          trailing.fixedSize()
        }
      }
    }
    .frame(minHeight: 56)
    .contentShape(Rectangle())
  }

  private func tone(_ t: ReviewTabRow.Tone) -> Color {
    switch t {
    case .reason: HColor.statusWarningForeground
    case .suggestion: HColor.actionAccent
    case .decide: HColor.textSecondary
    }
  }

  static func supporting(_ card: ReviewCardModel) -> String { ReviewEngine.rowSupporting(card) }

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
    let disc = Circle().fill(Color(HRGBA(0xFF, 0xF3, 0xDC, 1))).frame(width: 32, height: 32)
      .overlay { HIconView(.envelope, size: 16, color: Color(HRGBA(0x9A, 0x64, 0x00, 1)), strokeWidth: 2) }
    let text = VStack(alignment: .leading, spacing: 0) {
      Text(Self.unreadableLine(n))
        .hType(.subheadline.weight(.semibold)).foregroundStyle(HColor.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
      Text(detail)
        .hType(HType(size: 13, leading: 16, weight: .regular, textStyle: .footnote))
        .foregroundStyle(HColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    return Group {
      if typeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 12) {
          disc
          text
        }
      } else {
        HStack(spacing: 12) {
          disc
          text
          if chevron {
            HIconView(.chevronRight, size: HSpacing.iconSmall, color: HColor.iconSecondary)
          }
        }
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
