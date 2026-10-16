import HasalaDesign
import HasalaModels
import SwiftUI

/// Review · Pick a need (Paper 3SH-0), and its Want, Save and Transfer equivalents: a white
/// medium sheet floating 8 from the edges (radius 40), one detent that fits its content. The
/// bucket's categories with the suggestion ticked and marked "Suggested", the project chips,
/// "Always use X for M", and "Sort into X". Close, a swipe down or the scrim cancel: nothing
/// is sorted and the card goes back to the deck. At large text sizes it grows to large and
/// scrolls (page 14).
struct ReviewPickSheet: View {
  let model: any ReviewDeckModel
  let pick: ReviewPick
  let sort: (CategoryID, Bool, ProjectID?) -> Void

  @State private var selected: CategoryID?
  @State private var project: ProjectID?
  @State private var alwaysUse = true
  /// The content's measured height, which the one detent fits; an estimate until then.
  @State private var contentHeight: CGFloat?
  @Environment(\.dismiss) private var dismiss
  @Environment(\.dynamicTypeSize) private var typeSize

  private var options: [CategoryOption] { model.options(for: pick.choice, card: pick.card.id) }
  private var selectedName: String? { options.first { $0.id == selected }?.name }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        header
        list
        if !model.projects.isEmpty, pick.choice != .transfer { projects }
        ruleRow
        Button(selectedName.map { "Sort into \($0)" } ?? "Choose a category") {
          if let selected { sort(selected, alwaysUse, project) }
        }
        .buttonStyle(.pill(.primary, fill: true))
        .disabled(selected == nil)
        .accessibilityIdentifier("pick.sort")
      }
      .padding(.top, 8)
      .padding(.horizontal, HSpacing.insetPage)
      .padding(.bottom, 28)
      .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
    }
    .scrollBounceBehavior(.basedOnSize)
    // Paper: "Sort into" sits 28 above the sheet's own bottom edge, which floats over the
    // home indicator; the detent is exactly the content.
    .ignoresSafeArea(.container, edges: .bottom)
    .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.height(contentHeight ?? estimatedHeight)])
    .presentationDragIndicator(.visible)
    .presentationBackground(HColor.sheetSurface)
    .presentationCornerRadius(HRadius.sheet)
    .onAppear {
      selected = options.first { $0.id == pick.card.suggestion?.id }?.id ?? options.first?.id
      // A transfer is not a merchant's habit: no rule unless the person asks for one.
      alwaysUse = pick.choice != .transfer
    }
  }

  /// The sheet's height before the content is measured, from Paper's parts (header 60, rows
  /// 56 with 1 dividers, the project block 66, the rule row 44, the button 54, gaps 20, and
  /// the 8 / 28 insets), so it opens at its size instead of growing into it.
  private var estimatedHeight: CGFloat {
    let n = CGFloat(options.count)
    let projects: CGFloat = model.projects.isEmpty || pick.choice == .transfer ? 0 : 66 + 20
    return 8 + 60 + 20 + 56 * n + max(0, n - 1) + 20 + projects + 44 + 20 + 54 + 28
  }

  /// Close, "Need · which one?", and the empty 48 slot that keeps the title centred.
  private var header: some View {
    HStack {
      GlassIconButton(.close, label: "Close") { dismiss() }
        .accessibilityIdentifier("pick.close")
      Spacer(minLength: 8)
      Text("\(pick.choice.label) · which one?")
        .hType(.headline.weight(.semibold))
        .foregroundStyle(HColor.textPrimary)
        .multilineTextAlignment(.center)
        .accessibilityAddTraits(.isHeader)
      Spacer(minLength: 8)
      Color.clear.frame(width: HSpacing.glassButton, height: HSpacing.glassButton)
    }
    .padding(.top, 12)
  }

  /// The bucket's categories, straight on the sheet: disc 40, name, "Suggested", the tick.
  private var list: some View {
    VStack(spacing: 0) {
      ForEach(Array(options.enumerated()), id: \.element.id) { i, o in
        if i > 0 {
          HColor.borderSubtle.frame(height: 1).padding(.leading, 52).accessibilityHidden(true)
        }
        Button { selected = o.id } label: {
          HStack(spacing: 12) {
            CategoryDisc(hue: o.hue, icon: o.glyph.icon)
            Text(o.name).hType(.rowTitle).foregroundStyle(HColor.listRowTitle)
              .fixedSize(horizontal: false, vertical: true)
            if pick.card.suggestion?.id == o.id {
              InfoChip("Suggested", style: .suggested)
            }
            Spacer(minLength: 8)
            ZStack {
              if selected == o.id { HIconView(.check, size: 22, color: HColor.listRowCheck) }
            }
            .frame(width: 24, height: 24)
          }
          .frame(minHeight: 56)
          .contentShape(Rectangle())
        }
        .buttonStyle(HRowPressStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(pick.card.suggestion?.id == o.id ? "\(o.name), suggested" : o.name)
        .accessibilityAddTraits(selected == o.id ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("pick.\(o.id)")
      }
    }
  }

  /// "PROJECT": None or one of the open projects, as choice chips on the white sheet.
  private var projects: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Project").hType(.overline).foregroundStyle(HColor.textSecondary)
        .accessibilityAddTraits(.isHeader)
      ChipFlow(spacing: 8) {
        ChoiceChip("None", selected: project == nil, onCard: true) { project = nil }
          .accessibilityIdentifier("pick.project.none")
        ForEach(model.projects, id: \.id) { p in
          ChoiceChip(p.name, dot: .peach, selected: project == p.id, onCard: true) { project = p.id }
            .accessibilityIdentifier("pick.project.\(p.id)")
        }
      }
    }
  }

  private var ruleRow: some View {
    Toggle(isOn: $alwaysUse) {
      Text("Always use \(selectedName ?? "it") for \(pick.card.merchant)")
        .hType(.subheadline.weight(.medium))
        .foregroundStyle(HColor.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .toggleStyle(CheckboxToggleStyle())
    .accessibilityIdentifier("pick.alwaysUse")
  }
}

/// A 24 accent checkbox, radius 6, in a 40 slot (Paper "Rule checkbox"; spec 04 §14.6
/// `CheckboxSquare`). The whole row toggles it.
struct CheckboxToggleStyle: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View {
    Button { configuration.isOn.toggle() } label: {
      HStack(spacing: 12) {
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
        Spacer(minLength: 0)
      }
      .frame(minHeight: HSpacing.targetMinimum)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(configuration.isOn ? [.isSelected] : [])
  }
}
