import HasalaDesign
import HasalaModels
import SwiftUI

/// Setup · Done · You're set (Paper GWF-0): the coin badge, "You're set, Maya.", what is now
/// true, the one thing to keep safe, and one way on (page 17 §09: facts, not praise). The
/// badge lands once with the success haptic. No header and no way back.
struct DoneStep: View {
  var model: SetupModel

  var body: some View {
    CelebrationScreen(
      badge: .coin,
      title: model.firstName.isEmpty ? "You're set." : "You're set, \(model.firstName).",
      subtitle: "Your budget is worked out on this iPhone, and the key stays with you.",
      wash: .itWorks,
      successHaptic: true,
      spacing: (40, 28)
    ) {
      VStack(spacing: 12) {
        StepCard {
          ForEach(facts, id: \.self) { StepRow(text: $0, state: .done) }
        }
        KeepSafeCard()
      }
    } footer: {
      Button("Go to Home") { model.finish() }
        .buttonStyle(.pill(.primary, fill: true))
        .accessibilityIdentifier("done.home")
    }
  }

  /// What setup made true, in Paper's order: what was sorted, the plan, the sync, the Lock
  /// Screen. A step that was skipped has no line.
  private var facts: [String] {
    var lines: [String] = []
    if model.scanDone, let s = model.summary {
      lines.append("\(s.total) transactions sorted on this iPhone")
    } else if model.scan != nil {
      lines.append("Your bank alerts keep importing in the background")
    }
    if model.facts.planSet {
      let p = model.plan
      lines.append("\(model.today.yearMonth.name) plan ready, starting at \(p.needsPercent)/\(p.wantsPercent)/\(p.savingsPercent)")
    }
    if model.cloudSortOn {
      lines.append("Merchants Hasala doesn't know go to Cloudflare AI")
    }
    lines.append("Synced, end-to-end encrypted")
    lines.append(model.showDetails ? "Lock Screen shows amounts and merchants" : "Lock Screen shows no amounts or names")
    return lines
  }
}

/// "Keep your recovery phrase safe" (Paper "Only you can unlock it"): the one thing to keep
/// safe, on the amber cream with the gold key coin.
private struct KeepSafeCard: View {
  // The coin's gold and the card's cream are the brand artwork's (the Hasala mark's coin,
  // spec 05 §0), converted from the board's OKLab stops; no token names them.
  private static let cream = [Color(HRGBA(0xFF, 0xF6, 0xE2, 1)), Color(HRGBA(0xFB, 0xE9, 0xC4, 1))]
  private static let gold = [Color(HRGBA(0xF9, 0xDC, 0x94, 1)), Color(HRGBA(0xEB, 0xB0, 0x4A, 1))]
  private static let rim = Color(HRGBA(0xC9, 0x8A, 0x1E, 1))

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Circle()
        .fill(LinearGradient(colors: Self.gold, startPoint: .top, endPoint: .bottom))
        .frame(width: 36, height: 36)
        .background(Circle().fill(Self.rim).offset(y: 2))
        .overlay { HIconView(.key, size: 18, color: HColor.amber800, strokeWidth: 2.4) }
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text("Keep your recovery phrase safe").hType(.rowTitle).foregroundStyle(HColor.amber950)
        Text("It and your passkey are the only ways to unlock your data on a new iPhone. We can't reset them.")
          .hType(HType(size: 14, leading: 20, weight: .regular, textStyle: .subheadline))
          .foregroundStyle(HColor.amber950)
      }
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(16)
    .background(LinearGradient(colors: Self.cream, startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
    .accessibilityElement(children: .combine)
  }
}
