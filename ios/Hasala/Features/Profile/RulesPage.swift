import HasalaDesign
import HasalaModels
import SwiftUI

/// Profile › Categories and rules (Paper "Profile · Categories and rules" 68S-0): the rules
/// Hasala learned, most used first, each with a switch that pauses it at once (its
/// transactions go back to review). No Save: a switch saves the moment it flips.
///
/// The Categories view, "See all N rules" and "Add a rule" are not drawn yet: a Release build
/// shows the rules alone, without the segmented control that would offer an empty view.
struct RulesPage: View {
  enum Segment: Hashable { case categories, rules }

  @Bindable var app: AppModel
  let model: any ProfileModel
  @State private var segment: Segment = .rules

  private var unfinished: Bool { BuildSurface.showsUnfinished }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        // TODO(spec 04 §16.2 P5): the Categories view; until it exists the control is Debug only.
        if unfinished {
          HSegmentedControl([Segment.categories, .rules], selection: $segment) { $0 == .categories ? "Categories" : "Rules" }
            .accessibilityIdentifier("rules.segment")
        }
        switch segment {
        case .rules: rules
        case .categories:
          PlaceholderCard(systemImage: "tag", title: "Categories",
                          message: "Your 18 categories and their buckets. This view comes in a later build.")
        }
        if unfinished && segment == .rules {
          // TODO(spec 04 §16.2 P6): "Add a rule".
          Button { app.say("Adding a rule comes in a later build", icon: .rule) } label: {
            HStack(spacing: 6) {
              HIconView(.add, size: HSpacing.iconInline, color: HColor.textLink, strokeWidth: 2.4)
              Text("Add a rule").hType(.button).foregroundStyle(HColor.textLink)
            }
            .frame(maxWidth: .infinity, minHeight: HSpacing.targetMinimum)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("rules.add")
        }
      }
      .padding(.horizontal, HSpacing.sheetPadding)
      .padding(.top, 8)
      .padding(.bottom, 48)
    }
    .scrollEdgeEffectStyle(.soft, for: .bottom)
    .background(HColor.sheetSurfaceLarge)
    .navigationTitle("Categories and rules")
    .navigationBarTitleDisplayMode(.inline)
  }

  private var rules: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Hasala writes a rule when you sort a new merchant. Pause one to send its transactions back to review.")
        .hType(.subheadline)
        .foregroundStyle(HColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 4)
      VStack(alignment: .leading, spacing: 8) {
        OverlineHeader("Most used")
        HListCard {
          ForEach(Array(model.rules.enumerated()), id: \.element.id) { index, rule in
            if index > 0 { HDivider(inset: .disc68) }
            RuleRow(rule: rule, enabled: Binding(get: { rule.enabled }, set: { model.setRule(rule.id, enabled: $0) }))
          }
          if unfinished {
            HDivider(inset: .text16)
            // TODO(spec 04 §16.2 P6): every rule, with its detail.
            Button { app.say("Every rule comes in a later build", icon: .rule) } label: {
              HStack(spacing: 8) {
                Text("See all \(model.rules.count) rules").hType(.callout.weight(.medium))
                  .foregroundStyle(HColor.listRowTitle)
                  .frame(maxWidth: .infinity, alignment: .leading)
                HIconView(.chevronRight, size: HSpacing.iconSmall, color: HColor.listRowChevron)
              }
              .padding(.horizontal, HSpacing.listRowInsetInline)
              .frame(minHeight: HSpacing.listRowMinHeight)
              .contentShape(Rectangle())
            }
            .buttonStyle(HRowPressStyle())
            .accessibilityIdentifier("rules.seeAll")
          }
        }
      }
    }
  }
}

/// One rule (68S-0 · List card · Rules): the category's disc, the pattern in curly quotes
/// (with "Learned today" when it is new), how it matches over its count, and the switch. The
/// match line breaks before the count when it doesn't fit, as Paper breaks it. The row is one
/// stop that flips the switch.
private struct RuleRow: View {
  let rule: RuleRowModel
  @Binding var enabled: Bool
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    Toggle(isOn: $enabled) {
      let layout = typeSize.isAccessibilitySize
        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
        : AnyLayout(HStackLayout(spacing: HSpacing.listRowGap))
      layout {
        HuePlate(hue: rule.hue, icon: rule.glyph.icon)
        VStack(alignment: .leading, spacing: 2) {
          title
          ViewThatFits(in: .horizontal) {
            Text(rule.detail).lineLimit(1)
            Text("\(rule.match)\n\(rule.matchesLabel)")
          }
          .hType(.footnote)
          .foregroundStyle(HColor.listRowSupporting)
          .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .tint(HColor.controlSwitchTrackOn)
    .padding(.horizontal, HSpacing.listRowInsetInline)
    .padding(.vertical, HSpacing.listRowInsetBlock)
    .frame(minHeight: HSpacing.listRowMinHeightTwoLine)
    .accessibilityLabel(spoken)
    .accessibilityIdentifier("rule.\(rule.id)")
  }

  @ViewBuilder private var title: some View {
    let pattern = Text(rule.pattern).hType(.rowTitle).foregroundStyle(HColor.listRowTitle)
    if rule.learnedToday {
      ReflowingRow(spacing: 8) {
        pattern
      } trailing: {
        StatusPillView(StatusPill("Learned today", tone: .accent, showsDot: false), size: .s22, surface: .tinted)
      }
      .fixedSize(horizontal: !typeSize.isAccessibilitySize, vertical: false)
    } else {
      pattern
    }
  }

  /// "carrefour, learned today, Contains · Groceries · 41 matches": the quotes are drawn,
  /// not read.
  private var spoken: String {
    let pattern = rule.pattern.replacingOccurrences(of: "\u{201C}", with: "")
      .replacingOccurrences(of: "\u{201D}", with: "")
    return [pattern, rule.learnedToday ? "learned today" : nil, rule.detail].compactMap { $0 }
      .joined(separator: ", ")
  }
}
