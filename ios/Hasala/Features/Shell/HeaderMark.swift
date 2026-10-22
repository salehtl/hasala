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

nonisolated enum CoinShow {
  struct Beat: Equatable {
    let at: TimeInterval
    let haptic: HHaptic
  }

  static let sink = 0.1
  static let settle = 0.18

  static let crouch = 0.12
  static let rise = 0.14
  static let spinTime = 0.42
  static let slam = 0.06
  static let sinkAway = 0.05
  static let showerFall = 0.08
  static let showerCoins = 2
  static let landing = 0.3
  static let landed = 0.1
  static let burst = 0.45
  static let bumpUp = 0.04
  static let bumpSettle = 0.2
  static let stretchTime = 0.07
  static let unstretch = 0.12
  static let stillGlow = 0.45

  static let spins: CGFloat = 2
  static let fallFrom: CGFloat = 70
  static let dip: CGFloat = -18
  static let lift: CGFloat = 46
  static let crouchSquash: CGFloat = 0.2
  static let stretch: CGFloat = -0.1
  static let bumps: [CGFloat] = [0.12, 0.07, 0.05]

  static var shower: TimeInterval { showerFall + sinkAway }

  static var firstImpact: TimeInterval { crouch + spinTime + slam }

  static var lastCoin: TimeInterval { firstImpact + sinkAway + Double(showerCoins) * shower }

  static func impacts(_ trick: CoinTaps.Trick) -> [TimeInterval] {
    switch trick {
    case .deposit: [sink]
    case .jackpot: (0...showerCoins).map { firstImpact + Double($0) * shower }
    }
  }

  static func total(_ trick: CoinTaps.Trick) -> TimeInterval {
    switch trick {
    case .deposit: sink + settle
    case .jackpot: lastCoin + landing
    }
  }

  static func beats(_ trick: CoinTaps.Trick) -> [Beat] {
    switch trick {
    case .deposit:
      return [Beat(at: sink, haptic: .impactLight)]
    case .jackpot:
      let hits = impacts(.jackpot)
      return [Beat(at: hits[0], haptic: .impactRigid)]
        + hits.dropFirst().map { Beat(at: $0, haptic: .impactLight) }
        + [Beat(at: lastCoin + landed, haptic: .success)]
    }
  }
}

nonisolated struct CoinStage: Equatable {
  enum Step: Equatable {
    case play(after: TimeInterval)
    case skip
  }

  private(set) var busyUntil = -TimeInterval.infinity
  private(set) var jackpotQueued = false

  mutating func step(_ trick: CoinTaps.Trick, at now: TimeInterval) -> Step {
    if now >= busyUntil {
      busyUntil = now + CoinShow.total(trick)
      jackpotQueued = false
      return .play(after: 0)
    }
    guard trick == .jackpot, !jackpotQueued else { return .skip }
    jackpotQueued = true
    let wait = busyUntil - now
    busyUntil += CoinShow.total(.jackpot)
    return .play(after: wait)
  }

  mutating func started(_ trick: CoinTaps.Trick) {
    if trick == .jackpot { jackpotQueued = false }
  }

  mutating func reset() { self = CoinStage() }
}

struct HeaderMark: View {
  struct Coin {
    var drop: CGFloat = 0
    var spin: CGFloat = 0
    var squash: CGFloat = 0
    var bump: CGFloat = 0
    var burst: CGFloat = 0
  }

  @State private var taps = CoinTaps()
  @State private var stage = CoinStage()
  @State private var plays = 0
  @State private var trick = CoinTaps.Trick.deposit
  @State private var felt: [HHaptic: Int] = [:]
  @State private var glow = false
  @State private var players: [Task<Void, Never>] = []
  @Environment(\.hMotion) private var policy

  static let width: CGFloat = 54
  static let height: CGFloat = 32
  static let headroom: CGFloat = 6
  static let markSize = CGSize(width: width, height: height + headroom)

  var body: some View {
    ZStack {
      KeyframeAnimator(initialValue: Coin(), trigger: plays) { coin in
        SlotMark(plate: .onWash, drop: coin.drop, spin: coin.spin, squash: coin.squash)
          .frame(width: Self.markSize.width, height: Self.markSize.height)
          .scaleEffect(x: 1 + coin.bump, y: 1 - coin.bump * 0.4, anchor: .bottom)
          .background {
            if glow { StillGlow().transition(.opacity) }
          }
          .overlay {
            if coin.burst > 0, coin.burst < 1 {
              JackpotBurst(progress: coin.burst, mark: Self.markSize)
                .frame(width: Self.markSize.width * 2, height: Self.markSize.height * 2)
            }
          }
      } keyframes: { _ in
        Self.keyframes(trick)
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
    .hHaptic(.impactLight, trigger: felt[.impactLight, default: 0])
    .hHaptic(.impactRigid, trigger: felt[.impactRigid, default: 0])
    .hHaptic(.success, trigger: felt[.success, default: 0])
    #if HASALA_MOCKS
      .task { await autoplay() }
    #endif
    .onDisappear {
      stopPlayers()
      stage.reset()
    }
  }

  @KeyframesBuilder<Coin>
  static func keyframes(_ trick: CoinTaps.Trick) -> some Keyframes<Coin> {
    KeyframeTrack(\.drop) {
      if trick == .jackpot {
        LinearKeyframe(CoinShow.dip, duration: CoinShow.crouch, timingCurve: .easeOut)
        LinearKeyframe(CoinShow.lift, duration: CoinShow.rise, timingCurve: .easeOut)
        LinearKeyframe(CoinShow.lift * 0.8, duration: CoinShow.spinTime - CoinShow.rise, timingCurve: .easeInOut)
        LinearKeyframe(0, duration: CoinShow.slam, timingCurve: .easeIn)
        LinearKeyframe(-300, duration: CoinShow.sinkAway)
        MoveKeyframe(CoinShow.fallFrom)
        LinearKeyframe(0, duration: CoinShow.showerFall, timingCurve: .easeIn)
        LinearKeyframe(-300, duration: CoinShow.sinkAway)
        MoveKeyframe(CoinShow.fallFrom)
        LinearKeyframe(0, duration: CoinShow.showerFall, timingCurve: .easeIn)
        LinearKeyframe(-300, duration: CoinShow.sinkAway)
        MoveKeyframe(CoinShow.fallFrom)
        SpringKeyframe(0, duration: CoinShow.landing, spring: Spring(response: 0.28, dampingRatio: 0.55))
      } else {
        LinearKeyframe(-300, duration: CoinShow.sink, timingCurve: .easeIn)
        MoveKeyframe(CoinShow.fallFrom)
        SpringKeyframe(0, duration: CoinShow.settle, spring: Spring(response: 0.16, dampingRatio: 0.65))
      }
    }
    KeyframeTrack(\.spin) {
      if trick == .jackpot {
        LinearKeyframe(0, duration: CoinShow.crouch)
        LinearKeyframe(CoinShow.spins, duration: CoinShow.spinTime, timingCurve: .easeInOut)
        MoveKeyframe(0)
      } else {
        MoveKeyframe(0)
      }
    }
    KeyframeTrack(\.squash) {
      if trick == .jackpot {
        LinearKeyframe(CoinShow.crouchSquash, duration: CoinShow.crouch, timingCurve: .easeOut)
        LinearKeyframe(CoinShow.stretch, duration: CoinShow.stretchTime, timingCurve: .easeOut)
        LinearKeyframe(0, duration: CoinShow.unstretch, timingCurve: .easeOut)
      } else {
        MoveKeyframe(0)
      }
    }
    KeyframeTrack(\.bump) {
      if trick == .jackpot {
        LinearKeyframe(0, duration: CoinShow.firstImpact)
        LinearKeyframe(CoinShow.bumps[0], duration: CoinShow.bumpUp, timingCurve: .easeOut)
        LinearKeyframe(0, duration: CoinShow.shower - CoinShow.bumpUp, timingCurve: .easeIn)
        LinearKeyframe(CoinShow.bumps[1], duration: CoinShow.bumpUp, timingCurve: .easeOut)
        LinearKeyframe(0, duration: CoinShow.shower - CoinShow.bumpUp, timingCurve: .easeIn)
        LinearKeyframe(CoinShow.bumps[2], duration: CoinShow.bumpUp, timingCurve: .easeOut)
        SpringKeyframe(0, duration: CoinShow.bumpSettle, spring: Spring(response: 0.2, dampingRatio: 0.6))
      } else {
        MoveKeyframe(0)
      }
    }
    KeyframeTrack(\.burst) {
      if trick == .jackpot {
        LinearKeyframe(0, duration: CoinShow.firstImpact)
        LinearKeyframe(1, duration: CoinShow.burst, timingCurve: .easeOut)
        MoveKeyframe(0)
      } else {
        MoveKeyframe(0)
      }
    }
  }

  private func tapped() {
    let now = ProcessInfo.processInfo.systemUptime
    perform(taps.tap(at: now), now: now)
  }

  private func perform(_ next: CoinTaps.Trick, now: TimeInterval) {
    if policy.isStill {
      stillTrick(next)
      return
    }
    switch stage.step(next, at: now) {
    case .skip:
      return
    case .play(let wait):
      if wait == 0 { stopPlayers() }
      players.append(play(next, after: wait))
    }
  }

  private func stillTrick(_ next: CoinTaps.Trick) {
    guard next == .jackpot else {
      feel(.impactLight)
      return
    }
    feel(.success)
    guard !policy.settled else { return }
    stopPlayers()
    stage.reset()
    players = [
      Task { @MainActor in
        withAnimation(HMotion.easeOutSoft(HMotion.reduceMotionFade)) { glow = true }
        try? await Task.sleep(for: .seconds(CoinShow.stillGlow))
        guard !Task.isCancelled else { return }
        withAnimation(HMotion.easeOutSoft(HMotion.reduceMotionFade)) { glow = false }
      }
    ]
  }

  private func play(_ next: CoinTaps.Trick, after wait: TimeInterval) -> Task<Void, Never> {
    Task { @MainActor in
      if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
      guard !Task.isCancelled else { return }
      stage.started(next)
      trick = next
      plays += 1
      let start = ContinuousClock.now
      for beat in CoinShow.beats(next) {
        try? await Task.sleep(until: start + .seconds(beat.at), clock: .continuous)
        guard !Task.isCancelled else { return }
        feel(beat.haptic)
      }
    }
  }

  private func stopPlayers() {
    players.forEach { $0.cancel() }
    players = []
    glow = false
  }

  private func feel(_ haptic: HHaptic) {
    felt[haptic, default: 0] += 1
  }

  #if HASALA_MOCKS
    private func autoplay() async {
      guard let every = JackpotLaunch.current else { return }
      try? await Task.sleep(for: .seconds(1.5))
      repeat {
        guard !Task.isCancelled else { return }
        perform(.jackpot, now: ProcessInfo.processInfo.systemUptime)
        try? await Task.sleep(for: .seconds(max(every, CoinShow.total(.jackpot))))
      } while every > 0
    }
  #endif
}

private struct JackpotBurst: View {
  let progress: CGFloat
  let mark: CGSize

  static let sparks = 8

  var body: some View {
    Canvas { context, size in
      let s = SlotMark.scale(in: mark)
      let inMark = SlotMark.slotCentre(in: mark)
      let c = CGPoint(x: inMark.x + (size.width - mark.width) / 2, y: inMark.y + (size.height - mark.height) / 2)
      let p = progress
      let fade = 1 - p
      let ringW = 600 * s * (1 + 0.5 * p)
      let ringH = 112 * s * (1 + 1.4 * p)
      context.stroke(
        Path(ellipseIn: CGRect(x: c.x - ringW / 2, y: c.y - ringH / 2, width: ringW, height: ringH)),
        with: .color(SlotMark.coinDeep.opacity(0.9 * fade)), lineWidth: 0.6 + 1.8 * fade)
      let glowR = 220 * s * (0.6 + 0.4 * p)
      context.fill(
        Path(ellipseIn: CGRect(x: c.x - glowR, y: c.y - glowR * 0.6, width: glowR * 2, height: glowR * 1.2)),
        with: .radialGradient(
          Gradient(colors: [SlotMark.coinLight.opacity(0.45 * fade), SlotMark.coinLight.opacity(0)]),
          center: c, startRadius: 0, endRadius: glowR))
      for index in 0..<Self.sparks {
        let angle = Double.pi + Double.pi * (Double(index) + 0.5) / Double(Self.sparks)
        let reach = (8 + 28 * p) * (index.isMultiple(of: 2) ? 1 : 0.8)
        let point = CGPoint(x: c.x + reach * cos(angle), y: c.y - 4 + reach * 0.75 * sin(angle))
        let r = 0.5 + 1.6 * fade
        let color = index.isMultiple(of: 2) ? SlotMark.coinDeep : SlotMark.coinRim
        context.fill(
          Path(ellipseIn: CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2)),
          with: .color(color.opacity(Double(1 - p * p))))
      }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

private struct StillGlow: View {
  var body: some View {
    Ellipse()
      .fill(.radialGradient(
        Gradient(colors: [SlotMark.coinLight.opacity(0.7), SlotMark.coinLight.opacity(0)]),
        center: .center, startRadius: 0, endRadius: HeaderMark.width * 0.6))
      .frame(width: HeaderMark.width * 1.3, height: HeaderMark.height * 1.1)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }
}
