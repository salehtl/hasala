import HasalaDesign
import HasalaModels
import SwiftUI

/// Review · All caught up (Paper 4MY-0): the result, not a party. The mint disc, "6 sorted ·
/// 3 new rules", what the plan now counts and every line this session sorted, then "See
/// activity". The last sort stays undoable in the toast; Undo brings its card back.
///
/// The disc settles in once a session (the motion policy lets "All caught up" celebrate,
/// 600 ms at most); with Reduce Motion it fades in. No haptic: the person's last sort already
/// had its tap (plan B1.4).
struct ReviewDoneView: View {
  let model: any ReviewDeckModel
  @State private var shown = false
  @Environment(\.hMotion) private var policy
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

  private var motion: MotionPolicy {
    MotionPolicy(reduceMotion: policy.reduceMotion || systemReduceMotion, settled: policy.settled)
  }

  var body: some View {
    let sorted = model.sorted
    let rules = sorted.filter(\.learnedRule).count
    ScrollView {
      VStack(spacing: 0) {
        badge
          .padding(.top, 22)
        Text("All caught up")
          .hType(.title1)
          .foregroundStyle(HColor.textPrimary)
          .multilineTextAlignment(.center)
          .padding(.top, 16)
          .accessibilityAddTraits(.isHeader)
          .accessibilityIdentifier("review.done")
        Text(Self.tally(sorted: sorted.count, rules: rules))
          .hType(.subheadline)
          .foregroundStyle(HColor.textSecondary)
          .multilineTextAlignment(.center)
          .padding(.top, 4)
          .accessibilityIdentifier("review.done.tally")
        VStack(spacing: 16) {
          if !sorted.isEmpty { summary(sorted) }
          Button("See activity") { model.close(goToActivity: true) }
            .buttonStyle(.pill(.primary, fill: true))
            .accessibilityIdentifier("review.seeActivity")
        }
        .padding(.top, 22)
      }
      .padding(.horizontal, HSpacing.insetPage)
      // Clear of the toast, which sits on the bottom safe area.
      .padding(.bottom, HSpacing.toastHeight + 40)
    }
    .scrollBounceBehavior(.basedOnSize)
    .onAppear(perform: settle)
  }

  /// "6 sorted · 3 new rules", "1 sorted", or nothing sorted in this session.
  static func tally(sorted: Int, rules: Int) -> String {
    guard sorted > 0 else { return "Nothing waiting to sort." }
    return "\(sorted) sorted" + (rules > 0 ? " · \(rules) new rule\(rules == 1 ? "" : "s")" : "")
  }

  /// The mint disc (72, check 34 at 2.4, soft mint shadow).
  private var badge: some View {
    Circle()
      .fill(Hue.mint.perceptualGradient)
      .frame(width: 72, height: 72)
      .shadow(color: Color(HRGBA(0x16, 0x4A, 0x35, 0.10)), radius: 12, y: 8)
      .overlay { HIconView(.check, size: 34, color: Hue.mint.ink) }
      .scaleEffect(shown || motion.isStill ? 1 : HMotion.chipPopScale)
      .opacity(shown ? 1 : 0)
      .accessibilityHidden(true)
  }

  private func settle() {
    guard !shown else { return }
    let celebrate = !model.celebrated
    model.celebrated = true
    withAnimation(celebrate ? motion.animation(.celebrate) : nil) { shown = true }
  }

  /// "Your plan now counts AED 327.28 more", then each sorted line.
  private func summary(_ sorted: [SortedLine]) -> some View {
    let counted = sorted.reduce(Int64(0)) { $0 + $1.counted }
    return VStack(alignment: .leading, spacing: 0) {
      header(counted: .aed(counted))
        .padding(.top, 2)
        .padding(.bottom, 12)
        .overlay(alignment: .bottom) { HColor.borderSubtle.frame(height: 1) }
      VStack(spacing: 0) {
        ForEach(Array(sorted.enumerated()), id: \.element.id) { i, line in
          if i > 0 {
            HColor.borderSubtle.frame(height: 1).padding(.leading, 44).accessibilityHidden(true)
          }
          row(line)
        }
      }
      .padding(.top, 2)
    }
    .padding(.top, 16)
    .padding(.horizontal, 16)
    .padding(.bottom, 6)
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
    .hElevation(.nearFar)
  }

  private func header(counted: Money) -> some View {
    let phrase = MoneyPhrase([.text("Your plan now counts "), .text("AED "), .amount(counted), .text(" more")])
    return Text("\(Text("Your plan now counts ").foregroundStyle(HColor.textSecondary))\(figure(counted))\(Text(" more").foregroundStyle(HColor.textSecondary))")
      .hType(.subheadline)
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityLabel(phrase.spoken(hidden: model.hidden))
  }

  /// "AED 327.28" in the compact figure face, dots when amounts are hidden.
  private func figure(_ m: Money) -> Text {
    let digits = model.hidden ? MoneyFormat.hidden(count: 4) : MoneyFormat.string(m.minor)
    return Text("AED \(digits)")
      .font(.system(.subheadline, design: .rounded, weight: .bold).monospacedDigit())
      .foregroundStyle(HColor.textPrimary)
  }

  /// Disc 32, name 15/20 600 over the category 13/16, amount 15/20 bold.
  private func row(_ line: SortedLine) -> some View {
    HStack(spacing: 12) {
      CategoryDisc(hue: line.hue, icon: line.glyph.icon, size: .s32)
      VStack(alignment: .leading, spacing: 0) {
        Text(line.merchant).hType(.subheadline.weight(.semibold)).foregroundStyle(HColor.textPrimary)
          .fixedSize(horizontal: false, vertical: true)
        Text(line.detail).hType(.footnote).foregroundStyle(HColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      MoneyText(line.amount, figure: .compact, hidden: model.hidden, hiddenGlyphs: 3,
                color: line.isIncome ? HColor.moneyIn : HColor.moneyOut, sign: line.isIncome ? .income : .none)
        .fixedSize()
    }
    .frame(minHeight: 48)
    .accessibilityElement(children: .combine)
  }
}
