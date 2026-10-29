import HasalaDesign
import HasalaModels
import SwiftUI
import UIKit

/// Profile › Categories and rules (Paper "Profile · Categories and rules" 68S-0): the rules
/// Hasala learned, most used first, each with a switch that pauses it at once (its
/// transactions go back to review). No Save: a switch saves the moment it flips.
struct RulesPage: View {
  enum Segment: Hashable { case categories, rules }

  @Bindable var app: AppModel
  let model: any ProfileModel
  @State private var segment: Segment

  init(app: AppModel, model: any ProfileModel, startOn segment: Segment = .rules) {
    self.app = app
    self.model = model
    _segment = State(initialValue: segment)
  }

  private var unfinished: Bool { BuildSurface.showsUnfinished }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        HSegmentedControl([Segment.categories, .rules], selection: $segment) { $0 == .categories ? "Categories" : "Rules" }
          .accessibilityIdentifier("rules.segment")
        switch segment {
        case .rules: rules
        case .categories: CategoriesList(app: app)
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
      Text("Hasala writes a rule when you sort with Always use it on. Pause one to send its transactions back to review.")
        .hType(.subheadline)
        .foregroundStyle(HColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 4)
      let rules = model.rules
      if rules.isEmpty {
        EmptyNote(systemImage: "list.bullet", message: "No rules yet. Turn on Always use it when you sort.")
          .accessibilityIdentifier("rules.empty")
      } else {
        VStack(alignment: .leading, spacing: 8) {
          OverlineHeader("Most used")
          if rules.count > Self.lazyFrom {
            LazyVStack(spacing: 0) { ruleRows(rules) }
              .frame(maxWidth: .infinity)
              .background(HColor.listRowSurface)
              .clipShape(RoundedRectangle(cornerRadius: HRadius.listGroup, style: .continuous))
          } else {
            HListCard { ruleRows(rules) }
          }
        }
      }
    }
  }

  private static let lazyFrom = 40

  private func ruleRows(_ rules: [RuleRowModel]) -> some View {
    ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
      if index > 0 { HDivider(inset: .disc68) }
      RuleRow(rule: rule, enabled: Binding(get: { rule.enabled }, set: { model.setRule(rule.id, enabled: $0) }))
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
  @ScaledMetric(relativeTo: HType.rowTitle.textStyle) private var titleSize = HType.rowTitle.size
  @Environment(\.legibilityWeight) private var legibilityWeight
  @State private var width = CGFloat.infinity

  var body: some View {
    Toggle(isOn: $enabled) {
      let layout = typeSize.isAccessibilitySize
        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
        : AnyLayout(HStackLayout(spacing: HSpacing.listRowGap))
      layout {
        HuePlate(hue: rule.hue, icon: rule.glyph.icon)
        VStack(alignment: .leading, spacing: 2) {
          title
          MatchLine(rule: rule)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
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
    let pattern = Text(patternLine).hType(.rowTitle).foregroundStyle(HColor.listRowTitle)
      .lineLimit(2)
    if rule.learnedToday {
      let chip = StatusPillView(StatusPill("Learned today", tone: .accent, showsDot: false), size: .s22,
                                surface: .tinted)
      let stacked = VStack(alignment: .leading, spacing: 4) { pattern; chip }
      // Paper's title row: the chip 8 after the pattern, hugging it; under it when the two
      // don't fit, and always at the accessibility sizes. Never wider than the row.
      if typeSize.isAccessibilitySize {
        stacked
      } else {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 8) { pattern; chip }
          stacked
        }
      }
    } else {
      pattern
    }
  }

  private var patternLine: String {
    let count = rule.patterns.count
    guard count > 1, width.isFinite, width > 0 else { return rule.pattern }
    let type = HType.rowTitle
    let weight = legibilityWeight == .bold ? type.weight.bolder : type.weight
    let font = UIFont(name: weight.interFace, size: titleSize) ?? .systemFont(ofSize: titleSize)
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .kern: type.resolvedTracking * titleSize / type.size]
    let bounds = CGSize(width: width, height: .greatestFiniteMagnitude)
    func height(_ s: String) -> CGFloat {
      (s as NSString).boundingRect(with: bounds, options: .usesLineFragmentOrigin, attributes: attributes, context: nil)
        .height.rounded(.up)
    }
    let limit = height("A\nA")
    for shown in stride(from: count, to: 1, by: -1) where height(rule.patternLine(showing: shown)) <= limit {
      return rule.patternLine(showing: shown)
    }
    return rule.patternLine(showing: 1)
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

/// A rule's match line: "Contains · Groceries · 41 matches" on one line when it fits, else
/// how it matches over its count ("Exact match · Subscriptions⏎12 matches"), where Paper
/// breaks it. One text whose words change, never a second one in its place, so it keeps
/// growing with the text size (the accessibility audit follows the text node); whether the
/// line fits is measured in the face and size it is drawn in.
private struct MatchLine: View {
  let rule: RuleRowModel
  @ScaledMetric(relativeTo: HType.footnote.textStyle) private var size = HType.footnote.size
  @Environment(\.legibilityWeight) private var legibilityWeight
  @State private var width = CGFloat.infinity

  var body: some View {
    Text(fits ? rule.detail : "\(rule.match)\n\(rule.matchesLabel)")
      .hType(.footnote)
      .foregroundStyle(HColor.listRowSupporting)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
  }

  private var fits: Bool {
    let type = HType.footnote
    let weight = legibilityWeight == .bold ? type.weight.bolder : type.weight
    let font = UIFont(name: weight.interFace, size: size) ?? .systemFont(ofSize: size)
    let tracking = type.resolvedTracking * size / type.size
    let measured = (rule.detail as NSString).size(withAttributes: [.font: font, .kern: tracking]).width
    return measured.rounded(.up) <= width
  }
}
