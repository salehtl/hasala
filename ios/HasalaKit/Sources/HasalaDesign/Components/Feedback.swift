import HasalaModels
import SwiftUI

// Feedback and progress (Paper page 17, page 14 · Toast): status in words, progress with a
// count or a label, outcomes that say what changed. Work in the background never blocks the
// screen; only unlocking takes it over.

// MARK: - Toast

/// The glass toast (page 14 §03): a 56 strip that says what just happened, in the past tense,
/// with one action at most (Undo or Show). It floats 14 above the tab bar (or 34 from the
/// bottom) and never blocks. Frost-strong glass; solid under Reduce Transparency. The message
/// wraps to two lines at large sizes and the strip grows.
public struct GlassToast: View {
  /// The leading disc: accent with a white check (something was done), or ink with an
  /// eye-slash (amounts hidden).
  public enum Disc: Sendable {
    case accent(HIcon)
    case ink(HIcon)
  }

  private let disc: Disc
  let title: String
  let subtitle: String?
  let actionTitle: String?
  let action: (() -> Void)?
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  /// One line + Undo ("Sorted into Groceries"), two lines + Show ("Amounts hidden" / "Until you
  /// tap the eye again"), or one line with no action ("Bill marked as paid").
  public init(_ disc: Disc = .accent(.check), title: String, subtitle: String? = nil, actionTitle: String? = nil,
              action: (() -> Void)? = nil)
  {
    self.disc = disc
    self.title = title
    self.subtitle = subtitle
    self.actionTitle = actionTitle
    self.action = action
  }

  public var body: some View {
    HStack(spacing: 12) {
      discView
      VStack(alignment: .leading, spacing: 0) {
        Text(title)
          .hType(subtitle == nil ? .rowTitle : HType(size: 16, leading: 20, weight: .semibold, textStyle: .callout))
          .foregroundStyle(HColor.textPrimary)
        if let subtitle {
          Text(subtitle).hType(HType(size: 13, leading: 16, weight: .regular, textStyle: .footnote))
            .foregroundStyle(HColor.textSecondary)
        }
      }
      .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 8)
      if let actionTitle {
        Button(actionTitle) { action?() }
          .buttonStyle(.plain)
          .hType(.rowTitle)
          .foregroundStyle(HColor.textLink)
          // A 44 pt target inside the 56 pt toast.
          .frame(minWidth: 44, minHeight: 44)
          .contentShape(Rectangle())
      }
    }
    .padding(.leading, 10)
    .padding(.trailing, 18)
    .padding(.vertical, 6)
    .frame(minHeight: HSpacing.toastHeight)
    // Paper's frost-strong layer under the words (white 76%), so what scrolls behind the
    // toast stays out of them; native glass alone lets a dark widget's title show through
    // "Show". Reduce Transparency draws the solid fill instead.
    .background {
      if !reduceTransparency { Capsule().fill(HColor.materialGlassFrostStrong) }
    }
    .hGlass(in: Capsule(), interactive: false)
    .shadow(color: HColor.materialGlassShadowFar, radius: 12, x: 0, y: 8)
    // Contain, not combine: the action ("Undo", "Show") stays its own button.
    .accessibilityElement(children: .contain)
  }

  @ViewBuilder private var discView: some View {
    switch disc {
    case .accent(let icon):
      Circle().fill(HColor.actionAccent).frame(width: 36, height: 36)
        .overlay { HIconView(icon, size: HSpacing.iconInline, color: HColor.iconOnAccent, strokeWidth: 2.6) }
        .accessibilityHidden(true)
    case .ink(let icon):
      Circle().fill(HColor.textPrimary).frame(width: 36, height: 36)
        .overlay { HIconView(icon, size: HSpacing.iconInline, color: HColor.white, strokeWidth: 2.1) }
        .accessibilityHidden(true)
    }
  }
}

// MARK: - Progress

/// A spinner for waits with no count (page 17 §07): a ring on a 24 box with a quarter-turn arc,
/// round caps. Always next to words, never alone mid-screen. It stops turning under Reduce
/// Motion (the arc stays).
public struct Spinner: View {
  let size: CGFloat
  let tint: Color
  let track: Color
  @ResolvedMotion private var motion: MotionPolicy
  @State private var turning = false

  /// Sizes 12 (mailbox chip), 16 (pills) and 20 (step rows, buttons).
  public init(size: CGFloat = 16, tint: Color = HColor.actionAccent, track: Color = HColor.actionAccentSubtlePressed) {
    self.size = size
    self.tint = tint
    self.track = track
  }

  public var body: some View {
    let line = size * 3 / 24
    ZStack {
      Circle().stroke(track, lineWidth: line)
      Circle().trim(from: 0, to: 0.25).stroke(tint, style: StrokeStyle(lineWidth: line, lineCap: .round))
        .rotationEffect(.degrees(turning ? 270 : -90))
    }
    .padding(size * 3 / 24)
    .frame(width: size, height: size)
    .onAppear {
      guard !motion.isStill else { return }
      // A spinner is the one indicator that turns for as long as the wait lasts.
      withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { turning = true }
    }
    .accessibilityHidden(true)
  }
}

/// A determinate progress bar (page 17 §05), with no tick (a tick makes it a pace bar): a label
/// 15/20 600 and a count 13/18 600 above a 6 bar. Read as one element: "Reading alerts, 182 of 268".
public struct ProgressBar: View {
  let progress: Permille
  let label: String?
  let count: String?
  let onHue: Bool

  public init(_ progress: Permille, label: String? = nil, count: String? = nil, onHue: Bool = false) {
    self.progress = progress
    self.label = label
    self.count = count
    self.onHue = onHue
  }

  public var body: some View {
    VStack(spacing: 8) {
      if label != nil || count != nil {
        ReflowingRow {
          if let label { Text(label).hType(.subheadline.weight(.semibold)).foregroundStyle(HColor.textPrimary) }
        } trailing: {
          if let count { Text(count).hFigure(HFigure.badge.weight(.semibold)).foregroundStyle(HColor.textSecondary) }
        }
      }
      SlimProgressBar(progress, fill: HColor.feedbackProgressIndicator,
                      track: onHue ? HColor.progressTrackOnHue : HColor.feedbackProgressTrack)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(label ?? "Progress")
    .accessibilityValue(count ?? "\(progress.value / 10) percent")
  }
}

/// Where a setup flow is (page 13 §03): four 24 × 4 bars, gap 6, centred in the header. Done
/// and current are accent; to come is `apple-fills-secondary`. VoiceOver: "Step 1 of 4".
public struct StepIndicator: View {
  let current: Int
  let total: Int

  /// `current` counts from 1.
  public init(current: Int, of total: Int) {
    self.current = current
    self.total = total
  }

  public var body: some View {
    HStack(spacing: 6) {
      ForEach(1...max(1, total), id: \.self) { step in
        RoundedRectangle(cornerRadius: 2)
          .fill(step <= current ? HColor.actionAccent : HColor.appleFillsSecondary)
          .frame(width: 24, height: 4)
      }
    }
    .hAnimation(.thumbSlide, value: current)
    // A 44 box around the 4 pt bars, so the element VoiceOver reads is a size it can reach.
    .frame(minWidth: 44, minHeight: 44)
    .contentShape(Rectangle())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Step \(current) of \(total)")
  }
}

/// The Welcome story pager (page 13 §03): segments 3 tall, gap 4, across the top. Done stories
/// are ink; the current one fills as it plays (`fill` 0…1); later ones are the on-hue track.
public struct StoryProgress: View {
  let count: Int
  let current: Int
  let fill: Double

  /// `current` counts from 0.
  public init(count: Int, current: Int, fill: Double) {
    self.count = count
    self.current = current
    self.fill = fill
  }

  public var body: some View {
    HStack(spacing: 4) {
      ForEach(0..<max(1, count), id: \.self) { index in
        GeometryReader { geo in
          ZStack(alignment: .leading) {
            Capsule().fill(HColor.progressTrackOnHue)
            if index < current {
              Capsule().fill(HColor.textPrimary)
            } else if index == current {
              Capsule().fill(HColor.textPrimary).frame(width: geo.size.width * min(1, max(0, fill)))
            }
          }
        }
        .frame(height: 3)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Story \(current + 1) of \(count)")
  }
}

/// Work running behind the screen (page 17 §04 A): a white pill with a spinner, a label and a
/// count ("Reading on this iPhone · 214 of 268"), shown above the main button while the first
/// scan runs. The screen stays usable. Offline shows a grey dot instead of the spinner.
public struct BackgroundWorkPill: View {
  let label: String
  let count: String?
  let busy: Bool

  public init(label: String, count: String? = nil, busy: Bool = true) {
    self.label = label
    self.count = count
    self.busy = busy
  }

  public var body: some View {
    HStack(spacing: 8) {
      if busy {
        Spinner(size: 16)
      } else {
        Circle().fill(HColor.iconTertiary).frame(width: 8, height: 8)
      }
      Text(label).hType(.footnote.weight(.semibold)).foregroundStyle(HColor.textPrimary)
      if let count {
        Text(count).hFigure(HFigure.badge.weight(.semibold)).foregroundStyle(HColor.textSecondary)
      }
    }
    .padding(.leading, 10)
    .padding(.trailing, 14)
    .frame(minHeight: 36)
    .background(HColor.surfacePrimary, in: Capsule())
    .shadow(color: HColor.elevationNear, radius: 1, x: 0, y: 1)
    .shadow(color: Color(HRGBA(30, 42, 94, 0.08)), radius: 8, x: 0, y: 6)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel([label, count].compactMap { $0 }.joined(separator: ", "))
  }
}

/// The most common feedback (page 17 §03): a dot, a short verdict in the same colour, then plain
/// context in secondary ("● Over pace · on course for 1,992"). As a field error the dot is
/// centred in a line-tall lane and the words wrap under themselves (15/20 500, error).
public struct InlineStatus: View {
  public enum Tone: Sendable, Hashable {
    case success, warning, error, accent, neutral
    /// A pace verdict: the dot in the fill colour, the words in the verdict colour.
    case pace(Verdict)
  }

  public enum Size: Sendable { case small, regular }

  let tone: Tone
  let text: String
  let context: String?
  let size: Size
  let fieldError: Bool

  /// `fieldError` is the error line under a field or code cells.
  public init(tone: Tone, text: String, context: String? = nil, size: Size = .small, fieldError: Bool = false) {
    self.tone = tone
    self.text = text
    self.context = context
    self.size = size
    self.fieldError = fieldError
  }

  @ScaledMetric(relativeTo: .subheadline) private var regularLane: CGFloat = 20
  @ScaledMetric(relativeTo: .footnote) private var smallLane: CGFloat = 18

  public var body: some View {
    HStack(alignment: .top, spacing: fieldError ? 8 : 6) {
      Circle().fill(dot).frame(width: 7, height: 7)
        .frame(height: size == .regular || fieldError ? regularLane : smallLane)
      Text("\(Text(text).font(wordType.font).foregroundStyle(words))\(Text(verbatim: context.map { " · " + $0 } ?? ""))")
        .hType(size == .regular || fieldError ? .subheadline : .footnote)
        .foregroundStyle(HColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel([text, context].compactMap { $0 }.joined(separator: ", "))
  }

  private var wordType: HType {
    let base = size == .regular || fieldError ? HType.subheadline : HType.footnote
    return base.weight(fieldError ? .medium : .semibold)
  }

  private var dot: Color {
    switch tone {
    case .pace(let v): v == .overPace ? HColor.paceFillOverPace : v.foreground
    case .neutral: HColor.neutral300
    default: words
    }
  }

  private var words: Color {
    switch tone {
    case .success: HColor.statusSuccessForeground
    case .warning: HColor.statusWarningForeground
    case .error: HColor.statusErrorForeground
    case .accent: HColor.actionAccent
    case .neutral: HColor.textSecondary
    case .pace(let v): v.foreground
    }
  }
}

// MARK: - Outcomes

/// A status hero on a hue (Sign-in & security, page P2.5): a 56 white-70% disc with the icon in
/// the hue's ink, a 28/34 title in the ink, and a body line in on-hue secondary; an optional
/// action below. The hue names the state and the title says it ("Protected").
public struct StatusHero: View {
  let title: String
  let message: String
  let hue: Hue
  let icon: HIcon
  let action: (title: String, run: () -> Void)?

  public init(title: String, body: String, hue: Hue, icon: HIcon, action: (title: String, run: () -> Void)? = nil) {
    self.title = title
    self.message = body
    self.hue = hue
    self.icon = icon
    self.action = action
  }

  @Environment(\.dynamicTypeSize) private var typeSize

  public var body: some View {
    // At the accessibility sizes the disc moves above the words, so the title keeps the width.
    let layout = typeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
      : AnyLayout(HStackLayout(alignment: .center, spacing: 16))
    VStack(alignment: .leading, spacing: 16) {
      layout {
        Circle().fill(HColor.posterGlyph).frame(width: 56, height: 56)
          .overlay { HIconView(icon, size: 26, color: hue.ink) }
        VStack(alignment: .leading, spacing: 2) {
          Text(title).hType(.title1).foregroundStyle(hue.ink).accessibilityAddTraits(.isHeader)
          Text(message).hType(.subheadline).foregroundStyle(HColor.textOnHueSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      if let action {
        Button(action.title, action: action.run).buttonStyle(.pill(.onGrouped, size: .medium, fill: true))
      }
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(hue.perceptualGradient, in: RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
    .accessibilityElement(children: .combine)
  }
}

/// The answer to something just done (page 17 §04 C, page 16 §11): a status surface, radius 20,
/// a dot 8 and a 17/24 line, a second line in the tone's foreground. The fixes follow it as
/// normal rows and buttons; an error card may carry its own "Try again".
public struct ResultCard: View {
  public enum Tone: Sendable { case success, warning, error }

  let tone: Tone
  let title: String
  let detail: String?
  let action: (title: String, run: () -> Void)?

  public init(tone: Tone, title: String, detail: String? = nil, action: (title: String, run: () -> Void)? = nil) {
    self.tone = tone
    self.title = title
    self.detail = detail
    self.action = action
  }

  @ScaledMetric(relativeTo: .headline) private var lane: CGFloat = 24

  public var body: some View {
    VStack(alignment: .leading, spacing: action == nil ? 4 : 12) {
      VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .top, spacing: 8) {
          Circle().fill(dot).frame(width: 8, height: 8).frame(height: lane)
          Text(title).hType(.headline).foregroundStyle(HColor.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
        }
        if let detail {
          Text(detail).hType(.subheadline).foregroundStyle(foreground)
            .padding(.leading, 16)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .accessibilityElement(children: .combine)
      if let action {
        Button(action.title, action: action.run).buttonStyle(.pill(.primary, size: .medium))
          .padding(.leading, 16)
      }
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(surface, in: RoundedRectangle(cornerRadius: HRadius.tile, style: .continuous))
  }

  private var dot: Color {
    switch tone {
    case .success: HColor.statusSuccessForeground
    case .warning: HColor.paceFillOverPace
    case .error: HColor.statusErrorForeground
    }
  }

  private var foreground: Color {
    switch tone {
    case .success: HColor.statusSuccessForeground
    case .warning: HColor.statusWarningForeground
    case .error: HColor.statusErrorForeground
    }
  }

  private var surface: Color {
    switch tone {
    case .success: HColor.statusSuccessSurface
    case .warning: HColor.statusWarningSurface
    case .error: HColor.statusErrorSurface
    }
  }
}

/// The badge stage of a done screen (page 17 §09): 200 × 96, a white glow and four hue sparks
/// around a mint check disc, the Hasala coin-on-tray, or the unlocking ring. A big moment only;
/// it may celebrate once (`.celebrate`, under 600 ms). Under Reduce Motion it is simply there.
public struct SuccessBadge: View {
  public enum Content: Sendable, Hashable {
    /// A 72 mint disc with a 36 check (recovery done, all caught up).
    case check
    /// The Hasala coin-on-tray mark (You're set).
    case coin
    /// The unlocking ring, `progress` 0…1, around a sky disc with an open lock.
    case ring(Double)
  }

  let content: Content
  @ResolvedMotion private var motion: MotionPolicy
  @State private var landed = false

  public init(content: Content) {
    self.content = content
  }

  public var body: some View {
    ZStack {
      RadialGradient(colors: [HColor.white.opacity(0.9), HColor.white.opacity(0)], center: .center,
                     startRadius: 0, endRadius: 42)
        .frame(width: 120, height: 120)
      sparks
      centre
        .scaleEffect(landed || motion.isStill ? 1 : HMotion.chipPopScale)
        .opacity(landed || motion.isStill ? 1 : 0)
    }
    .frame(width: 200, height: 96)
    .onAppear {
      // Once per occurrence: the done screen appears once.
      withAnimation(motion.animation(.celebrate)) { landed = true }
    }
    .accessibilityHidden(true)
  }

  private var sparks: some View {
    ZStack(alignment: .topLeading) {
      spark(HPalette.hueSkyEnd, 8, x: 30, y: 22)
      spark(HPalette.hueSandEnd, 6, x: 52, y: 70)
      spark(HPalette.hueLilacEnd, 7, x: 156, y: 14)
      spark(HPalette.hueMintEnd, 9, x: 164, y: 62)
    }
    .frame(width: 200, height: 96, alignment: .topLeading)
  }

  private func spark(_ color: HRGBA, _ size: CGFloat, x: CGFloat, y: CGFloat) -> some View {
    Circle().fill(Color(color)).frame(width: size, height: size).offset(x: x, y: y)
  }

  @ViewBuilder private var centre: some View {
    switch content {
    case .check:
      Circle().fill(Hue.mint.perceptualGradient).frame(width: 72, height: 72)
        .overlay { Circle().stroke(HColor.white, lineWidth: 1).blendMode(.overlay) }
        .shadow(color: Color(HRGBA(22, 74, 53, 0.10)), radius: 1, x: 0, y: 1)
        .shadow(color: Color(HRGBA(22, 74, 53, 0.16)), radius: 14, x: 0, y: 12)
        .overlay { HIconView(.check, size: 36, color: Hue.mint.ink) }
    case .coin:
      HasalaMark()
        .frame(width: 160, height: 96)
        .shadow(color: Color(HRGBA(20, 38, 89, 0.22)), radius: 8, x: 0, y: 12)
    case .ring(let progress):
      ZStack {
        Circle().stroke(HColor.progressRingTrack, lineWidth: 5).frame(width: 80, height: 80)
        Circle().trim(from: 0, to: min(1, max(0, progress)))
          .stroke(HColor.actionAccent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
          .rotationEffect(.degrees(-90))
          .frame(width: 80, height: 80)
        Circle().fill(Hue.sky.perceptualGradient).frame(width: 68, height: 68)
          .overlay { HIconView(.lock, size: 30, color: Hue.sky.ink, strokeWidth: 1.8) }
      }
      .frame(width: 88, height: 88)
    }
  }
}

/// Good news said plainly, or nothing found (page 17 §08): a 56 disc with an icon, a 20/25
/// title, one line in secondary, centred. In the Notifications sheet: "Nothing needs you · We'll
/// tell you when something does." An optional action follows.
public struct EmptyStateCard: View {
  public enum Tone: Sendable {
    /// A success disc with a check (all clear).
    case success
    /// A white disc with a secondary icon (nothing found).
    case neutral
  }

  let icon: HIcon
  let tone: Tone
  let title: String
  let message: String
  let action: (title: String, run: () -> Void)?

  public init(icon: HIcon = .check, tone: Tone = .success, title: String, message: String,
              action: (title: String, run: () -> Void)? = nil)
  {
    self.icon = icon
    self.tone = tone
    self.title = title
    self.message = message
    self.action = action
  }

  public var body: some View {
    VStack(spacing: 12) {
      Circle()
        .fill(tone == .success ? HColor.statusSuccessSurface : HColor.surfacePrimary)
        .frame(width: 56, height: 56)
        .overlay {
          HIconView(icon, size: 26, color: tone == .success ? HColor.statusSuccessForeground : HColor.iconSecondary,
                    strokeWidth: tone == .success ? 2.2 : nil)
        }
        .accessibilityHidden(true)
      VStack(spacing: 4) {
        Text(title)
          .hType(HType(size: HFontSize.title3, leading: 25, weight: .semibold, tracking: HTracking.title3,
                       textStyle: .title3))
          .foregroundStyle(HColor.textPrimary)
          .accessibilityAddTraits(.isHeader)
        Text(message).hType(.subheadline).foregroundStyle(HColor.textSecondary)
      }
      .multilineTextAlignment(.center)
      .accessibilityElement(children: .combine)
      if let action {
        Button(action.title, action: action.run).buttonStyle(.pill(.secondary, size: .medium))
      }
    }
    .padding(.top, 28)
    .padding(.bottom, 8)
    .padding(.horizontal, 24)
    .frame(maxWidth: .infinity)
  }
}
