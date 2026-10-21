import HasalaDesign
import SwiftUI

nonisolated struct CoinTaps: Equatable {
  enum Trick: Equatable { case deposit, jackpot }

  static let jackpotTaps = 5
  static let gap: TimeInterval = 0.6

  private(set) var streak = 0
  private var lastTap = Date.distantPast

  mutating func tap(at now: Date) -> Trick {
    streak = now.timeIntervalSince(lastTap) < Self.gap ? streak + 1 : 1
    lastTap = now
    guard streak >= Self.jackpotTaps else { return .deposit }
    streak = 0
    return .jackpot
  }
}

struct HeaderMark: View {
  struct Coin {
    var drop: CGFloat = 0
    var spin: CGFloat = 0
  }

  @State private var taps = CoinTaps()
  @State private var plays = 0
  @State private var trick = CoinTaps.Trick.deposit
  @State private var clink = 0
  @State private var jackpot = 0
  @State private var busyUntil = Date.distantPast
  @Environment(\.hMotion) private var policy

  static let sink = 0.12
  static let spinTime = 0.42
  static let settle = 0.3
  static let fallFrom: CGFloat = 420
  static let headroom: CGFloat = 40

  var body: some View {
    Color.clear
      .frame(width: 54, height: 32)
      .overlay(alignment: .bottom) {
        KeyframeAnimator(initialValue: Coin(), trigger: plays) { coin in
          SlotMark(plate: .onWash, drop: coin.drop, spin: coin.spin)
            .frame(width: 54, height: 32 + Self.headroom)
        } keyframes: { _ in
          KeyframeTrack(\.spin) {
            CubicKeyframe(trick == .jackpot ? 2 : 0, duration: lead)
            MoveKeyframe(0)
          }
          KeyframeTrack(\.drop) {
            CubicKeyframe(0, duration: lead)
            CubicKeyframe(-300, duration: Self.sink)
            MoveKeyframe(Self.fallFrom)
            SpringKeyframe(0, duration: Self.settle, spring: Spring(response: 0.28, dampingRatio: 0.62))
          }
        }
        .allowsHitTesting(false)
      }
      .contentShape(Rectangle())
      .onTapGesture(perform: tapped)
      .hHaptic(.impactLight, trigger: clink)
      .hHaptic(.success, trigger: jackpot)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Hasala")
      .accessibilityAddTraits(.isImage)
      .accessibilityRespondsToUserInteraction(false)
      .accessibilityIdentifier("header.mark")
  }

  private var lead: Double { trick == .jackpot ? Self.spinTime : 0 }

  private func tapped() {
    let now = Date()
    let next = taps.tap(at: now)
    let isJackpot = next == .jackpot
    if policy.isStill {
      if isJackpot { jackpot += 1 } else { clink += 1 }
      return
    }
    guard isJackpot || now >= busyUntil else { return }
    trick = next
    let lead = self.lead
    busyUntil = now.addingTimeInterval(lead + Self.sink + Self.settle)
    plays += 1
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(lead + Self.sink))
      if isJackpot { jackpot += 1 } else { clink += 1 }
    }
  }
}
