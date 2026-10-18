import HasalaDesign
import HasalaModels
import SwiftUI

// The account templates and their parts (Paper "Template · Account screen" E01-0; P2 rows
// 14.1–14.8; spec 07 §3, spec 08 §2.3): join, the recovery phrase, setup, sign-in, recovery
// and the walls all stand on these, built from the design system's parts and motion.

// MARK: - Account screen

/// How an account screen is left from its header (plan decision 7).
enum AccountBack {
  /// The system back button with its edge swipe: a screen pushed on a navigation stack.
  /// The stack's path pops; the model clears what the left screen showed.
  case system
  /// No way back (the account exists, the step can't be undone, the root of a flow): no
  /// back button and no swipe.
  case none
  /// A back button that runs `action`: a screen whose "back" is a change of state on the
  /// same screen, not a pop (unlock's words, the phrase viewer in Sign-in & security).
  case action(() -> Void)
}

/// The account screen (Paper "Template · Account screen"): the morning wash under the
/// system navigation bar, which carries the back button, the step indicator as its
/// principal item and Skip or Close on the trailing side; the question block (title 1 and
/// a body line on the wash); the content; and a dock of buttons above the home indicator.
///
/// The bar is the system's (decision 7), so back has the interactive swipe and its glass;
/// screens with no way back hide the button, which also turns the swipe off.
/// The id of an account screen's question and content together (not the dock), so a screen
/// can scroll the least that shows all of it, which never takes the title under the header
/// (`revealsPhraseEntry`).
let accountScreenBodyID = "account.screenBody"

struct AccountScreen<Content: View, Footer: View>: View {
  var title: String
  var subtitle: String?
  var steps: (current: Int, of: Int)?
  var back: AccountBack
  var trailing: (title: String, action: () -> Void)?
  var wash: HWash
  @ViewBuilder var content: () -> Content
  @ViewBuilder var footer: () -> Footer

  init(
    title: String, subtitle: String? = nil, steps: (current: Int, of: Int)? = nil, back: AccountBack = .none,
    trailing: (title: String, action: () -> Void)? = nil, wash: HWash = .setup,
    @ViewBuilder content: @escaping () -> Content, @ViewBuilder footer: @escaping () -> Footer
  ) {
    self.title = title
    self.subtitle = subtitle
    self.steps = steps
    self.back = back
    self.trailing = trailing
    self.wash = wash
    self.content = content
    self.footer = footer
  }

  /// The keyboard is up: the dock lifts off it a little.
  @State private var keyboardUp = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        QuestionBlock(title: title, subtitle: subtitle, top: hasHeader ? 16 : 24 + 16)
        content()
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.top, 24)
      }
      .id(accountScreenBodyID)
      .padding(.horizontal, HSpacing.insetPage)
      .padding(.bottom, 16)
    }
    .scrollBounceBehavior(.basedOnSize)
    .scrollEdgeEffectStyle(.soft, for: .bottom)
    .scrollDismissesKeyboard(.interactively)
    .safeAreaBar(edge: .bottom) {
      ActionDock(keyboardUp: keyboardUp, content: footer)
    }
    .onGeometryChange(for: Bool.self) { $0.safeAreaInsets.bottom > 120 } action: { keyboardUp = $0 }
    .background(alignment: .top) {
      AmbientWash(wash).ignoresSafeArea(edges: .top)
    }
    .background(HColor.surfaceSecondary)
    .accountHeader(steps: steps, back: back, trailing: trailing)
  }

  /// Whether the header holds anything. Without back, steps or a trailing action Paper keeps
  /// a 24 pt header for the rhythm (G80, K34), so the bar goes and the space stays.
  private var hasHeader: Bool {
    if case .none = back { return steps != nil || trailing != nil }
    return true
  }
}

extension AccountScreen where Footer == EmptyView {
  init(
    title: String, subtitle: String? = nil, steps: (current: Int, of: Int)? = nil, back: AccountBack = .none,
    trailing: (title: String, action: () -> Void)? = nil, wash: HWash = .setup,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.init(title: title, subtitle: subtitle, steps: steps, back: back, trailing: trailing, wash: wash,
              content: content, footer: { EmptyView() })
  }
}

extension View {
  /// The account header on the system bar: back as `back` says, the step indicator as the
  /// principal item, and a trailing text action (`account.trailing`). No title: the
  /// question block below names the screen.
  func accountHeader(
    steps: (current: Int, of: Int)? = nil, back: AccountBack, trailing: (title: String, action: () -> Void)? = nil
  ) -> some View {
    modifier(AccountHeader(steps: steps, back: back, trailing: trailing))
  }
}

private struct AccountHeader: ViewModifier {
  let steps: (current: Int, of: Int)?
  let back: AccountBack
  let trailing: (title: String, action: () -> Void)?

  func body(content: Content) -> some View {
    content
      .navigationBarTitleDisplayMode(.inline)
      .navigationBarBackButtonHidden(!isSystemBack)
      // An empty header has no bar; hiding it also keeps the swipe from going back.
      .toolbar(isEmpty ? .hidden : .automatic, for: .navigationBar)
      .toolbar {
        if case .action(let run) = back {
          ToolbarItem(placement: .topBarLeading) {
            Button(action: run) {
              Image(systemName: "chevron.backward")
            }
            // Ink like the system back and Paper's glass Back (LPY), not the accent.
            .tint(HColor.appleLabelsVibrantPrimary)
            .accessibilityLabel("Back")
          }
        }
        if let steps {
          ToolbarItem(placement: .principal) {
            StepIndicator(current: steps.current, of: steps.of)
          }
          .sharedBackgroundVisibility(.hidden)
        }
        if let trailing {
          // Paper draws plain link text in the 72 trailing slot, not a glass capsule.
          ToolbarItem(placement: .topBarTrailing) {
            Button(action: trailing.action) {
              Text(trailing.title)
                .hType(HType(size: 17, leading: 22, weight: .regular, textStyle: .body))
                .foregroundStyle(HColor.textLink)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("account.trailing")
          }
          .sharedBackgroundVisibility(.hidden)
        }
      }
  }

  private var isSystemBack: Bool {
    if case .system = back { return true }
    return false
  }

  private var isEmpty: Bool {
    if case .none = back { return steps == nil && trailing == nil }
    return false
  }
}

/// The question block: Title 1 (28/34 bold) and a body line on the wash, 8 apart.
private struct QuestionBlock: View {
  let title: String
  let subtitle: String?
  /// 16 under the header; 40 under the status bar when there is no header.
  let top: CGFloat

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .hType(.title1)
        .foregroundStyle(HColor.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
      if let subtitle {
        Text(subtitle)
          .hType(.body)
          .foregroundStyle(HColor.textOnWashSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.top, top)
  }
}

/// The bottom dock (Paper "Action"): a primary pill, then a secondary link or a note, 4
/// apart, 20 from the sides, on the home indicator's safe area. A soft scroll edge sits
/// under it when content scrolls behind (`safeAreaBar`).
private struct ActionDock<Content: View>: View {
  let keyboardUp: Bool
  @ViewBuilder let content: () -> Content

  var body: some View {
    VStack(spacing: 4) { content() }
      .frame(maxWidth: .infinity)
      .padding(.horizontal, HSpacing.insetPage)
      .padding(.top, 8)
      .padding(.bottom, keyboardUp ? 12 : 0)
      .environment(\.pillDisabledBase, HColor.surfaceSecondary)
      .environment(\.dockTyping, keyboardUp)
      .hAnimation(.fade, value: keyboardUp)
  }
}

extension EnvironmentValues {
  @Entry var dockTyping = false
}

private struct DockLinkWhileTyping: ViewModifier {
  @Environment(\.dockTyping) private var typing

  func body(content: Content) -> some View {
    if !typing {
      content.transition(.opacity)
    }
  }
}

extension View {
  func dockLink() -> some View {
    modifier(DockLinkWhileTyping())
  }

  func revealsOnKeyboard(_ id: String) -> some View {
    modifier(KeyboardReveal(id: id))
  }
}

private struct KeyboardReveal: ViewModifier {
  let id: String
  @Environment(\.hMotion) private var motion

  func body(content: Content) -> some View {
    ScrollViewReader { proxy in
      content
        .onGeometryChange(for: Bool.self) { $0.safeAreaInsets.bottom > 120 } action: { up in
          guard up else { return }
          Task { withAnimation(motion.animation(.fade)) { proxy.scrollTo(id) } }
        }
    }
  }
}

// MARK: - Actions at the largest text sizes

extension AccountScreen {
  /// The account template with its actions docked as Paper draws them, except at the
  /// accessibility text sizes: there two wrapped buttons would fill half the screen and
  /// still clip (the dock can't scroll), so they follow the content and scroll with it
  /// (spec 07 §8, plan 0.1 rule 11). The join and phrase screens use it (requests/p1.md 1); a
  /// screen whose dock must stay over the keyboard at every size (unlock's word list) keeps
  /// `footer:`.
  init<Main: View, Actions: View>(
    title: String, subtitle: String? = nil, steps: (current: Int, of: Int)? = nil, back: AccountBack = .none,
    trailing: (title: String, action: () -> Void)? = nil, wash: HWash = .setup,
    @ViewBuilder content: @escaping () -> Main, @ViewBuilder actions: @escaping () -> Actions
  ) where Content == ActionsAfterContent<Main, Actions>, Footer == DockedActions<Actions> {
    self.init(
      title: title, subtitle: subtitle, steps: steps, back: back, trailing: trailing, wash: wash,
      content: { ActionsAfterContent(content: content(), actions: actions) },
      footer: { DockedActions(actions: actions) })
  }
}

/// The page's content, then (at the accessibility sizes only) its actions, 32 under it.
struct ActionsAfterContent<Main: View, Actions: View>: View {
  let content: Main
  let actions: () -> Actions

  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      content
      if typeSize.isAccessibilitySize {
        VStack(spacing: 4) { actions() }
          .frame(maxWidth: .infinity)
          .padding(.top, 32)
      }
    }
  }
}

/// The dock's actions, 4 apart, below the accessibility sizes.
struct DockedActions<Actions: View>: View {
  let actions: () -> Actions

  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    if !typeSize.isAccessibilitySize {
      VStack(spacing: 4) { actions() }
    }
  }
}

// MARK: - Celebration screen

/// A done screen (Paper "Your account is ready." FJI-0, "You're back in" H5V-0, "You're set"
/// GWF-0): the ready wash, the success badge with its glow and sparks, a large centred
/// title and body, a fact card, and the dock. No header and no way back.
///
/// The badge lands once (`.celebrate`, under 600 ms; still under Reduce Motion), and
/// `successHaptic` plays the success haptic as it settles ("You're set", a mailbox
/// connected: the motion policy's two).
struct CelebrationScreen<Cards: View, Footer: View>: View {
  var badge: SuccessBadge.Content?
  var title: String
  var subtitle: String?
  var wash: HWash
  var successHaptic: Bool
  /// The badge under the status bar, and the cards under the copy: 76 and 36 on the account
  /// boards (FJI, GL7, H5V); setup's result and done screens draw 40 and 28 (7DG, GWF).
  var spacing: (top: CGFloat, cards: CGFloat)
  @ViewBuilder var cards: () -> Cards
  @ViewBuilder var footer: () -> Footer

  init(
    badge: SuccessBadge.Content? = .check, title: String, subtitle: String? = nil, wash: HWash = .ready,
    successHaptic: Bool = false, spacing: (top: CGFloat, cards: CGFloat) = (76, 36),
    @ViewBuilder cards: @escaping () -> Cards, @ViewBuilder footer: @escaping () -> Footer
  ) {
    self.badge = badge
    self.title = title
    self.subtitle = subtitle
    self.wash = wash
    self.successHaptic = successHaptic
    self.spacing = spacing
    self.cards = cards
    self.footer = footer
  }

  @State private var keyboardUp = false
  @State private var landed = false

  var body: some View {
    ScrollView {
      VStack(spacing: 0) {
        VStack(spacing: 20) {
          if let badge { SuccessBadge(content: badge) }
          VStack(spacing: 8) {
            Text(title)
              .hType(.largeTitle)
              .foregroundStyle(HColor.textPrimary)
              .accessibilityAddTraits(.isHeader)
            if let subtitle {
              Text(subtitle)
                .hType(.body)
                .foregroundStyle(HColor.textOnWashSecondary)
                .frame(maxWidth: 300)
            }
          }
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.top, badge == nil ? min(40, spacing.top) : spacing.top)
        cards()
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, HSpacing.insetPage)
          .padding(.top, spacing.cards)
      }
      .padding(.bottom, 16)
    }
    .scrollBounceBehavior(.basedOnSize)
    .scrollEdgeEffectStyle(.soft, for: .bottom)
    .safeAreaBar(edge: .bottom) {
      ActionDock(keyboardUp: keyboardUp, content: footer)
    }
    .background(alignment: .top) {
      AmbientWash(wash).ignoresSafeArea(edges: .top)
    }
    .background(HColor.surfaceSecondary)
    .navigationBarBackButtonHidden()
    .toolbar(.hidden, for: .navigationBar)
    .task {
      guard successHaptic, !landed else { return }
      // When the badge has settled, not as it starts (spec 01 §4.11).
      try? await Task.sleep(for: .seconds(HMotion.celebrateResponse))
      landed = true
    }
    .hHaptic(.success, trigger: landed)
  }
}

extension CelebrationScreen where Footer == EmptyView {
  init(
    badge: SuccessBadge.Content? = .check, title: String, subtitle: String? = nil, wash: HWash = .ready,
    successHaptic: Bool = false, spacing: (top: CGFloat, cards: CGFloat) = (76, 36),
    @ViewBuilder cards: @escaping () -> Cards
  ) {
    self.init(badge: badge, title: title, subtitle: subtitle, wash: wash, successHaptic: successHaptic,
              spacing: spacing, cards: cards, footer: { EmptyView() })
  }
}

// MARK: - Cards

/// A 40 icon tile: a hue disc with a 20 line icon in the hue's ink (Paper "IconTile").
struct IconTile: View {
  var icon: HIcon
  var hue: Hue

  var body: some View {
    CategoryDisc(hue: hue, icon: icon, size: .s40)
  }
}

/// The mint "Recommended" or "Fastest" chip on an option (Paper "HueChip"): 24 tall,
/// radius 12, the mint gradient, 13/18 semibold in the mint ink.
struct HueChip: View {
  var text: String
  var hue: Hue = .mint

  var body: some View {
    Text(text)
      .hType(HType(size: 13, leading: 18, weight: .semibold, textStyle: .footnote))
      .foregroundStyle(hue.ink)
      .padding(.horizontal, 9)
      .frame(minHeight: 24)
      .background(hue.perceptualGradient, in: Capsule())
  }
}

/// An option with its own button (Paper "OptionCard", spec 08: unlock, recover, forgot):
/// an icon tile, an optional chip, a 17/22 title and a 15/20 line, then a 50 card button.
struct OptionCard: View {
  enum ButtonKind { case primary, secondary }

  var icon: HIcon
  var hue: Hue
  var chip: String?
  var title: String
  var detail: String
  var buttonTitle: String
  var buttonKind: ButtonKind = .secondary
  var buttonIcon: HIcon?
  var busy = false
  var identifier: String
  var action: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .top, spacing: 12) {
        IconTile(icon: icon, hue: hue)
        CardText(chip: chip, title: title, detail: detail)
      }
      .accessibilityElement(children: .combine)
      Button(buttonTitle, action: action)
        .buttonStyle(CardButtonStyle(kind: buttonKind, icon: buttonIcon, loading: busy))
        .accessibilityIdentifier(identifier)
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
  }
}

/// The 50 button inside an option card (Paper "CardButton"): primary (accent, white label)
/// or secondary (accent-subtle, link label), 17/24 semibold, radius 25. It presses like
/// every pill (darken and 0.97, 120 ms back; colour only with Reduce Motion).
private struct CardButtonStyle: ButtonStyle {
  let kind: OptionCard.ButtonKind
  let icon: HIcon?
  let loading: Bool

  func makeBody(configuration: Configuration) -> some View {
    CardButtonBody(configuration: configuration, kind: kind, icon: icon, loading: loading)
  }
}

private struct CardButtonBody: View {
  let configuration: ButtonStyleConfiguration
  let kind: OptionCard.ButtonKind
  let icon: HIcon?
  let loading: Bool
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.hMotion) private var policy
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let pressed = configuration.isPressed && !loading
    let motion = MotionPolicy(reduceMotion: policy.reduceMotion || reduceMotion, settled: policy.settled)
    HStack(spacing: 8) {
      if loading {
        Spinner(size: 20, tint: foreground,
                track: kind == .primary ? HColor.white.opacity(0.35) : HColor.actionAccentSubtlePressed)
      } else if let icon {
        HIconView(icon, size: 20, color: foreground, strokeWidth: 2)
      }
      configuration.label.multilineTextAlignment(.center)
    }
    .hType(HType(size: 17, leading: 24, weight: .semibold, textStyle: .body))
    .foregroundStyle(foreground)
    .padding(.horizontal, 12)
    .frame(maxWidth: .infinity, minHeight: 50)
    .background(fill(pressed: pressed), in: Capsule())
    .contentShape(Capsule())
    .scaleEffect(pressed && !motion.isStill ? HMotion.pressScale : 1)
    .animation(pressed ? nil : motion.animation(.press), value: pressed)
    .allowsHitTesting(!loading)
    .accessibilityValue(loading ? Text("In progress") : Text(""))
  }

  private var foreground: Color {
    guard isEnabled else { return HColor.textDisabled }
    return kind == .primary ? HColor.textOnAccent : HColor.textLink
  }

  private func fill(pressed: Bool) -> Color {
    guard isEnabled else { return HColor.appleFillsSecondary }
    switch kind {
    case .primary: return pressed ? HColor.actionAccentPressed : HColor.actionAccent
    case .secondary: return pressed ? HColor.actionAccentSubtlePressed : HColor.actionAccentSubtle
    }
  }
}

/// A choice between two ways (Paper "SelectionCard", S8 and H43): the card is the button,
/// a 2 pt accent ring and a filled radio mark the one chosen.
struct SelectionCard: View {
  var icon: HIcon
  var hue: Hue
  var chip: String?
  var title: String
  var detail: String
  var selected: Bool
  var identifier: String
  var action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(alignment: .top, spacing: 12) {
        IconTile(icon: icon, hue: hue)
        CardText(chip: chip, title: title, detail: detail)
        Radio(on: selected)
      }
      .padding(20)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
      .overlay {
        // 2 pt outside the card edge, no gap (box-shadow 0 0 0 2px).
        RoundedRectangle(cornerRadius: HRadius.card + 2, style: .continuous)
          .strokeBorder(HColor.actionAccent, lineWidth: 2)
          .padding(-2)
          .opacity(selected ? 1 : 0)
      }
      .hAnimation(.thumbSlide, value: selected)
    }
    .buttonStyle(HPressStyle(in: RoundedRectangle(cornerRadius: HRadius.card, style: .continuous), scales: false))
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    .accessibilityIdentifier(identifier)
  }
}

/// The radio of a selection card: 24, accent with a white check when on, a 1.5 neutral
/// ring when off.
private struct Radio: View {
  let on: Bool

  var body: some View {
    ZStack {
      Circle().strokeBorder(HColor.neutral300, lineWidth: 1.5).opacity(on ? 0 : 1)
      Circle().fill(HColor.actionAccent).opacity(on ? 1 : 0)
      HIconView(.check, size: 14, color: HColor.white, strokeWidth: 3).opacity(on ? 1 : 0)
    }
    .frame(width: 24, height: 24)
    .accessibilityHidden(true)
  }
}

/// The text column of an option or selection card: chip, title (padded 4 under a chip) and
/// the line under it.
private struct CardText: View {
  let chip: String?
  let title: String
  let detail: String

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      if let chip { HueChip(text: chip) }
      Text(title)
        .hType(HType(size: 17, leading: 22, weight: .semibold, textStyle: .headline))
        .foregroundStyle(HColor.textPrimary)
        .padding(.top, chip == nil ? 0 : 4)
      Text(detail)
        .hType(.subheadline)
        .foregroundStyle(HColor.textSecondary)
    }
    .multilineTextAlignment(.leading)
    .fixedSize(horizontal: false, vertical: true)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// A card that tells one thing (Paper "InfoCard"; the hand-off cards on the done screens):
/// an icon tile, a 16/22 title and a 15/20 line, on white, radius 24 (20 as a content card).
struct InfoCard: View {
  var icon: HIcon
  var hue: Hue
  var title: String
  var detail: String
  var radius: CGFloat = HRadius.listGroup

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
    .padding(16)
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    .accessibilityElement(children: .combine)
  }
}

/// A quiet note under the content (Paper "NoteRow"): an 18 icon in icon-secondary and a
/// 13/18 line, 4 in from the content edge.
struct NoteRow: View {
  var icon: HIcon
  var text: String

  @ScaledMetric(relativeTo: .footnote) private var lane: CGFloat = 18

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      HIconView(icon, size: 18, color: HColor.iconSecondary).frame(height: lane)
      Text(text)
        .hType(.footnote)
        .foregroundStyle(HColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.top, 4)
    .padding(.horizontal, 4)
    .accessibilityElement(children: .combine)
  }
}

/// The amber note that says why something is held back (Paper "WarningCallout": no
/// screenshots on the phrase screen): a 20 icon and 15/20 medium text in the warning ink on
/// the warning surface, radius 20.
struct WarningCallout: View {
  var icon: HIcon = .cameraSlash
  var text: String

  @ScaledMetric(relativeTo: .subheadline) private var lane: CGFloat = 20

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      HIconView(icon, size: 20, color: HColor.statusWarningForeground).frame(height: lane)
      Text(text)
        .hType(.subheadline.weight(.medium))
        .foregroundStyle(HColor.statusWarningForeground)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, 14)
    .padding(.horizontal, 16)
    .background(HColor.statusWarningSurface, in: RoundedRectangle(cornerRadius: HRadius.tile, style: .continuous))
    .accessibilityElement(children: .combine)
  }
}

/// A light hint on the wash (Paper "HintCard · Spam"): an 18 icon and a 13/18 line on the
/// white-70% surface, radius 16.
struct HintCard: View {
  var icon: HIcon = .envelope
  var text: String

  @ScaledMetric(relativeTo: .footnote) private var lane: CGFloat = 18

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      HIconView(icon, size: 18, color: HColor.iconSecondary).frame(height: lane)
      Text(text)
        .hType(.footnote)
        .foregroundStyle(HColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, 12)
    .padding(.horizontal, 14)
    .background(HColor.surfaceOnWash, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .accessibilityElement(children: .combine)
  }
}

// MARK: - Dock parts

/// The link under the primary button (Paper "Secondary link (44pt target)"): 17/22
/// semibold in the link colour (or destructive), a 44 box, 16 in.
struct SecondaryLink: View {
  var title: String
  var identifier: String
  var role: ButtonRole?
  var action: () -> Void

  var body: some View {
    Button(role: role, action: action) {
      Text(title)
        .hType(HType(size: 17, leading: 22, weight: .semibold, textStyle: .body))
        .foregroundStyle(role == .destructive ? HColor.actionDestructive : HColor.textLink)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 44)
        .contentShape(Rectangle())
    }
    // A link dims while pressed, as text buttons do; it has no fill to darken.
    .buttonStyle(.plain)
    .accessibilityIdentifier(identifier)
    .dockLink()
  }
}

/// A plain note in the link's place (Paper "Note (not a link)"): 15/22 secondary in the
/// same 44 box ("Takes about two minutes. It can't be skipped.").
struct ActionNote: View {
  var text: String

  var body: some View {
    Text(text)
      .hType(HType(size: 15, leading: 22, weight: .regular, textStyle: .subheadline))
      .foregroundStyle(HColor.textSecondary)
      .multilineTextAlignment(.center)
      .padding(.horizontal, 16)
      .frame(maxWidth: .infinity, minHeight: 44)
  }
}

// MARK: - Earlier parts (kept; the packages move their screens to the parts above)

/// A labelled field on the grouped canvas: label, a white 52 pt field (r14), a footer.
/// The same field as `AccountField`, with the control as a view builder.
struct LabeledField<Field: View, Accessory: View>: View {
  var label: String
  var footer: String?
  var error: String?
  var focused = false
  @ViewBuilder var field: () -> Field
  @ViewBuilder var accessory: () -> Accessory

  var body: some View {
    FieldFrame(label: label, help: footer, error: error, focused: focused,
               trailingPill: Accessory.self != EmptyView.self) {
      field()
    } trailing: {
      accessory()
    }
  }
}

extension LabeledField where Accessory == EmptyView {
  init(label: String, footer: String? = nil, error: String? = nil, focused: Bool = false,
       @ViewBuilder field: @escaping () -> Field) {
    self.init(label: label, footer: footer, error: error, focused: focused, field: field, accessory: { EmptyView() })
  }
}

/// A dot and one line of status: success (green), error (red), info (grey). Small (13/18)
/// under a field ("Passwords match."), regular (15/20) in a card (the strength line).
struct StatusLine: View {
  enum Tone { case success, error, info }
  enum Size { case small, regular }
  var text: String
  var tone: Tone
  var size: Size = .small

  @ScaledMetric(relativeTo: .footnote) private var smallLane: CGFloat = 18
  @ScaledMetric(relativeTo: .subheadline) private var regularLane: CGFloat = 20

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Circle().fill(color).frame(width: 7, height: 7).frame(height: size == .regular ? regularLane : smallLane)
      Text(text)
        .hType((size == .regular ? HType.subheadline : HType.footnote).weight(tone == .info ? .regular : .semibold))
        .foregroundStyle(color)
        .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("status.\(tone)")
  }

  private var color: Color {
    switch tone {
    case .success: HColor.statusSuccessForeground
    case .error: HColor.statusErrorForeground
    case .info: HColor.textSecondary
    }
  }
}

/// A white r20 card with an icon and text (the "We only email you about…" note).
struct NoteCard: View {
  var systemImage: String
  var title: String?
  var text: String
  var tint: Color = HColor.surfacePrimary

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: systemImage)
        .font(.system(size: 17, weight: .medium))
        .foregroundStyle(HColor.iconPrimary)
        .frame(width: 22)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        if let title {
          Text(title).hType(.rowTitle).foregroundStyle(HColor.textPrimary)
        }
        Text(text)
          .hType(.subheadline)
          .foregroundStyle(HColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .padding(16)
    .background(tint, in: RoundedRectangle(cornerRadius: HRadius.tile, style: .continuous))
    .accessibilityElement(children: .combine)
  }
}

/// A small footnote with a leading lock (Paper's bottom notes).
struct LockNote: View {
  var text: String
  var systemImage = "lock"

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: systemImage)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(HColor.iconSecondary)
        .padding(.top, 2)
        .accessibilityHidden(true)
      Text(text)
        .hType(.footnote)
        .foregroundStyle(HColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// A filling pill for a step's main action: the kit's loading state (spinner and label,
/// same size, taps blocked) while `busy`, and Paper's disabled fill until `enabled`.
struct BusyButton: View {
  var title: String
  var busy: Bool
  var kind: PillButtonStyle.Kind = .primary
  var enabled = true
  var identifier: String
  var action: () -> Void

  var body: some View {
    Button(title, action: action)
      .buttonStyle(.pill(kind, fill: true, loading: busy))
      .disabled(!enabled)
      .accessibilityIdentifier(identifier)
  }
}

/// A full-width text link under the primary button (44 pt). `SecondaryLink` is the same
/// part in Paper's type; this one keeps the button type its screens were drawn with.
struct LinkButton: View {
  var title: String
  var identifier: String
  var role: ButtonRole?
  var action: () -> Void

  var body: some View {
    SecondaryLink(title: title, identifier: identifier, role: role, action: action)
  }
}

/// The error banner a screen shows for a failure (one line of copy).
struct FailureBanner: View {
  var failure: AuthFailure?

  var body: some View {
    if let message = failure?.message {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: "exclamationmark.circle.fill")
          .foregroundStyle(HColor.statusErrorForeground)
          .accessibilityHidden(true)
        Text(message)
          .hType(.subheadline)
          .foregroundStyle(HColor.statusErrorForeground)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
      }
      .padding(14)
      .background(HColor.statusErrorSurface, in: RoundedRectangle(cornerRadius: HRadius.control, style: .continuous))
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("account.failure")
      .hTransition(.rise)
    }
  }
}

/// A text link that opens Safari, with a 44 pt hit area.
struct WebLink: View {
  var title: String
  var url: String
  var identifier: String

  var body: some View {
    Link(destination: URL(string: url)!) {
      Text(title)
        .hType(HType(size: 17, leading: 22, weight: .semibold, textStyle: .body))
        .foregroundStyle(HColor.textLink)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 44)
        .contentShape(Rectangle())
    }
    .accessibilityIdentifier(identifier)
    .dockLink()
  }
}

/// A small inline text button ("Forgot password?", "Resend code", "Change email"): Paper's
/// InlineLink, 15/20 semibold in the link colour, with a 44 pt hit area.
struct InlineTextButton: View {
  var title: String
  var identifier: String
  var action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(title)
        .hType(.subheadline.weight(.semibold))
        .foregroundStyle(HColor.textLink)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier(identifier)
  }
}
