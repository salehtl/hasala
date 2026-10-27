import HasalaDesign
import HasalaModels
import SwiftUI

/// Review · Pick a need (Paper 3SH-0), and its Want, Save and Transfer equivalents: a white
/// medium sheet floating 8 from the edges (radius 40), one detent that fits its content. The
/// bucket's categories with the suggestion marked "Suggested", the project chips and "Always
/// use it for M". A tap on a category files the card at once. Close, a swipe down or the
/// scrim cancel: nothing is sorted and the card goes back to the deck. At large text sizes it grows to large and
/// scrolls (page 14).
struct ReviewPickSheet: View {
  let model: any ReviewDeckModel
  let pick: ReviewPick
  let sort: (CategoryID, Bool, ProjectID?) -> Void
  let create: (String, Glyph, Bool, ProjectID?) -> String?

  @State private var project: ProjectID?
  @State private var alwaysUse = false
  /// The content's measured height, which the one detent fits; an estimate until then.
  @State private var contentHeight: CGFloat?
  @State private var formOffer: CountsAsOption?
  @State private var saved = false
  @State private var name = ""
  @State private var glyph = CategoryIconGuess.fallback
  @State private var glyphPicked = false
  @State private var refusal: String?
  @FocusState private var nameFocused: Bool
  @Environment(\.dismiss) private var dismiss
  @Environment(\.dynamicTypeSize) private var typeSize

  private var options: [CategoryOption] { model.options(for: pick.choice, card: pick.card.id) }
  private var projectChoices: [ProjectChoice] { model.projects(for: pick.card.id) }
  private var showsProjects: Bool { !projectChoices.isEmpty && pick.choice != .transfer }
  private var newCategory: CountsAsOption? { model.newCategory(for: pick.choice, card: pick.card.id) }

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          if let formOffer {
            form(formOffer)
          } else {
            header
            list
            if showsProjects { projects }
            if canAlwaysUse { ruleRow }
            if let newCategory { newCategoryRow(newCategory) }
          }
        }
        .padding(.top, 8)
        .padding(.horizontal, HSpacing.insetPage)
        .padding(.bottom, 28)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        .hAnimation(.sheetContent, value: creating)
        .id(Self.top)
      }
      .onChange(of: creating) { proxy.scrollTo(Self.top, anchor: .top) }
    }
    .scrollBounceBehavior(.basedOnSize)
    // Paper: "Sort into" sits 28 above the sheet's own bottom edge, which floats over the
    // home indicator; the detent is exactly the content.
    .ignoresSafeArea(.container, edges: typeSize.isAccessibilitySize ? [] : .bottom)
    .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.height(contentHeight ?? estimatedHeight)])
    .presentationDragIndicator(.visible)
    .presentationBackground(HColor.sheetSurface)
    .presentationCornerRadius(HRadius.sheet)
    .onChange(of: name) { _, new in
      if !glyphPicked { glyph = CategoryIconGuess.glyph(for: new) }
      refusal = nil
    }
    .task(id: creating) {
      if creating { nameFocused = true }
    }
  }

  private static let top = "pick.top"

  private var creating: Bool { formOffer != nil }

  private var suggested: CategoryID? { pick.card.suggestion?.id }

  private var canAlwaysUse: Bool { pick.card.canAlwaysUse }

  /// The sheet's height before the content is measured, from Paper's parts (header 60, rows
  /// 56 with 1 dividers, the project block 66, the rule row 44, gaps 20, and the 8 / 28
  /// insets), so it opens at its size instead of growing into it.
  private var estimatedHeight: CGFloat {
    let n = CGFloat(options.count)
    let projects: CGFloat = showsProjects ? 66 + 20 : 0
    let rule: CGFloat = canAlwaysUse ? 20 + 44 : 0
    let add: CGFloat = newCategory != nil ? 20 + 56 : 0
    return 8 + 60 + 20 + 56 * n + max(0, n - 1) + projects + rule + add + 28
  }

  /// Close, "Need · which one?", and the empty 48 slot that keeps the title centred.
  @ViewBuilder private var header: some View {
    let close = GlassIconButton(.close, label: "Close") { dismiss() }
      .accessibilityIdentifier("pick.close")
    let title = Text("\(pick.choice.label) · which one?")
      .hType(.headline.weight(.semibold))
      .foregroundStyle(HColor.textPrimary)
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityAddTraits(.isHeader)
    if typeSize.isAccessibilitySize {
      VStack(alignment: .leading, spacing: 12) {
        close
        title
      }
      .padding(.top, 12)
    } else {
      HStack {
        close
        Spacer(minLength: 8)
        title.multilineTextAlignment(.center)
        Spacer(minLength: 8)
        Color.clear.frame(width: HSpacing.glassButton, height: HSpacing.glassButton)
      }
      .padding(.top, 12)
    }
  }

  /// The bucket's categories, straight on the sheet: disc 40, name, "Suggested".
  private var list: some View {
    VStack(spacing: 0) {
      ForEach(Array(options.enumerated()), id: \.element.id) { i, o in
        if i > 0 {
          HColor.borderSubtle.frame(height: 1).padding(.leading, 52).accessibilityHidden(true)
        }
        Button {
          sort(o.id, alwaysUse, project)
        } label: {
          HStack(spacing: 12) {
            CategoryDisc(hue: o.hue, icon: o.glyph.icon)
            let words = typeSize.isAccessibilitySize
              ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
              : AnyLayout(HStackLayout(spacing: 12))
            words {
              Text(o.name).hType(.rowTitle).foregroundStyle(HColor.listRowTitle)
                .fixedSize(horizontal: false, vertical: true)
              if suggested == o.id {
                InfoChip("Suggested", style: .suggested)
              }
            }
            Spacer(minLength: 8)
          }
          .frame(minHeight: 56)
          .contentShape(Rectangle())
        }
        .buttonStyle(HRowPressStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(suggested == o.id ? "\(o.name), suggested" : o.name)
        .accessibilityHint("Sorts it now")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("pick.\(o.id)")
      }
    }
  }

  /// "PROJECT": None or one of the open projects, as choice chips on the white sheet.
  private var projects: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Project").hType(.overline).foregroundStyle(HColor.textSecondary)
        .accessibilityAddTraits(.isHeader)
      FlowLayout(spacing: 8) {
        ChoiceChip("None", selected: project == nil, onCard: true) { project = nil }
          .accessibilityIdentifier("pick.project.none")
        ForEach(projectChoices) { p in
          HStack(spacing: 6) {
            ChoiceChip(p.name, dot: .peach, selected: project == p.id, onCard: true) { project = p.id }
              .accessibilityLabel(p.suggested ? "\(p.name), suggested" : p.name)
              .accessibilityIdentifier("pick.project.\(p.id)")
            if p.suggested {
              InfoChip("Suggested", style: .suggested).accessibilityHidden(true)
            }
          }
        }
      }
    }
  }

  @ViewBuilder private var ruleRow: some View {
    let label = Text("Always use it for \(pick.card.merchant)")
      .hType(.subheadline.weight(.medium))
      .foregroundStyle(HColor.textPrimary)
      .fixedSize(horizontal: false, vertical: true)
    if typeSize.isAccessibilitySize {
      Toggle(isOn: $alwaysUse) { label }
        .tint(HColor.controlSwitchTrackOn)
        .accessibilityIdentifier("pick.alwaysUse")
    } else {
      Toggle(isOn: $alwaysUse) { label }
        .toggleStyle(CheckboxToggleStyle())
        .accessibilityIdentifier("pick.alwaysUse")
    }
  }

  private func newCategoryRow(_ offer: CountsAsOption) -> some View {
    Button { openForm(offer) } label: {
      let icon = HIconView(.add, size: 22, color: HColor.listRowAction).accessibilityHidden(true)
      let title = Text("New category").hType(.rowTitle).foregroundStyle(HColor.listRowAction)
        .fixedSize(horizontal: false, vertical: true)
      Group {
        if typeSize.isAccessibilitySize {
          VStack(alignment: .leading, spacing: 8) {
            icon
            title
          }
          .padding(.vertical, 14)
          .frame(maxWidth: .infinity, alignment: .leading)
        } else {
          HStack(spacing: 12) {
            icon.frame(width: HSpacing.listRowLeadingDisc, height: HSpacing.listRowLeadingDisc)
            title
            Spacer(minLength: 8)
          }
          .frame(minHeight: 56)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(HRowPressStyle())
    .accessibilityHint("Adds a category and sorts it there")
    .accessibilityIdentifier("pick.newCategory")
  }

  @ViewBuilder private func form(_ offer: CountsAsOption) -> some View {
    formHeader
    CategoryNameIconForm(
      name: $name, glyph: Binding(get: { glyph }, set: { pickGlyph($0) }), hue: offer.bucket.hue,
      ids: CategoryFormIDs(name: "pick.newCategory.name", icon: "pick.newCategory.icon"), fieldSurface: HColor.fieldSurface,
      nameFocus: $nameFocused
    ) {
      if let refusal {
        Text(refusal).hType(.footnote).foregroundStyle(HColor.statusErrorForeground)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 4)
          .accessibilityIdentifier("pick.newCategory.refusal")
      }
    }
  }

  @ViewBuilder private var formHeader: some View {
    let back = GlassIconButton(.back, label: "Back", action: closeForm)
      .accessibilityIdentifier("pick.newCategory.back")
    let save = GlassIconButton(.done, label: "Save", prominent: true, action: save)
      .accessibilityIdentifier("pick.newCategory.save")
    let title = Text("\(pick.choice.label) · new category")
      .hType(.headline.weight(.semibold))
      .foregroundStyle(HColor.textPrimary)
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityAddTraits(.isHeader)
      .accessibilityIdentifier("pick.newCategory.title")
    if typeSize.isAccessibilitySize {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          back
          Spacer(minLength: 8)
          save
        }
        title
      }
      .padding(.top, 12)
    } else {
      HStack {
        back
        Spacer(minLength: 8)
        title.multilineTextAlignment(.center)
        Spacer(minLength: 8)
        save
      }
      .padding(.top, 12)
    }
  }

  private func pickGlyph(_ g: Glyph) {
    glyph = g
    glyphPicked = true
  }

  private func openForm(_ offer: CountsAsOption) {
    name = ""
    glyph = CategoryIconGuess.fallback
    glyphPicked = false
    refusal = nil
    formOffer = offer
  }

  private func closeForm() {
    nameFocused = false
    refusal = nil
    formOffer = nil
  }

  private func save() {
    guard !saved else { return }
    guard let why = create(name, glyph, alwaysUse, project) else {
      saved = true
      return
    }
    refusal = why
    AccessibilityNotification.Announcement(why).post()
  }
}

/// A 24 accent checkbox, radius 6, in a 40 slot (Paper "Rule checkbox"; spec 04 §14.6
/// `CheckboxSquare`). The whole row toggles it.
struct CheckboxToggleStyle: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View {
    CheckboxRow(configuration: configuration)
  }
}

private struct CheckboxRow: View {
  let configuration: ToggleStyleConfiguration

  var body: some View {
    Button { configuration.isOn.toggle() } label: {
      HStack(alignment: .top, spacing: 12) {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(configuration.isOn ? HColor.actionAccent : HColor.surfacePrimary)
          .overlay {
            if configuration.isOn {
              HIconView(.check, size: 16, color: HColor.white, strokeWidth: 3)
            } else {
              RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(HColor.controlCheckUnselected, lineWidth: 1.5)
            }
          }
          .frame(width: 24, height: 24)
          .frame(width: 40, height: 40)
        configuration.label
          .fixedSize(horizontal: false, vertical: true)
          .padding(.vertical, 10)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(minHeight: HSpacing.targetMinimum)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(configuration.isOn ? [.isSelected] : [])
  }
}

enum ReviewReasonStyle {
  static func ink(_ reason: TxnReviewReason) -> Color {
    switch reason {
    case .senderUnverified: HColor.statusWarningForeground
    case .probableCopy, .samePurchase, .mayRepeat: HColor.statusInfoForeground
    }
  }

  static func surface(_ reason: TxnReviewReason) -> Color {
    switch reason {
    case .senderUnverified: HColor.statusWarningSurface
    case .probableCopy, .samePurchase, .mayRepeat: HColor.reviewSuggestionSurface
    }
  }

  static func icon(_ reason: TxnReviewReason) -> HIcon {
    switch reason {
    case .senderUnverified: .shield
    case .probableCopy: .envelope
    case .samePurchase: .globe
    case .mayRepeat: .chat
    }
  }

  static func chip(_ reason: TxnReviewReason) -> InfoChip.Style {
    switch reason {
    case .senderUnverified: .warningReason
    case .probableCopy, .samePurchase, .mayRepeat: .reason
    }
  }
}

struct ReviewReasonSheet: View {
  let reason: TxnReviewReason
  let sort: () -> Void
  let archive: () -> Void
  let merge: () -> Void
  let keepBoth: () -> Void

  @State private var contentHeight: CGFloat?
  @Environment(\.dismiss) private var dismiss
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          header
          ReviewReasonInfo(reason: reason, sort: sort, archive: archive, merge: merge, keepBoth: keepBoth)
        }
        .padding(.top, 8)
        .padding(.horizontal, HSpacing.insetPage)
        .padding(.bottom, 28)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
      }
      .scrollBounceBehavior(.basedOnSize)
      .ignoresSafeArea(.container, edges: typeSize.isAccessibilitySize ? [] : .bottom)
      .background(HColor.sheetSurface)
      .toolbar(.hidden, for: .navigationBar)
    }
    .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.height(contentHeight ?? 600)])
    .presentationDragIndicator(.visible)
    .presentationBackground(HColor.sheetSurface)
    .presentationCornerRadius(HRadius.sheet)
  }

  private var header: some View {
    HStack {
      GlassIconButton(.close, label: "Close") { dismiss() }
        .accessibilityIdentifier("reason.close")
      Spacer(minLength: 8)
      Text("About this alert")
        .hType(.headline.weight(.semibold))
        .foregroundStyle(HColor.textPrimary)
        .multilineTextAlignment(.center)
        .accessibilityAddTraits(.isHeader)
      Spacer(minLength: 8)
      Color.clear.frame(width: HSpacing.glassButton, height: HSpacing.glassButton)
    }
    .padding(.top, 12)
  }
}

struct ReviewReasonPage: View {
  let reason: TxnReviewReason
  let sort: () -> Void
  let archive: () -> Void
  let merge: () -> Void
  let keepBoth: () -> Void

  var body: some View {
    ScrollView {
      ReviewReasonInfo(reason: reason, sort: sort, archive: archive, merge: merge, keepBoth: keepBoth)
        .padding(.horizontal, HSpacing.insetPage)
        .padding(.top, 8)
        .padding(.bottom, 40)
    }
    .background(HColor.sheetSurfaceLarge)
    .navigationTitle("About this alert")
    .navigationBarTitleDisplayMode(.inline)
  }
}

struct ReviewReasonInfo: View {
  let reason: TxnReviewReason
  let sort: () -> Void
  let archive: () -> Void
  let merge: () -> Void
  let keepBoth: () -> Void

  @ScaledMetric(relativeTo: .subheadline) private var stepDisc: CGFloat = 24

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      hero
      whatToDo.padding(.bottom, 8)
      actions
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("reason.info")
  }

  private var explanation: String {
    switch reason {
    case .senderUnverified:
      "Your mailbox couldn't confirm that this email came from your bank. It may still be real, so check it before you sort it."
    case .probableCopy:
      "Another alert has the same bank, card, amount and merchant, a few minutes apart. Bank alerts often reach two inboxes. Until you choose, it doesn't count in your totals."
    case .samePurchase:
      "Your bank sent an alert in another currency, then this one in AED a few days later on the same card. It's often the same purchase. Until you choose, both count in your totals."
    case .mayRepeat:
      "A bank text and a bank email, or two bank texts, can tell of one payment in different words, so Hasala couldn't be sure. Until you choose, both count in your totals."
    }
  }

  private var steps: [String] {
    switch reason {
    case .senderUnverified:
      [
        "Open your bank app and look for this payment.",
        "If it's there, sort it as usual.",
        "If it isn't, archive it so it stays out of your plan. Don't tap links in that email.",
      ]
    case .probableCopy:
      ["Merge it if it's the same payment.", "Keep both if you really paid twice."]
    case .samePurchase:
      [
        "If it's the same purchase, the original keeps this AED amount and this alert moves to Archived.",
        "Keep both if they're two different purchases.",
      ]
    case .mayRepeat:
      [
        "Look for the payment in your bank app.",
        "If it's the same payment, archive this one.",
        "If you paid twice, sort it as usual.",
      ]
    }
  }

  @ViewBuilder private var actions: some View {
    switch reason {
    case .senderUnverified:
      Button("It's real, sort it") { sort() }
        .buttonStyle(.pill(.primary, fill: true))
        .accessibilityIdentifier("reason.sort")
      Button("Not mine, archive it") { archive() }
        .buttonStyle(.pill(.destructiveText, fill: true))
        .accessibilityIdentifier("reason.archive")
    case .probableCopy:
      Button("Merge") { merge() }
        .buttonStyle(.pill(.primary, fill: true))
        .accessibilityIdentifier("reason.merge")
      Button("Keep both") { keepBoth() }
        .buttonStyle(.pill(.secondary, fill: true))
        .accessibilityIdentifier("reason.keepBoth")
    case .samePurchase:
      Button("Same purchase") { merge() }
        .buttonStyle(.pill(.primary, fill: true))
        .accessibilityIdentifier("reason.same")
      Button("Keep both") { keepBoth() }
        .buttonStyle(.pill(.secondary, fill: true))
        .accessibilityIdentifier("reason.keepBoth")
    case .mayRepeat:
      Button("Same payment, archive it") { archive() }
        .buttonStyle(.pill(.primary, fill: true))
        .accessibilityIdentifier("reason.archive")
      Button("Keep both, sort it") { sort() }
        .buttonStyle(.pill(.secondary, fill: true))
        .accessibilityIdentifier("reason.sort")
    }
  }

  private var hero: some View {
    VStack(alignment: .leading, spacing: 12) {
      Circle().fill(ReviewReasonStyle.surface(reason)).frame(width: 56, height: 56)
        .overlay {
          HIconView(ReviewReasonStyle.icon(reason), size: 26, color: ReviewReasonStyle.ink(reason), strokeWidth: 1.9)
        }
        .accessibilityHidden(true)
      Text(reason.title)
        .hType(.section)
        .foregroundStyle(HColor.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
      Text(explanation)
        .hType(.subheadline)
        .foregroundStyle(HColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.top, 4)
  }

  private var whatToDo: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("What to do").hType(.overline).foregroundStyle(HColor.textSecondary)
        .accessibilityAddTraits(.isHeader)
      VStack(alignment: .leading, spacing: 4) {
        ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
          HStack(alignment: .top, spacing: 12) {
            Text("\(i + 1)")
              .hType(.footnote.weight(.semibold))
              .foregroundStyle(HColor.textPrimary)
              .frame(width: stepDisc, height: stepDisc)
              .background(HColor.surfaceSecondary, in: Circle())
            Text(step)
              .hType(.subheadline)
              .foregroundStyle(HColor.textPrimary)
              .fixedSize(horizontal: false, vertical: true)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.top, 2)
          }
          .padding(.vertical, 6)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("Step \(i + 1). \(step)")
        }
      }
    }
  }
}
