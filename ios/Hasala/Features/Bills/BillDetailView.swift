import HasalaDesign
import HasalaModels
import SwiftUI

/// One bill (Paper "Bills · AXA Insurance (late)" 1UD-0), pushed from Bills, Home, Activity's
struct BillDetailView: View {
  @Bindable var app: AppModel
  let bill: BillID
  @State private var model: BillsViewModel
  @State private var sheet: RecurringSheet?
  @State private var confirmDelete = false
  @Environment(\.dismiss) private var dismiss
  @Environment(\.dynamicTypeSize) private var typeSize

  init(app: AppModel, bill: BillID) {
    self.app = app
    self.bill = bill
    _model = State(initialValue: BillsViewModel(app: app))
  }

  private var unfinished: Bool { BuildSurface.showsUnfinished }

  var body: some View {
    let detail = model.detail(bill)
    PushedPage(app: app, title: detail?.name ?? "Bill", wash: Self.wash(detail)) {
      if let detail {
        hero(detail).padding(.horizontal, HSpacing.insetPage)
        if !detail.banners.isEmpty { banners(detail).padding(.horizontal, HSpacing.insetPage) }
        ForEach(detail.notices) { notice in
          noticeCard(notice, detail).padding(.horizontal, HSpacing.insetPage)
        }
        if let noticed = detail.noticed { noticedCard(noticed).padding(.horizontal, HSpacing.insetPage) }
        if !detail.history.isEmpty { history(detail).padding(.horizontal, HSpacing.insetPage) }
        actions(detail).padding(.horizontal, HSpacing.insetPage)
      } else {
        EmptyNote(systemImage: "doc.text", message: "This bill is no longer tracked.")
          .padding(.horizontal, HSpacing.insetPage)
      }
    }
    .toolbar {
      if let detail, !detail.isIncome {
        ToolbarItem(placement: .topBarTrailing) { manageMenu(detail) }
      }
    }
    .sheet(item: $sheet) { RecurringSheetHost(app: app, sheet: $0) }
    .alert(deleteTitle(detail), isPresented: $confirmDelete) {
      Button(detail?.source == .manual ? "Delete" : "Not a bill", role: .destructive) {
        if model.perform(.deleteBill(bill)) { dismiss() }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(detail?.source == .manual
        ? "It leaves Recurring. Its payments stay in Activity."
        : "Hasala won't suggest it again. Its payments stay in Activity.")
    }
  }

  private func deleteTitle(_ d: BillDetail?) -> String {
    d?.source == .manual ? "Delete \(d?.name ?? "this item")?" : "\(d?.name ?? "This") is not a bill?"
  }

  private func manageMenu(_ d: BillDetail) -> some View {
    Menu {
      if !d.isEnded {
        Button { sheet = .editAmount(d.id) } label: { Label("Edit amount…", systemImage: "pencil") }
          .accessibilityIdentifier("bills.manage.editAmount")
        if d.isPaused {
          Button { model.perform(.resumeBill(d.id)) } label: { Label("Resume", systemImage: "play") }
            .accessibilityIdentifier("bills.manage.resume")
        } else {
          Button { sheet = .pause(d.id) } label: { Label("Pause…", systemImage: "pause") }
            .accessibilityIdentifier("bills.manage.pause")
        }
        Button { sheet = .end(d.id) } label: { Label("End…", systemImage: "stop") }
          .accessibilityIdentifier("bills.manage.end")
      } else {
        Button { model.perform(.reactivateBill(d.id)) } label: {
          Label("Start tracking again", systemImage: "arrow.clockwise")
        }
        .accessibilityIdentifier("bills.manage.reactivate")
      }
      Button { sheet = .link(d.id) } label: { Label("Link past payments…", systemImage: "link") }
        .accessibilityIdentifier("bills.manage.link")
      Divider()
      Button(role: .destructive) { confirmDelete = true } label: {
        Label(d.source == .manual ? "Delete" : "Not a bill", systemImage: "trash")
      }
      .accessibilityIdentifier("bills.manage.delete")
    } label: {
      HIconView(.more, size: HSpacing.iconGlass, color: HColor.iconGlass)
    }
    .accessibilityLabel("Manage")
    .accessibilityIdentifier("bills.detail.manage")
  }

  private func banners(_ d: BillDetail) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(d.banners) { banner in
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          HIconView(Self.icon(banner.icon), size: 18, color: HColor.iconPrimary)
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
          PhraseText(banner.text, hidden: model.hidden)
            .hType(.subheadline.weight(.semibold))
            .foregroundStyle(HColor.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("bills.detail.banner.\(banner.id)")
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.tile, style: .continuous))
  }

  static func icon(_ icon: BillBannerIcon) -> HIcon {
    switch icon {
    case .clock: .clock
    case .calendar: .calendar
    case .tag: .tag
    }
  }

  private func noticeCard(_ n: BillNoticeCard, _ d: BillDetail) -> some View {
    BillCard(
      hue: Self.hue(n.tone), glyph: .icon(d.glyph.icon), name: d.name, pill: StatusPill(n.title, tone: n.tone),
      amount: Self.figure(n, d), message: n.body, hidden: model.hidden,
      primary: .init(title: Self.title(n.primary, short: typeSize.isAccessibilitySize), id: Self.primaryID(n)) {
        run(n.primary.action, n, d)
      },
      secondary: n.secondary.map { b in
        .init(title: b.title, id: "bills.notice.\(n.id).secondary") { run(b.action, n, d) }
      },
      id: "bills.notice.\(n.id)")
  }

  static func hue(_ tone: StatusTone) -> Hue {
    switch tone {
    case .error: .rose
    case .warning: .sand
    case .accent, .success: .sky
    }
  }

  static func figure(_ n: BillNoticeCard, _ d: BillDetail) -> Money {
    if case .acceptPrice(let amount, _) = n.primary.action { return amount }
    return d.amount
  }

  static func title(_ b: BillNoticeCard.Button, short: Bool) -> String {
    if short, case .acceptPrice = b.action { return "Accept" }
    return b.title
  }

  static func primaryID(_ n: BillNoticeCard) -> String {
    if case .acceptPrice = n.primary.action { return "bills.detail.accept" }
    return "bills.notice.\(n.id).primary"
  }

  private func run(_ action: BillNoticeCard.Action, _ n: BillNoticeCard, _ d: BillDetail) {
    switch action {
    case .acceptPrice(let amount, let from):
      model.perform(.editBillAmount(d.id, amount, approximate: d.approximate, from: from))
    case .resume:
      model.perform(.resumeBill(d.id))
    case .reactivate:
      model.perform(.reactivateBill(d.id))
    case .reapply:
      model.perform(.reapplyBill(d.id))
    case .dismiss:
      model.perform(.dismissBillNotice(d.id, noticeID: n.id))
    }
  }

  static func wash(_ detail: BillDetail?) -> HWash {
    switch detail?.state {
    case .late: .overBudget
    case .priceChange, .paused: .overPace
    default: .onTrack
    }
  }

  // MARK: Hero

  /// The 56 disc with its white ring and the status pill, then the kind, the figure and how
  /// often it comes ("every month · usually the 7th · Emirates NBD").
  private func hero(_ d: BillDetail) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 12) {
        CategoryDisc(hue: d.hue, glyph: d.glyph, size: .s56, ring: true)
        StatusPillView(d.pill, size: .s32, surface: .white)
      }
      VStack(alignment: .leading, spacing: 4) {
        Text(d.kind).hType(.overline).foregroundStyle(HColor.textOnWashSecondary)
        HStack(alignment: .firstTextBaseline, spacing: 0) {
          if d.approximate && !model.hidden {
            Text(verbatim: "~").hFigure(.large).foregroundStyle(HColor.textPrimary)
          }
          MoneyText(d.amount, figure: .large, unit: .unit, hidden: model.hidden, hiddenGlyphs: 4,
                    color: d.isIncome ? HColor.moneyIn : HColor.textPrimary, unitGap: 6,
                    sign: d.isIncome ? .income : .none)
        }
        Text(d.cadence).hType(.subheadline).foregroundStyle(HColor.textOnWashSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("bills.detail.\(d.id)")
    }
    .padding(.top, 4)
  }

  // MARK: What we noticed

  private func noticedCard(_ noticed: MoneyPhrase) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        HIconView(.magnifier, size: 20, color: HColor.iconPrimary, strokeWidth: 1.9)
        Text("What we noticed").hType(.body.weight(.semibold)).foregroundStyle(HColor.textPrimary)
          .accessibilityAddTraits(.isHeader)
      }
      PhraseText(noticed, hidden: model.hidden)
        .hType(.subheadline)
        .foregroundStyle(HColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.trailing, 24)
    }
    .padding(.top, 18)
    .padding(.horizontal, 20)
    .padding(.bottom, 20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.tile, style: .continuous))
    .accessibilityElement(children: .combine)
  }

  // MARK: Payment history

  private func history(_ d: BillDetail) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HSectionHeader("Payment history", trailing: d.historyNote.map { .fact($0) } ?? .none)
      VStack(spacing: 0) {
        ForEach(Array(d.history.enumerated()), id: \.element.id) { index, step in
          TimelineStep(step: step, first: index == 0, last: index == d.history.count - 1, hidden: model.hidden)
        }
      }
      .padding(.vertical, 8)
      .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
    }
  }

  // MARK: Actions

  @ViewBuilder private func actions(_ d: BillDetail) -> some View {
    VStack(spacing: 16) {
      VStack(spacing: 10) {
        if d.isIncome {
          Button("Edit salary") { sheet = .salary(d.id) }
            .buttonStyle(.pill(.primary, fill: true))
            .pillHeight()
            .accessibilityIdentifier("bills.detail.editSalary")
        } else {
          if d.isLate {
            Button("I paid it — find the payment") { model.markPaid(d.id) }
              .buttonStyle(.pill(.primary, fill: true))
              .pillHeight()
              .accessibilityIdentifier("bills.detail.paid")
            if unfinished {
              Button("Remind me tomorrow") { model.remind(d.id) }
                .buttonStyle(.pill(.secondary, fill: true))
                .pillHeight()
                .accessibilityIdentifier("bills.detail.remind")
            }
          }
          if d.isPriceChange && !d.hasPriceNotice {
            Button("Accept new amount") { model.acceptAmount(d.id) }
              .buttonStyle(.pill(.primary, fill: true))
              .pillHeight()
              .accessibilityIdentifier("bills.detail.accept")
          }
          if d.isPaused {
            Button("Resume") { model.perform(.resumeBill(d.id)) }
              .buttonStyle(.pill(.primary, fill: true))
              .pillHeight()
              .accessibilityIdentifier("bills.detail.resume")
          }
          if d.isEnded {
            Button("Start tracking again") { model.perform(.reactivateBill(d.id)) }
              .buttonStyle(.pill(.primary, fill: true))
              .pillHeight()
              .accessibilityIdentifier("bills.detail.reactivate")
          } else {
            Button { sheet = .end(d.id) } label: {
              Text("It's cancelled — end it")
                .hType(.button)
                .foregroundStyle(HColor.actionDestructive)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("bills.detail.end")
          }
        }
      }
      .padding(.top, 16)
      .padding(.horizontal, 16)
      .padding(.bottom, 8)
      .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
      Text(d.footnote)
        .hType(.footnote)
        .foregroundStyle(HColor.textSecondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, typeSize.isAccessibilitySize ? 0 : 56)
    }
  }
}

/// One step of the payment history (1UD-0 · Timeline card): a 24 rail lane with the node (a
/// red ring and dot for the payment that hasn't come, a tinted ring for one still due, a green
/// tick for a paid one) on a 2 pt line, then the date, its note and the amount. 64 tall with a
/// note, 52 without. One VoiceOver stop.
private struct TimelineStep: View {
  let step: BillHistoryStep
  let first: Bool
  let last: Bool
  let hidden: Bool

  var body: some View {
    HStack(spacing: 14) {
      Color.clear.frame(width: 24)
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
          Text(step.title).hType(.rowTitle).foregroundStyle(HColor.listRowTitle)
          if let note = step.note {
            Text(note).hType(.footnote.weight(.semibold)).foregroundStyle(noteColor)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if let amount = step.amount {
          MoneyText(amount, figure: .row, hidden: hidden, hiddenGlyphs: 3,
                    color: step.kind == .paid ? HColor.moneyOut : HColor.textSecondary)
            .fixedSize()
        }
      }
      .padding(.vertical, 6)
    }
    .frame(minHeight: step.note == nil ? HSpacing.listRowMinHeight : HSpacing.listRowMinHeightTwoLine)
    .background(alignment: .leading) { rail }
    .padding(.horizontal, HSpacing.listRowInsetInline)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(spoken)
  }

  private var rail: some View {
    VStack(spacing: 0) {
      Rectangle().fill(first ? Color.clear : HColor.borderSubtle).frame(width: 2)
      node
      Rectangle().fill(last ? Color.clear : HColor.borderSubtle).frame(width: 2)
    }
    .frame(width: 24)
  }

  @ViewBuilder private var node: some View {
    switch step.kind {
    case .expected(let late):
      let tone: StatusTone = late ? .error : .accent
      Circle()
        .fill(tone.surface)
        .overlay { Circle().strokeBorder(tone.foreground, lineWidth: 2) }
        .overlay { Circle().fill(tone.foreground).frame(width: 8, height: 8) }
        .frame(width: 24, height: 24)
    case .paid:
      Circle()
        .fill(HColor.statusSuccessForeground)
        .overlay { HIconView(.check, size: 14, color: HColor.white, strokeWidth: 3) }
        .frame(width: 24, height: 24)
    }
  }

  private var noteColor: Color {
    if case .expected(true) = step.kind { return HColor.statusErrorForeground }
    return HColor.textSecondary
  }

  /// "Wed 7 Oct, Expected · no bank email yet, AED 550.00" / "Mon 7 Sep, paid, AED 550.00".
  private var spoken: String {
    let amount = step.amount.map { hidden ? "Amount hidden" : "\($0.currency) \(MoneyFormat.string($0.minor))" }
    return [step.title, step.note ?? "paid", amount].compactMap { $0 }.joined(separator: ", ")
  }
}
