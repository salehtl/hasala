import HasalaDesign
import HasalaModels
import SwiftUI
import UIKit

// The parts the sign-in, unlock, recovery, Sign-in & security and freeze screens share
// (Paper P2.3–P2.8; spec 08 §2.3, spec 09 §1): the hero disc over a question block, the
// "or" divider, the status list card, bullet and match cards, the resend row and the
// unlocking ring. Built on the account templates and the design system's parts.

// MARK: - Hero disc and its screen

/// The 64 hue disc above a question block or in a confirm sheet (Paper "HeroDisc · Sealed",
/// "· Frozen", "Disc · Face ID"): the hue's 160° gradient, a 4 pt white ring, a 30 glyph in
/// the hue's ink at 1.8. The account screens' discs (G80, K34, GUM, MTO, IYT) also float on
/// the far shadow; the confirm sheet's Face ID and password discs don't.
struct HeroDisc: View {
  var icon: HIcon
  var hue: Hue
  var shadow = true

  var body: some View {
    Circle()
      .fill(hue.perceptualGradient)
      .frame(width: 64, height: 64)
      .overlay { HIconView(icon, size: 30, color: hue.ink, strokeWidth: icon == .password ? 1.7 : 1.8) }
      .background { Circle().fill(HColor.white).padding(-4) }
      .shadow(color: shadow ? HColor.elevationFar : .clear, radius: 12, x: 0, y: 8)
      .accessibilityHidden(true)
  }
}

/// An account screen with a hero disc over its title (Paper G80 "Unlock your data", K34, GUM,
/// MTO "Your account is frozen"): the account template's wash, header, question block,
/// content and dock, with the disc 16 above the title. These screens have no way back, so
/// the header is Paper's 24 pt spacer unless `back` says otherwise.
struct HeroAccountScreen<Content: View, Footer: View>: View {
  var hero: HeroDisc
  var title: String
  var subtitle: String?
  var back: AccountBack = .none
  @ViewBuilder var content: () -> Content
  @ViewBuilder var footer: () -> Footer

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        hero
          .padding(.bottom, 16)
        VStack(alignment: .leading, spacing: 8) {
          Text(title)
            .hType(.title1)
            .foregroundStyle(HColor.textPrimary)
            .accessibilityAddTraits(.isHeader)
          if let subtitle {
            Text(subtitle)
              .hType(.body)
              .foregroundStyle(HColor.textOnWashSecondary)
          }
        }
        .fixedSize(horizontal: false, vertical: true)
        content()
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.top, 24)
      }
      .padding(.horizontal, HSpacing.insetPage)
      // Paper's no-back header is a 24 pt spacer, then 16 to the question block.
      .padding(.top, hasHeader ? 16 : 40)
      .padding(.bottom, 16)
    }
    .scrollBounceBehavior(.basedOnSize)
    .scrollEdgeEffectStyle(.soft, for: .bottom)
    .safeAreaBar(edge: .bottom) {
      AccountDock(content: footer)
    }
    .background(alignment: .top) {
      AmbientWash(.setup).ignoresSafeArea(edges: .top)
    }
    .background(HColor.surfaceSecondary)
    .accountHeader(back: back)
  }

  private var hasHeader: Bool {
    if case .none = back { return false }
    return true
  }
}

/// The dock of a screen built outside the account template (Paper "Action"): a primary pill
/// and a link or a note, 4 apart, 20 from the sides, on the home indicator's safe area.
struct AccountDock<Content: View>: View {
  @ViewBuilder var content: () -> Content

  var body: some View {
    VStack(spacing: 4) { content() }
      .frame(maxWidth: .infinity)
      .padding(.horizontal, HSpacing.insetPage)
      .padding(.top, 8)
      .environment(\.pillDisabledBase, HColor.surfaceSecondary)
  }
}

extension View {
  /// The account template puts its content 24 under the question block; some boards draw it
  /// closer (spec 08 §5: KH7 and KIL 20, GDD and GZT 16). `AccountScreen` is shared, so a
  /// page pulls its own content up by the difference.
  func accountContentTop(_ top: CGFloat) -> some View {
    padding(.top, top - accountTemplateContentTop)
  }
}

/// `AccountScreen`'s gap between the question block and the content.
private let accountTemplateContentTop: CGFloat = 24

// MARK: - Small parts

/// "or use your email" between the passkey and the password (Paper "OrDivider"): two
/// hairlines and a 13/18 semibold label, 8 above and below.
struct OrDivider: View {
  var label: String

  var body: some View {
    HStack(spacing: 12) {
      Rectangle().fill(HColor.appleSeparatorsNonOpaque).frame(height: 1).accessibilityHidden(true)
      Text(label)
        .hType(.footnote.weight(.semibold))
        .foregroundStyle(HColor.textSecondary)
        .fixedSize()
      Rectangle().fill(HColor.appleSeparatorsNonOpaque).frame(height: 1).accessibilityHidden(true)
    }
    .padding(.vertical, 8)
  }
}

/// A row of a status list (Paper "StatusListCard"): a 7 dot, a 16/22 title (secondary while
/// it hasn't started), and a trailing 15/20 value.
struct StatusListRow: Identifiable {
  enum State { case done, active, pending }

  var title: String
  var value: String
  var state: State
  var id: String { title }
}

/// The white list of steps or facts on a done or progress screen (Paper GJJ "Unlock steps",
/// H5V): rows at least 52, dividers in from the dot's lane (35).
struct StatusListCard: View {
  var rows: [StatusListRow]

  @ScaledMetric(relativeTo: .callout) private var lane: CGFloat = 22

  var body: some View {
    HListCard {
      ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
        if i > 0 { HDivider(inset: .lane35) }
        HStack(alignment: .top, spacing: 12) {
          Circle().fill(dot(row.state)).frame(width: 7, height: 7).frame(height: lane)
          ReflowingRow {
            Text(row.title)
              .hType(.rowTitle)
              .foregroundStyle(row.state == .pending ? HColor.textSecondary : HColor.textPrimary)
          } trailing: {
            Text(row.value).hType(.subheadline).foregroundStyle(HColor.textSecondary)
          }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .frame(minHeight: 52)
        .accessibilityElement(children: .combine)
      }
    }
  }

  private func dot(_ state: StatusListRow.State) -> Color {
    switch state {
    case .done: HColor.statusSuccessForeground
    case .active: HColor.actionAccent
    case .pending: HColor.neutral300
    }
  }
}

/// What a confirmation will do, as dotted lines in a white card (Paper "BulletCard", P2.6;
/// "Ways forward" on IYT): radius 20, 16 in, rows 10 apart, a 7 dot in text-secondary.
struct BulletCard: View {
  var lines: [String]

  @ScaledMetric(relativeTo: .subheadline) private var lane: CGFloat = 20

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(lines, id: \.self) { line in
        HStack(alignment: .top, spacing: 10) {
          Circle().fill(HColor.textSecondary).frame(width: 7, height: 7).frame(height: lane)
          Text(line)
            .hType(.subheadline)
            .foregroundStyle(HColor.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.tile, style: .continuous))
    .accessibilityElement(children: .combine)
  }
}

/// A need, one of two in a white card (Paper GYP "Two things", H9F): a 40 icon tile, a
/// 16/22 title and a 15/20 line.
struct NeedRow: View {
  var icon: HIcon
  var hue: Hue
  var title: String
  var detail: String

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      IconTile(icon: icon, hue: hue)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).hType(.rowTitle).foregroundStyle(HColor.textPrimary)
        Text(detail).hType(.subheadline).foregroundStyle(HColor.textSecondary)
      }
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityElement(children: .combine)
  }
}

/// A white card of need rows, 20 in, 16 apart (Paper "Two things").
struct NeedsCard<Content: View>: View {
  @ViewBuilder var content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: 16) { content() }
      .padding(20)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
  }
}

/// The red note for what can't be undone or done for you (Paper "WarningNote", GYP and
/// H9F): an 18 padlock and 13/18 medium text in the error ink on the error surface.
struct WarningNote: View {
  var text: String

  @ScaledMetric(relativeTo: .footnote) private var lane: CGFloat = 18

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      HIconView(.lock, size: 18, color: HColor.statusErrorForeground).frame(height: lane)
      Text(text)
        .hType(.footnote.weight(.medium))
        .foregroundStyle(HColor.statusErrorForeground)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, 12)
    .padding(.horizontal, 14)
    .background(HColor.statusErrorSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .accessibilityElement(children: .combine)
  }
}

/// A white note with a 22 icon and 15/20 secondary text (Paper GQL "A code alone can't
/// reset it", LPY "Two codes", LRC "Nothing changes yet"): radius 20, 16 in.
struct CardNote: View {
  var icon: HIcon
  var text: String

  @ScaledMetric(relativeTo: .subheadline) private var lane: CGFloat = 20

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      HIconView(icon, size: 22, color: HColor.iconPrimary, strokeWidth: 1.8).frame(height: lane)
      Text(text)
        .hType(.subheadline)
        .foregroundStyle(HColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(16)
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.tile, style: .continuous))
    .accessibilityElement(children: .combine)
  }
}

// MARK: - Codes

/// Under the code cells (Paper "ResendRow"): "Resend code in 0:42" counting down from the
/// send, then a "Resend code" link; and a way back to the address on the right.
struct ResendRow: View {
  var sentAt: Date?
  /// How long before a new code may be asked for.
  var wait: TimeInterval = 60
  var busy = false
  var trailing: (title: String, identifier: String, action: () -> Void)?
  var onResend: () -> Void

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      let left = sentAt.map { max(0, wait - context.date.timeIntervalSince($0)) } ?? 0
      HStack {
        if left > 0 {
          Text("Resend code in \(Self.clock(left))")
            .hType(.subheadline)
            .foregroundStyle(HColor.textSecondary)
            .accessibilityIdentifier("code.resendWait")
        } else {
          InlineTextButton(title: "Resend code", identifier: "code.resend", action: onResend)
            .disabled(busy)
        }
        Spacer(minLength: 8)
        if let trailing {
          InlineTextButton(title: trailing.title, identifier: trailing.identifier, action: trailing.action)
        }
      }
      .frame(minHeight: 44)
    }
  }

  /// "0:42".
  static func clock(_ seconds: TimeInterval) -> String {
    let s = Int(seconds.rounded(.up))
    return "\(s / 60):" + String(format: "%02d", s % 60)
  }
}

/// A six-digit code screen (Paper G2U "Check your email", G5E): the cells, checked on the
/// sixth digit; the wrong and expired lines; the resend row; the spam hint. An expired code
/// offers "Send a new code" in the dock (page 11 §02).
struct CodeStepScreen: View {
  var title: String
  var subtitle: String
  var steps: (current: Int, of: Int)?
  @Binding var code: String
  var busy: Bool
  var failure: AuthFailure?
  var sentAt: Date?
  var trailing: (title: String, identifier: String, action: () -> Void)?
  var onSubmit: () -> Void
  var onResend: () -> Void

  private var state: CodeCells.State {
    switch failure {
    case .codeExpired: .expired
    case .codeWrong: code.count == 6 ? .wrong : .typing
    default: .typing
    }
  }

  var body: some View {
    AccountScreen(title: title, subtitle: subtitle, steps: steps, back: .system) {
      VStack(alignment: .leading, spacing: 12) {
        CodeCells(code: $code, state: state)
          .onChange(of: code) { _, new in
            // Checked on the sixth digit (page 11 §02); typing again clears a wrong code.
            if new.count == 6, !busy { onSubmit() }
          }
        if let message = failure?.message {
          FieldErrorLine(text: message, warning: failure == .codeExpired)
            .accessibilityIdentifier("code.failure")
        }
        if state != .expired {
          ResendRow(sentAt: sentAt, busy: busy, trailing: trailing, onResend: onResend)
        }
        HintCard(text: "Not there? Check Spam or Promotions for an email from no-reply@hasala.app.")
      }
    } footer: {
      if state == .expired {
        BusyButton(title: "Send a new code", busy: busy, identifier: "code.resendNew", action: onResend)
      }
    }
  }
}

// MARK: - Unlocking ring

/// The badge of "Unlocking your data" (Paper GJJ "Disc · Unlocking"): the celebration
/// glow and sparks around a 68 sky disc with an open padlock, inside an 88 progress ring.
/// The service doesn't report how far it has got, so the arc turns (an indeterminate ring)
/// rather than pretend a percentage; under Reduce Motion it holds still.
struct UnlockingBadge: View {
  @StageMotion private var motion: MotionPolicy

  var body: some View {
    let still = motion.isStill
    ZStack {
      RadialGradient(colors: [HColor.white.opacity(0.9), HColor.white.opacity(0)], center: .center,
                     startRadius: 0, endRadius: 42)
        .frame(width: 120, height: 120)
      sparks
      ZStack {
        Circle().stroke(HColor.progressRingTrack, lineWidth: 5).frame(width: 80, height: 80)
        TimelineView(.animation(paused: still)) { context in
          // One turn every 1.2 s, from 12 o'clock; still, it rests where Paper draws it.
          let turn = still ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2
          Circle().trim(from: 0, to: 0.64)
            .stroke(HColor.actionAccent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
            .rotationEffect(.degrees(-90 + turn * 360))
            .frame(width: 80, height: 80)
        }
        Circle().fill(Hue.sky.perceptualGradient).frame(width: 68, height: 68)
          .overlay { Circle().stroke(HColor.white, lineWidth: 1).blendMode(.overlay) }
          .overlay { OpenPadlock().stroke(Hue.sky.ink, style: StrokeStyle(lineWidth: 1.8 * 30 / 24, lineCap: .round, lineJoin: .round)).frame(width: 30, height: 30) }
      }
      .frame(width: 88, height: 88)
    }
    .frame(width: 200, height: 96)
    .accessibilityHidden(true)
  }

  private var sparks: some View {
    ZStack(alignment: .topLeading) {
      spark(Hue.sky, 8, x: 30, y: 22)
      spark(Hue.sand, 6, x: 52, y: 70)
      spark(Hue.lilac, 7, x: 156, y: 14)
      spark(Hue.mint, 9, x: 164, y: 62)
    }
    .frame(width: 200, height: 96, alignment: .topLeading)
  }

  private func spark(_ hue: Hue, _ size: CGFloat, x: CGFloat, y: CGFloat) -> some View {
    Circle().fill(hue.end).frame(width: size, height: size).offset(x: x, y: y)
  }
}

/// Paper's open padlock (GJJ): the closed body with the shackle swung open
/// (`M8.5 10.5V8a3.5 3.5 0 0 1 6.8-1.2`), in a 24 box scaled to the frame.
private nonisolated struct OpenPadlock: Shape {
  func path(in rect: CGRect) -> Path {
    var p = Path()
    p.addRoundedRect(in: CGRect(x: 5, y: 10.5, width: 14, height: 10), cornerSize: CGSize(width: 2.5, height: 2.5))
    p.move(to: CGPoint(x: 8.5, y: 10.5))
    p.addLine(to: CGPoint(x: 8.5, y: 8))
    // The arc from the shackle's left leg over the top, stopping short on the right.
    p.addArc(center: CGPoint(x: 12, y: 8), radius: 3.5, startAngle: .degrees(180), endAngle: .degrees(-20),
             clockwise: false)
    return p.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24))
  }
}

/// A celebration-style progress screen (Paper GJJ): the ready wash, the unlocking badge,
/// a large centred title and body, a status card, and an info card at the foot. No header,
/// no controls: it moves on by itself.
struct ProgressCelebrationScreen<Cards: View, Foot: View>: View {
  var title: String
  var subtitle: String
  @ViewBuilder var cards: () -> Cards
  @ViewBuilder var foot: () -> Foot

  var body: some View {
    ScrollView {
      VStack(spacing: 0) {
        VStack(spacing: 20) {
          UnlockingBadge()
          VStack(spacing: 8) {
            Text(title)
              .hType(.largeTitle)
              .foregroundStyle(HColor.textPrimary)
              .accessibilityAddTraits(.isHeader)
            Text(subtitle)
              .hType(.body)
              .foregroundStyle(HColor.textOnWashSecondary)
              .frame(maxWidth: 300)
          }
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.top, 76)
        cards()
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, HSpacing.insetPage)
          .padding(.top, 36)
      }
      .padding(.bottom, 16)
    }
    .scrollBounceBehavior(.basedOnSize)
    .scrollEdgeEffectStyle(.soft, for: .bottom)
    .safeAreaBar(edge: .bottom) {
      // Paper: the card's foot sits 40 from the screen's bottom edge.
      foot()
        .padding(.horizontal, HSpacing.insetPage)
        .padding(.bottom, 6)
    }
    .background(alignment: .top) {
      AmbientWash(.ready).ignoresSafeArea(edges: .top)
    }
    .background(HColor.surfaceSecondary)
    .navigationBarBackButtonHidden()
    .toolbar(.hidden, for: .navigationBar)
  }
}

// MARK: - Capture

/// Whether any screen showing Hasala is being recorded or mirrored: the words are then not
/// drawn at all (spec 04 §6.7, "shown means drawn").
@MainActor
func screenIsCaptured() -> Bool {
  #if DEBUG
    if ProcessInfo.processInfo.arguments.contains("-HasalaScreenCaptured") { return true }
  #endif
  return UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.contains { $0.screen.isCaptured }
}
