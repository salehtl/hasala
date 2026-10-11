import HasalaDesign
import SwiftUI

// The account screen template (Paper page 14 "Template · Account screen"): the morning
// wash at the top, a glass back button and the step dashes, a title-1 headline and its
// subtitle, the content, and a footer of pill buttons pinned above the home indicator.

struct AccountScreen<Content: View, Footer: View>: View {
  var title: String
  var subtitle: String?
  var steps: (current: Int, of: Int)?
  var onBack: (() -> Void)?
  var trailing: (title: String, action: () -> Void)?
  var wash: Color = HColor.washMorning
  var centered = false
  @ViewBuilder var content: () -> Content
  @ViewBuilder var footer: () -> Footer

  var body: some View {
    ScrollView {
      VStack(alignment: centered ? .center : .leading, spacing: 0) {
        topBar
        VStack(alignment: centered ? .center : .leading, spacing: 8) {
          Text(title)
            .hType(.title1)
            .foregroundStyle(HColor.textPrimary)
            .multilineTextAlignment(centered ? .center : .leading)
            .accessibilityAddTraits(.isHeader)
          if let subtitle {
            Text(subtitle)
              .hType(.body)
              .foregroundStyle(HColor.textOnWashSecondary)
              .multilineTextAlignment(centered ? .center : .leading)
          }
        }
        .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
        .padding(.top, 16)
        content()
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.top, 24)
      }
      .padding(.horizontal, HSpacing.insetPage)
      .padding(.bottom, 24)
    }
    .scrollBounceBehavior(.basedOnSize)
    .scrollDismissesKeyboard(.interactively)
    .safeAreaInset(edge: .bottom) {
      VStack(spacing: 4) { footer() }
        .padding(.horizontal, HSpacing.insetPage)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(HColor.surfaceSecondary.opacity(0.94))
    }
    .background(alignment: .top) {
      LinearGradient(colors: [wash, wash.opacity(0.45), HColor.surfaceSecondary.opacity(0)],
                     startPoint: .top, endPoint: .bottom)
        .frame(height: 360)
        .ignoresSafeArea(edges: .top)
    }
    .background(HColor.surfaceSecondary)
    .toolbar(.hidden, for: .navigationBar)
  }

  @ViewBuilder private var topBar: some View {
    if onBack != nil || steps != nil || trailing != nil {
      HStack {
        Group {
          if let onBack {
            GlassBackButton(action: onBack)
          } else {
            Color.clear.frame(width: 48, height: 48)
          }
        }
        .frame(width: 72, alignment: .leading)
        Spacer(minLength: 0)
        if let steps { StepDashes(current: steps.current, of: steps.of) }
        Spacer(minLength: 0)
        Group {
          if let trailing {
            InlineTextButton(title: trailing.title, identifier: "account.trailing", action: trailing.action)
          } else {
            Color.clear.frame(width: 1, height: 48)
          }
        }
        .frame(width: 72, alignment: .trailing)
      }
      .padding(.top, 6)
    }
  }
}

extension AccountScreen where Footer == EmptyView {
  init(
    title: String, subtitle: String? = nil, steps: (current: Int, of: Int)? = nil, onBack: (() -> Void)? = nil,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.init(title: title, subtitle: subtitle, steps: steps, onBack: onBack, content: content, footer: { EmptyView() })
  }
}

/// The 48 pt glass back button.
struct GlassBackButton: View {
  var action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: "chevron.left")
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(HColor.textPrimary)
        .frame(width: 48, height: 48)
    }
    .buttonStyle(.plain)
    .glassEffect(.regular.interactive(), in: Circle())
    .accessibilityLabel("Back")
    .accessibilityIdentifier("account.back")
  }
}

/// The step indicator: 24 × 4 dashes, the done ones in the accent.
struct StepDashes: View {
  var current: Int
  var of: Int

  var body: some View {
    HStack(spacing: 6) {
      ForEach(1...max(of, 1), id: \.self) { i in
        Capsule()
          .fill(i <= current ? HColor.actionAccent : HColor.appleFillsSecondary)
          .frame(width: 24, height: 4)
      }
    }
    .frame(minWidth: 44, minHeight: 44)
    .contentShape(Rectangle())
    .accessibilityElement()
    .accessibilityLabel("Step \(current) of \(of)")
  }
}

/// A labelled field on the grouped canvas: label, a white 52 pt field (r14), a footer.
struct LabeledField<Field: View, Accessory: View>: View {
  var label: String
  var footer: String?
  var error: String?
  var focused = false
  @ViewBuilder var field: () -> Field
  @ViewBuilder var accessory: () -> Accessory

  var body: some View {
    VStack(alignment: .leading, spacing: HSpacing.fieldLabelGap) {
      Text(label)
        .hType(.footnote.weight(.semibold))
        .foregroundStyle(HColor.textSecondary)
      HStack(spacing: 8) {
        field()
          .hType(.body)
          .foregroundStyle(HColor.fieldText)
          .frame(maxWidth: .infinity, alignment: .leading)
        accessory()
      }
      .padding(.leading, HSpacing.fieldInsetInline)
      .padding(.trailing, 8)
      .frame(minHeight: HSpacing.fieldMinHeight)
      .background(HColor.fieldSurfaceOnGrouped, in: RoundedRectangle(cornerRadius: HRadius.field, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: HRadius.field, style: .continuous)
          .strokeBorder(error != nil ? HColor.fieldError : (focused ? HColor.fieldFocus : .clear), lineWidth: 2)
      }
      if let error {
        StatusLine(text: error, tone: .error)
      } else if let footer {
        Text(footer)
          .hType(.footnote)
          .foregroundStyle(HColor.textSecondary)
      }
    }
  }
}

extension LabeledField where Accessory == EmptyView {
  init(label: String, footer: String? = nil, error: String? = nil, focused: Bool = false,
       @ViewBuilder field: @escaping () -> Field) {
    self.init(label: label, footer: footer, error: error, focused: focused, field: field, accessory: { EmptyView() })
  }
}

/// A dot and one line of status: success (green), error (red), info (grey).
struct StatusLine: View {
  enum Tone { case success, error, info }
  var text: String
  var tone: Tone

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Circle().fill(color).frame(width: 6, height: 6).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3 }
      Text(text)
        .hType(.footnote.weight(tone == .info ? .regular : .semibold))
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
    .background(tint, in: RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
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

/// A round icon disc for rows and cards.
struct IconDisc: View {
  var systemImage: String
  var tint: Color = HColor.actionAccentSubtle
  var ink: Color = HColor.actionAccent
  var size: CGFloat = 40

  var body: some View {
    Image(systemName: systemImage)
      .font(.system(size: size * 0.42, weight: .medium))
      .foregroundStyle(ink)
      .frame(width: size, height: size)
      .background(tint, in: Circle())
      .accessibilityHidden(true)
  }
}

/// The success badge over the "account ready" and "done" boards.
struct SuccessBadge: View {
  var systemImage = "checkmark"

  var body: some View {
    Image(systemName: systemImage)
      .font(.system(size: 28, weight: .semibold))
      .foregroundStyle(HColor.statusSuccessForeground)
      .frame(width: 72, height: 72)
      .background(HColor.statusSuccessSurface, in: Circle())
      .shadow(color: HColor.elevationFar, radius: 16, y: 8)
      .accessibilityHidden(true)
  }
}

/// A primary pill that shows a spinner while `busy`.
struct BusyButton: View {
  var title: String
  var busy: Bool
  var kind: PillButtonStyle.Kind = .primary
  var enabled = true
  var identifier: String
  var action: () -> Void

  var body: some View {
    Button(action: action) {
      ZStack {
        Text(title).opacity(busy ? 0 : 1)
        if busy { ProgressView().tint(kind == .primary ? HColor.textOnAccent : HColor.textLink) }
      }
    }
    .buttonStyle(.pill(enabled ? kind : .tertiary, fill: true))
    .opacity(enabled ? 1 : 0.55)
    .disabled(!enabled || busy)
    .accessibilityIdentifier(identifier)
  }
}

/// A full-width text link under the primary button (44 pt).
struct LinkButton: View {
  var title: String
  var identifier: String
  var role: ButtonRole?
  var action: () -> Void

  var body: some View {
    Button(title, role: role, action: action)
      .hType(.button)
      .foregroundStyle(role == .destructive ? HColor.actionDestructive : HColor.textLink)
      .multilineTextAlignment(.center)
      .frame(maxWidth: .infinity, minHeight: 44)
      .accessibilityIdentifier(identifier)
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
        .hType(.button)
        .foregroundStyle(HColor.textLink)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, minHeight: 44)
        .contentShape(Rectangle())
    }
    .accessibilityIdentifier(identifier)
  }
}

/// A small inline text button ("Forgot password?", "Resend code") with a 44 pt hit area.
struct InlineTextButton: View {
  var title: String
  var identifier: String
  var action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(title)
        .hType(.rowTitle)
        .foregroundStyle(HColor.textLink)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier(identifier)
  }
}
