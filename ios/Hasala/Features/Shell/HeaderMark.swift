import HasalaDesign
import SwiftUI

nonisolated struct CoinTaps: Equatable {
  enum Trick: Equatable { case deposit, jackpot }

  static let jackpotTaps = 5
  static let gap: TimeInterval = 0.6

  private(set) var streak = 0
  private var lastTap = -TimeInterval.infinity

  mutating func tap(at now: TimeInterval) -> Trick {
    streak = now - lastTap < Self.gap ? streak + 1 : 1
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
  @State private var busyUntil = -TimeInterval.infinity
  @State private var jackpotQueued = false
  @State private var player: Task<Void, Never>?
  @Environment(\.hMotion) private var policy

  static let width: CGFloat = 54
  static let height: CGFloat = 32
  static let headroom: CGFloat = 6
  static let sink = 0.12
  static let spinTime = 0.42
  static let settle = 0.3
  static let fallFrom: CGFloat = 70

  var body: some View {
    ZStack {
      KeyframeAnimator(initialValue: Coin(), trigger: plays) { coin in
        SlotMark(plate: .onWash, drop: coin.drop, spin: coin.spin)
          .frame(width: Self.width, height: Self.height + Self.headroom)
      } keyframes: { _ in
        KeyframeTrack(\.spin) {
          CubicKeyframe(trick == .jackpot ? 2 : 0, duration: Self.lead(trick))
          MoveKeyframe(0)
        }
        KeyframeTrack(\.drop) {
          CubicKeyframe(0, duration: Self.lead(trick))
          CubicKeyframe(-300, duration: Self.sink)
          MoveKeyframe(Self.fallFrom)
          SpringKeyframe(0, duration: Self.settle, spring: Spring(response: 0.28, dampingRatio: 0.62))
        }
      }
      .padding(.bottom, Self.headroom)
      .allowsHitTesting(false)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Hasala")
      .accessibilityAddTraits(.isImage)
      .accessibilityIdentifier("header.mark")
      Color.clear
        .frame(width: Self.width, height: Self.height)
        .contentShape(Rectangle())
        .onTapGesture(perform: tapped)
        .accessibilityHidden(true)
    }
    .hHaptic(.impactLight, trigger: clink)
    .hHaptic(.success, trigger: jackpot)
    .onDisappear {
      player?.cancel()
      player = nil
      jackpotQueued = false
      busyUntil = -TimeInterval.infinity
    }
  }

  static func lead(_ trick: CoinTaps.Trick) -> Double { trick == .jackpot ? spinTime : 0 }

  private func tapped() {
    let now = ProcessInfo.processInfo.systemUptime
    let next = taps.tap(at: now)
    if policy.isStill {
      if next == .jackpot { jackpot += 1 } else { clink += 1 }
      return
    }
    if now >= busyUntil {
      play(next, after: 0, now: now)
    } else if next == .jackpot, !jackpotQueued {
      jackpotQueued = true
      play(.jackpot, after: busyUntil - now, now: now)
    }
  }

  private func play(_ next: CoinTaps.Trick, after wait: TimeInterval, now: TimeInterval) {
    busyUntil = now + wait + Self.lead(next) + Self.sink + Self.settle
    player = Task { @MainActor in
      if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
      guard !Task.isCancelled else { return }
      trick = next
      plays += 1
      try? await Task.sleep(for: .seconds(Self.lead(next) + Self.sink))
      guard !Task.isCancelled else { return }
      if next == .jackpot {
        jackpotQueued = false
        jackpot += 1
      } else {
        clink += 1
      }
    }
  }
}
