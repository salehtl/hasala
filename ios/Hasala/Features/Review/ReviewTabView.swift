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
  @Environment(\.dynamicTypeSize) private var typeSize
  @Environment(AccountSession.self) private var session: AccountSession?
  @State private var cloudSortAnswered = false
  @State private var pastingText = false

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
        let slot = SortSlot.of(SortSlot.Facts(asks: asksCloudSort, status: app.cloudSort?.status, importing: app.mailbox?.importing))
        VStack(alignment: .leading, spacing: 24) {
          if !cards.isEmpty || elsewhere != nil || !isThisMonth { periodRow(elsewhere, isThisMonth: isThisMonth) }
          slotCard(slot)
          if cards.isEmpty {
            caughtUp(elsewhere)
          } else {
            startCard
          }
          if unread > 0 { unreadable(unread) }
          if !app.store.state.unreadTexts.isEmpty { unreadTexts(app.store.state.unreadTexts.count) }
          if app.offersBankTextPaste { pasteTextRow }
          if !cards.isEmpty { list(cards) }
        }
        .padding(.horizontal, HSpacing.insetPage)
      }
      .navigationDestination(for: ReviewRoute.self) { route in
        switch route {
        case .unreadMail: UnreadMailView(app: app)
        case .unreadTexts: UnreadTextsView(app: app)
        }
      }
      .onChange(of: cards.count) {
        app.cloudSort?.countsChanged()
      }
    }
    .onAppear {
      #if HASALA_MOCKS
        if BankTextsLaunch.takeOpenPaste() { pastingText = true }
      #endif
      takePasteRequest()
    }
    .onChange(of: app.router.pasteBankText) { _, _ in takePasteRequest() }
    .sheet(isPresented: $pastingText) {
      if let lane = app.bankTexts {
        PasteBankTextSheet(lane: lane, hidden: app.amountsHidden) { app.say("Added to Review") }
      }
    }
  }

  private func takePasteRequest() {
    guard app.router.pasteBankText else { return }
    app.router.pasteBankText = false
    if app.offersBankTextPaste { pastingText = true }
  }

  private var pasteTextRow: some View {
    Button { pastingText = true } label: {
      HStack(spacing: 12) {
        Circle().fill(HColor.actionAccentSubtle).frame(width: 32, height: 32)
          .overlay { HIconView(.paper, size: 16, color: HColor.actionAccent, strokeWidth: 2) }
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 0) {
          Text("Paste a bank text")
            .hType(.subheadline.weight(.semibold)).foregroundStyle(HColor.textPrimary)
          Text(BankTexts.pasteDetail(usesTexts: app.usesBankTexts))
            .hType(HType(size: 13, leading: 16, weight: .regular, textStyle: .footnote))
            .foregroundStyle(HColor.textSecondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        if !typeSize.isAccessibilitySize {
          HIconView(.chevronRight, size: HSpacing.iconSmall, color: HColor.iconSecondary)
        }
      }
      .padding(.vertical, 14)
      .padding(.horizontal, 16)
      .background(cardSurface)
      .contentShape(Rectangle())
    }
    .buttonStyle(HRowPressStyle())
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
    .accessibilityIdentifier("review.tab.pasteText")
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
    app.say("Cloudflare AI is on. It sorts a few names at a time, mostly while Hasala is open.", icon: .cloud)
  }

  private func cloudSortNotNow() {
    session?.services.cloudSort?.notNow()
    cloudSortAnswered = true
  }

  static func countLine(_ n: Int, elsewhere: ReviewElsewhere? = nil, period: String = "") -> String {
    guard n > 0 else { return elsewhere == nil ? "All caught up" : "Nothing to sort in \(period)" }
    return "\(MoneyFormat.count(n)) to sort · " + timeLine(minutes: (n + 5) / 6)
  }

  static func timeLine(minutes: Int) -> String {
    if minutes == 1 { return "about a minute" }
    if minutes <= 60 { return "about \(minutes) minutes" }
    let hours = (minutes + 30) / 60
    return hours == 1 ? "about an hour" : "about \(MoneyFormat.count(hours)) hours"
  }

  static let emptyLine = "New transactions Hasala can't sort on its own show up here."

  static func orderLine(months: Int) -> String {
    months > 1 ? "Newest month first" : "Oldest first"
  }

  @ViewBuilder private func slotCard(_ slot: SortSlot?) -> some View {
    switch slot {
    case .ask?:
      CloudSortAskCard(turnOn: turnOnCloudSort, notNow: cloudSortNotNow)
    case .importing(let mail)?:
      importingCard(mail, queued: !app.reviewCards.isEmpty)
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
          Text("Need, want or save. One card at a time.")
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
          let r = ReviewEngine.tabRow(card, app.store.state)
          Button { ReviewEntry.open(app, at: r.id) } label: { row(r) }
            .buttonStyle(HRowPressStyle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(r.spoken(hidden: app.amountsHidden))
            .accessibilityHint("Opens the deck at this one")
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
        unreadableRow(Self.unreadableLine(n), detail: Self.unreadableDetail)
      }
      .buttonStyle(HRowPressStyle())
      .accessibilityHint("Opens Add a transaction")
      .accessibilityIdentifier("review.tab.unreadable")
    } else {
      Button {
        app.router.review.append(.unreadMail)
      } label: {
        unreadableRow(Self.unreadableLine(n), detail: "Add each one by hand or dismiss it")
      }
      .buttonStyle(HRowPressStyle())
      .accessibilityIdentifier("review.tab.unreadable")
    }
  }

  static let unreadableDetail = "Add it yourself from your bank app"

  static let unreadTextsDetail = "Paste each one again, or add it yourself"

  private func unreadTexts(_ n: Int) -> some View {
    Button {
      app.router.review.append(.unreadTexts)
    } label: {
      unreadableRow(
        ReviewEngine.unreadTextLine(n), detail: app.offersBankTextPaste ? Self.unreadTextsDetail : "Add each one by hand or dismiss it",
        icon: .chat)
    }
    .buttonStyle(HRowPressStyle())
    .accessibilityIdentifier("review.tab.unreadTexts")
  }

  static func unreadableLine(_ n: Int) -> String { ReviewEngine.unreadLine(n) }

  private func unreadableRow(_ title: String, detail: String, icon: HIcon = .envelope) -> some View {
    let disc = Circle().fill(Color(HRGBA(0xFF, 0xF3, 0xDC, 1))).frame(width: 32, height: 32)
      .overlay { HIconView(icon, size: 16, color: Color(HRGBA(0x9A, 0x64, 0x00, 1)), strokeWidth: 2) }
    let text = VStack(alignment: .leading, spacing: 0) {
      Text(title)
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
          HIconView(.chevronRight, size: HSpacing.iconSmall, color: HColor.iconSecondary)
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
