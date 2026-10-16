import HasalaDesign
import HasalaModels
import SwiftUI

/// One bill (Paper "Bills · AXA Insurance (late)" 1UD-0), pushed from Bills, Home, Activity's
/// "Coming up" and Profile › Bills: the hero in the bill's wash (rose may be late, sand changed
/// price, sky otherwise), what we noticed, the payment history, and what can be done.
///
/// A bill that may be late offers "I paid it — find the payment" (it marks the payment, as
/// Bills' "I paid it" does) and "It's cancelled — stop tracking" (after a confirm); "Remind me
/// tomorrow" is Debug only until reminders exist. A price change offers "Accept new amount".
/// Income is read only. Paper's "More" (•••) has nothing drawn behind it, so it isn't here.
struct BillDetailView: View {
  @Bindable var app: AppModel
  let bill: BillID
  @State private var model: BillsViewModel
  @State private var confirmStop = false
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
        if let noticed = detail.noticed { noticedCard(noticed).padding(.horizontal, HSpacing.insetPage) }
        if !detail.history.isEmpty { history(detail).padding(.horizontal, HSpacing.insetPage) }
        actions(detail).padding(.horizontal, HSpacing.insetPage)
      } else {
        EmptyNote(systemImage: "doc.text", message: "This bill is no longer tracked.")
          .padding(.horizontal, HSpacing.insetPage)
      }
    }
    .alert("Stop tracking \(detail?.name ?? "this bill")?", isPresented: $confirmStop) {
      Button("Stop tracking", role: .destructive) {
        model.stopTracking(bill)
        dismiss()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("It leaves Bills and Coming up. Its past payments stay in Activity.")
    }
  }

  static func wash(_ detail: BillDetail?) -> HWash {
    switch detail?.state {
    case .late: .overBudget
    case .priceChange: .overPace
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
      if !d.isIncome {
        VStack(spacing: 10) {
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
          if d.isPriceChange {
            Button("Accept new amount") { model.acceptAmount(d.id) }
              .buttonStyle(.pill(.primary, fill: true))
              .pillHeight()
              .accessibilityIdentifier("bills.detail.accept")
          }
          Button { confirmStop = true } label: {
            Text("It's cancelled — stop tracking")
              .hType(.button)
              .foregroundStyle(HColor.actionDestructive)
              .multilineTextAlignment(.center)
              .frame(maxWidth: .infinity, minHeight: 48)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("bills.detail.stop")
        }
        .padding(.top, 16)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
      }
      // Paper's footnote is 56 in from the actions' 20 (76 from the screen's edge), so its
      // two lines break where the board's do.
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
        MoneyText(step.amount, figure: .row, hidden: hidden, hiddenGlyphs: 3,
                  color: step.kind == .paid ? HColor.moneyOut : HColor.textSecondary)
          .fixedSize()
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
    let amount = hidden ? "Amount hidden" : "\(step.amount.currency) \(MoneyFormat.string(step.amount.minor))"
    return [step.title, step.note ?? "paid", amount].joined(separator: ", ")
  }
}
