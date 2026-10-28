import HasalaDesign
import HasalaModels
import SwiftUI

#if HASALA_MOCKS
  import HasalaMocks
#endif

/// Plan · October (Paper board 104-0): one plan for the month. Ready to assign, the split,
/// the buckets with their budget rows, and the projects. Rows push the category's month and
/// the project; Assign opens Move money.
struct PlanView: View {
  @Bindable var app: AppModel
  let model: any PlanModel

  var body: some View {
    NavigationStack(path: Bindable(app.router).plan) {
      TabScreen(app: app, title: "Plan") {
        MonthPill(month: model.snapshot.month)
      } content: {
        PlanContent(model: model)
      }
      .navigationDestination(for: PlanRoute.self) { route in
        switch route {
        case .category(let id): CategoryDetailView(app: app, category: id)
        case .project(let id): ProjectDetailView(app: app, project: id)
        case .projects: ProjectsListView(app: app)
        case .addToProject(let id): ProjectAddTransactionsView(app: app, project: id)
        }
      }
    }
  }
}

struct PlanContent: View {
  let model: any PlanModel
  @Environment(\.hMotion) private var policy
  /// The slim bars fill from empty the first time Plan appears in the process (owner rule:
  /// not on every appearance); after that they show where they are, and a changed budget
  /// moves its bar on `.fillUpdate`. `fill` scales every bar at once.
  @State private var reveal = PaceFillPhase()

  private var snap: PlanSnapshot { model.snapshot }

  var body: some View {
    VStack(alignment: .leading, spacing: HSpacing.gapScreenSection) {
      if snap.nothingPlanned {
        NothingPlannedCard(model: model)
      } else {
        ReadyToAssignCard(model: model)
        SplitSection(snap: snap)
      }
      ForEach(snap.sections) { section in
        BucketSection(section: section, month: snap.month, hidden: model.hidden, reveal: reveal.fill,
                      nothingPlanned: snap.nothingPlanned) {
          model.open($0)
        }
      }
      ProjectsSection(model: model, reveal: reveal.fill)
    }
    .paceFillSequence($reveal, target: 1, policy: policy, once: .perProcess("plan.bars"))
  }
}

// MARK: - Ready to assign

/// "Brief card · Ready to assign": the mint poster with the wallet plate, the overline, the
/// figure and "Income 25,000 · planned 24,000"; under it Assign (and, in Debug, Auto-assign
/// with its helper). Assign opens Move money with no category chosen yet.
private struct ReadyToAssignCard: View {
  let model: any PlanModel
  @Environment(\.dynamicTypeSize) private var typeSize

  private var snap: PlanSnapshot { model.snapshot }
  private var overPlanned: Bool { snap.readyToAssign.isNegative }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      poster
      actions
    }
    .background(HColor.surfacePrimary)
    .clipShape(RoundedRectangle(cornerRadius: HRadius.brief, style: .continuous))
    .hElevation(.nearFar)
    .padding(.horizontal, HSpacing.insetPage)
  }

  private var poster: some View {
    VStack(alignment: .leading, spacing: 14) {
      // The plate beside the overline; at the accessibility sizes above it, so the overline
      // has the card's width to wrap in. One layout either way, so the views keep their
      // identity while the text size changes.
      let header = typeSize.isAccessibilitySize
        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
        : AnyLayout(HStackLayout(spacing: 8))
      header {
        Circle().fill(HColor.posterGlyph).frame(width: 32, height: 32)
          .overlay { PlanGlyph(kind: .wallet, size: 18, color: ink, stroke: 2) }
        Text(overPlanned ? "Over-planned" : "Ready to assign").hType(.overline).foregroundStyle(ink)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityAddTraits(.isHeader)
      }
      VStack(alignment: .leading, spacing: 2) {
        let rta = snap.readyToAssign
        MoneyText(rta, figure: .large, unit: .unit, hidden: model.hidden, hiddenGlyphs: 4,
                  color: overPlanned ? HColor.statusWarningForeground : HColor.textPrimary,
                  unitGap: 6, sign: overPlanned ? .debt : .none)
          .accessibilityIdentifier("plan.readyToAssign")
        if overPlanned {
          PhraseText(MoneyPhrase([.text("Planned "), .amount(.aed(rta.minor.negated), .compact, hidden: 3),
                                  .text(" more than income")]), hidden: model.hidden)
            .hType(.subheadline.weight(.semibold)).foregroundStyle(HColor.statusWarningForeground)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("plan.overPlanned")
        }
        PhraseText(snap.incomeLine, hidden: model.hidden).hType(.subheadline)
          .foregroundStyle(overPlanned ? HColor.textSecondary : HColor.textOnHueSecondary)
      }
    }
    .padding(EdgeInsets(top: 14, leading: 16, bottom: 16, trailing: 16))
    .frame(maxWidth: .infinity, alignment: .leading)
    .background {
      if overPlanned { HColor.statusWarningSurface } else { Hue.mint.perceptualGradient }
    }
  }

  private var ink: Color { overPlanned ? HColor.statusWarningForeground : Hue.mint.ink }

  private var actions: some View {
    VStack(alignment: .leading, spacing: 12) {
      // Side by side; stacked at the accessibility text sizes (spec 04 §17).
      let layout = typeSize.isAccessibilitySize
        ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
      layout {
        // Each pill takes the height its label needs (two lines at the largest sizes).
        Button(overPlanned ? "Move money" : "Assign") { model.moveMoney(to: nil) }
          .buttonStyle(.pill(.primary, size: .medium, fill: true))
          .fixedSize(horizontal: false, vertical: true)
          .disabled(snap.readyToAssign.minor == 0)
          .accessibilityIdentifier("plan.assign")
        // TODO(03a §6.11, spec 04 §16.2 P2): Auto-assign; a Release build offers Assign alone.
        if BuildSurface.showsUnfinished {
          Button("Auto-assign") { model.autoAssign() }
            .buttonStyle(.pill(.secondary, size: .medium, fill: typeSize.isAccessibilitySize))
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      if BuildSurface.showsUnfinished {
        Text("Auto-assign funds targets first, then follows your \(snap.splitName) split.")
          .hType(.footnote).foregroundStyle(HColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(16)
  }
}

// MARK: - Nothing planned

private struct NothingPlannedCard: View {
  let model: any PlanModel
  @Environment(\.dynamicTypeSize) private var typeSize

  private var snap: PlanSnapshot { model.snapshot }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Nothing planned for \(snap.month.name) yet").hType(.headline).foregroundStyle(HColor.textPrimary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityAddTraits(.isHeader)
          .accessibilityIdentifier("plan.nothingPlanned")
        Text(message).hType(.subheadline).foregroundStyle(HColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      let layout = typeSize.isAccessibilitySize
        ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
      layout {
        Button("Assign") { model.moveMoney(to: nil) }
          .buttonStyle(.pill(.primary, size: .medium, fill: true))
          .fixedSize(horizontal: false, vertical: true)
          .disabled(snap.readyToAssign.minor <= 0)
          .accessibilityIdentifier("plan.assign")
        if !snap.lastMonthBudgets.isEmpty {
          Button("Copy last month") { model.copyLastMonth() }
            .buttonStyle(.pill(.secondary, size: .medium, fill: true))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("plan.copyLastMonth")
        }
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(HColor.surfacePrimary)
    .clipShape(RoundedRectangle(cornerRadius: HRadius.brief, style: .continuous))
    .hElevation(.nearFar)
    .padding(.horizontal, HSpacing.insetPage)
  }

  private var message: String {
    if !snap.lastMonthBudgets.isEmpty {
      return "Give each category a budget, or start from \(snap.month.previous.name)'s plan."
    }
    if snap.readyToAssign.minor > 0 {
      return "Assign your income to your categories, or tap a category to set its budget."
    }
    return "Tap a category to set its budget, and Hasala keeps track of your month against it."
  }
}

// MARK: - Your split

/// "Your split": the three buckets' share of the plan as one 12 tall bar in their dot
/// colours (2 apart, outer corners 6, inner 2), with the bucket and its percent under each
/// part. "Started from 50 / 30 / 20" on the right of the overline.
private struct SplitSection: View {
  let snap: PlanSnapshot
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ReflowingRow(alignment: .firstTextBaseline) {
        Text("Your split").hType(.overline).foregroundStyle(HColor.textSecondary).accessibilityAddTraits(.isHeader)
      } trailing: {
        Text(snap.startedFrom).hType(.footnote).foregroundStyle(HColor.textSecondary)
      }
      .padding(.horizontal, 4)
      GeometryReader { geo in
        let widths = Self.partWidths(geo.size.width, fractions: fractions, gap: 2)
        HStack(spacing: 2) {
          ForEach(Array(snap.split.enumerated()), id: \.element.id) { i, share in
            UnevenRoundedRectangle(
              topLeadingRadius: i == 0 ? 6 : 2, bottomLeadingRadius: i == 0 ? 6 : 2,
              bottomTrailingRadius: i == snap.split.count - 1 ? 6 : 2,
              topTrailingRadius: i == snap.split.count - 1 ? 6 : 2, style: .continuous)
              .fill(share.bucket.splitColor)
              .frame(width: widths[i])
          }
        }
      }
      .frame(height: 12)
      .accessibilityHidden(true)
      labels
    }
    .padding(.horizontal, HSpacing.insetPage)
  }

  private var fractions: [Double] { snap.split.map(\.share.fraction) }

  static func partWidths(_ total: CGFloat, fractions: [Double], gap: CGFloat, floor: CGFloat = 12) -> [CGFloat] {
    let n = fractions.count
    guard n > 0 else { return [] }
    let room = max(0, total - gap * CGFloat(n - 1))
    guard room > floor * CGFloat(n) else { return Array(repeating: room / CGFloat(n), count: n) }
    var floored = Set<Int>()
    while true {
      let free = room - floor * CGFloat(floored.count)
      let open = fractions.indices.filter { !floored.contains($0) }
      let weight = open.map { fractions[$0] }.reduce(0, +)
      let widths = fractions.indices.map { i -> CGFloat in
        if floored.contains(i) { return floor }
        return weight > 0 ? free * fractions[i] / weight : free / CGFloat(open.count)
      }
      let more = open.filter { widths[$0] < floor }
      if more.isEmpty { return widths }
      floored.formUnion(more)
    }
  }

  private var labels: some View {
    SplitLegendLayout(fractions: fractions, gap: 2,
                      stacked: typeSize.isAccessibilitySize || snap.split.contains { $0.share.value < 100 }) {
      ForEach(snap.split) { share in label(share) }
    }
  }

  private func label(_ share: SplitShare) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(share.bucket.title).hType(.footnote).foregroundStyle(HColor.textSecondary)
      Text(share.label).hFigure(.stat).foregroundStyle(HColor.textPrimary)
    }
    .fixedSize()
    // Read as text: an element with no trait reads to the audit as a control too small to tap.
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(share.bucket.title), \(share.label)")
    .accessibilityAddTraits(.isStaticText)
  }
}

private struct SplitLegendLayout: Layout {
  let fractions: [Double]
  let gap: CGFloat
  let stacked: Bool
  var lineSpacing: CGFloat = 6

  private func underParts(_ subviews: Subviews, width: CGFloat) -> [CGFloat]? {
    guard !stacked, subviews.count == fractions.count else { return nil }
    let widths = SplitSection.partWidths(width, fractions: fractions, gap: gap)
    for (i, view) in subviews.enumerated() where view.sizeThatFits(.unspecified).width > widths[i] {
      return nil
    }
    return widths
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
    let width = proposal.width ?? sizes.map(\.width).reduce(0, +)
    if underParts(subviews, width: width) != nil {
      return CGSize(width: width, height: sizes.map(\.height).max() ?? 0)
    }
    let height = sizes.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, sizes.count - 1))
    return CGSize(width: width, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    if let widths = underParts(subviews, width: bounds.width) {
      var x = bounds.minX
      for (i, view) in subviews.enumerated() {
        view.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading, proposal: .unspecified)
        x += widths[i] + gap
      }
      return
    }
    var y = bounds.minY
    for view in subviews {
      let height = view.sizeThatFits(.unspecified).height
      view.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading, proposal: .unspecified)
      y += height + lineSpacing
    }
  }
}

// MARK: - Buckets

/// One bucket: the dot, its name in Title 2, "3,309.20 left of 12,350" (Savings: "✓ Done for
/// October") on the same baseline, then its rows in a white card with dividers inset 68.
private struct BucketSection: View {
  let section: PlanSection
  let month: YearMonth
  let hidden: Bool
  let reveal: Double
  var nothingPlanned = false
  let open: (CategoryID) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ReflowingRow(alignment: .firstTextBaseline) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Circle().fill(section.bucket.splitColor).frame(width: 10, height: 10)
          Text(section.bucket.title).hType(.section).foregroundStyle(HColor.textPrimary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
      } trailing: {
        summary
      }
      PlanListCard {
        ForEach(section.rows) { row in
          Button { open(row.id) } label: {
            BudgetRowView(row: row, hidden: hidden, reveal: reveal, unplanned: nothingPlanned && row.isUntouched)
          }
            .buttonStyle(HRowPressStyle())
            .accessibilityIdentifier("plan.row.\(row.id)")
        }
      }
    }
    .padding(.horizontal, HSpacing.insetPage)
  }

  @ViewBuilder private var summary: some View {
    if nothingPlanned && section.budget.isZero && section.left.isZero {
      EmptyView()
    } else if section.done {
      DoneMark("Done for \(month.name)")
    } else {
      // "3,309.20 left of 12,350": what is left first, then the bucket's plan, whole.
      HStack(alignment: .firstTextBaseline, spacing: 4) {
        MoneyText(section.left, figure: .compact, hidden: hidden, hiddenGlyphs: 3,
                  color: section.left.isNegative ? HColor.statusErrorForeground : HColor.textPrimary)
        Text(section.left.isNegative ? "over" : "left of").hType(.subheadline).foregroundStyle(HColor.textSecondary)
        if !section.left.isNegative {
          MoneyText(section.budget, figure: HFigure.compact.weight(.medium), style: .compact, hidden: hidden,
                    hiddenGlyphs: 3, color: HColor.textSecondary)
        }
      }
      .accessibilityElement(children: .combine)
      .accessibilityAddTraits(.isStaticText)
    }
  }
}

/// A budget row (Paper "BudgetRow", page 16 §05): the 40 disc, the name with what is left on
/// the right ("1,387.60 left", "✓ Done", "77%"), a line of facts, and the slim 6 bar in the
/// verdict's colour, with no today tick. At least 72 tall; one button that reads as one
/// sentence ("Groceries, AED 1,387.60 left. 812.40 of 2,200, Over pace."). At the
/// accessibility sizes the figure moves under the name and the facts wrap.
struct BudgetRowView: View {
  let row: PlanRowModel
  let hidden: Bool
  /// How much of its fill the bar shows (Plan's first reveal); 1 at rest.
  var reveal: Double = 1
  var unplanned = false
  @Environment(\.dynamicTypeSize) private var typeSize

  private var parts: [PlanDetailPart] { unplanned ? [.text("No budget yet")] : row.detail }

  var body: some View {
    let layout = typeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
      : AnyLayout(HStackLayout(alignment: .center, spacing: HSpacing.listRowGap))
    layout {
      CategoryDisc(hue: row.hue, glyph: row.glyph)
      VStack(alignment: .leading, spacing: 2) {
        if typeSize.isAccessibilitySize {
          name
          trailing
        } else {
          HStack(alignment: row.trailing == .done ? .center : .firstTextBaseline, spacing: 8) {
            name
            Spacer(minLength: 0)
            trailing
          }
        }
        PlanFactsLine(parts: parts, hidden: hidden)
        SlimProgressBar(Permille(Int(Double(min(1000, row.progress.value)) * reveal)), fill: row.verdict.fill)
          .padding(.top, 6)
          .hAnimation(.fillUpdate, value: row.progress)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, HSpacing.listRowInsetInline)
    .padding(.vertical, 9)
    .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
    .contentShape(Rectangle())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(spoken)
  }

  private var name: some View {
    Text(row.name).hType(.rowTitle).foregroundStyle(HColor.listRowTitle).singleLineAtDefaultTextSize()
  }

  @ViewBuilder private var trailing: some View {
    switch row.trailing {
    case .left where unplanned:
      EmptyView()
    case .left(let m):
      HStack(alignment: .firstTextBaseline, spacing: 4) {
        MoneyText(.aed(abs(m.minor)), figure: .row, hidden: hidden, hiddenGlyphs: 3,
                  color: m.isNegative ? HColor.statusErrorForeground : HColor.textPrimary)
        Text(m.isNegative ? "over" : "left").hType(.footnote).foregroundStyle(HColor.textSecondary)
      }
      .fixedSize()
    case .done:
      DoneMark("Done")
    case .percent(let p):
      Text("\(p)%").hFigure(.row).foregroundStyle(HColor.textPrimary)
    }
  }

  private var spoken: String {
    let figure: String
    switch row.trailing {
    case .left where unplanned:
      return "\(row.name), No budget yet."
    case .left(let m):
      let amount = hidden ? "Amount hidden" : "\(m.currency) \(MoneyFormat.string(m.minor))"
      figure = "\(amount) \(m.isNegative ? "over" : "left")"
    case .done: figure = "Done"
    case .percent(let p): figure = "\(p) percent"
    }
    let facts = BillDetailParts.spoken(row.detail, hidden: hidden)
    return "\(row.name), \(figure). \(facts)."
  }
}

extension PlanRowModel {
  var isUntouched: Bool { budget.isZero && spent.isZero }
}

// MARK: - Projects

private struct ProjectsSection: View {
  let model: any PlanModel
  let reveal: Double

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ReflowingRow(alignment: .firstTextBaseline) {
        Text("Projects").hType(.section).foregroundStyle(HColor.textPrimary).accessibilityAddTraits(.isHeader)
      } trailing: {
        Button { model.newProject() } label: {
          Text("New project")
            .hType(.subheadline.weight(.medium))
            .foregroundStyle(HColor.textLink)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, -12)
        .accessibilityIdentifier("plan.newProject")
      }
      ForEach(model.snapshot.projects) { p in
        Button { model.open(project: p.id) } label: {
          ProjectCard(project: p, hidden: model.hidden, reveal: reveal)
        }
        .buttonStyle(HPressStyle(in: RoundedRectangle(cornerRadius: HRadius.brief, style: .continuous)))
        .accessibilityIdentifier("plan.project.\(p.id)")
      }
      if model.snapshot.projects.isEmpty {
        Text("Set money aside for one thing, like a trip or a move. It stays out of your monthly plan.")
          .hType(.subheadline).foregroundStyle(HColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Button { model.openProjects() } label: {
        HStack(spacing: 6) {
          Text("All projects").hType(.subheadline.weight(.medium)).foregroundStyle(HColor.textLink)
          HIconView(.chevronRight, size: HSpacing.iconSmall, color: HColor.textLink)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("plan.allProjects")
    }
    .padding(.horizontal, HSpacing.insetPage)
  }
}

struct ProjectCard: View {
  let project: PlanProjectModel
  let hidden: Bool
  let reveal: Double

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 12) {
        GlyphPlate(icon: project.glyph.icon, hue: .peach, size: 40)
        VStack(alignment: .leading, spacing: 2) {
          Text(project.name).hType(.headline).foregroundStyle(HColor.textPrimary)
          if !project.dates.isEmpty {
            Text(project.dates).hType(.footnote).foregroundStyle(HColor.textOnHueSecondary)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        HIconView(.chevronRight, size: HSpacing.iconSmall, color: Hue.peach.ink)
      }
      SideBySideOrStacked(spacing: 6, spreads: false) {
        MoneyText(figure, figure: HFigure.medium.weight(.bold), hidden: hidden, hiddenGlyphs: 4,
                  color: figureColor, sign: refunded ? .income : .none)
          .fixedSize()
        PhraseText(caption, hidden: hidden)
          .hType(.subheadline).foregroundStyle(HColor.textOnHueSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if project.budget != nil {
        SlimProgressBar(Permille(Int(Double(min(1000, project.progress.value)) * reveal)), fill: HColor.paceFill,
                        track: HColor.progressTrackOnHue, height: 8)
      }
      if !project.pending.isZero {
        PhraseText(MoneyPhrase([.amount(project.pending, .compact, hidden: 3), .text(" waiting for review")]),
                   hidden: hidden)
          .hType(.footnote).foregroundStyle(HColor.textOnHueSecondary)
      }
      if let line = project.mark?.line {
        Text(line).hType(.footnote).foregroundStyle(HColor.textOnHueSecondary)
      }
      if !project.countInPlan {
        HStack(alignment: .top, spacing: 6) {
          HIconView(.info, size: 14, color: HColor.textOnHueSecondary)
            .padding(.top, 2)
          Text("Not counted in your monthly plan").hType(.footnote).foregroundStyle(HColor.textOnHueSecondary)
        }
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Hue.peach.perceptualGradient, in: RoundedRectangle(cornerRadius: HRadius.brief, style: .continuous))
    .contentShape(RoundedRectangle(cornerRadius: HRadius.brief, style: .continuous))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(spoken)
  }

  private var over: Bool { project.left?.isNegative == true }
  private var refunded: Bool { project.left == nil && project.spent.isNegative }

  private var figure: Money {
    guard let left = project.left else { return .aed(abs(project.spent.minor)) }
    return .aed(abs(left.minor))
  }

  private var figureColor: Color {
    if over { return HColor.statusErrorForeground }
    return refunded ? HColor.moneyIn : HColor.textPrimary
  }

  private var caption: MoneyPhrase {
    guard let budget = project.budget else { return refunded ? "refunded · no budget" : "spent · no budget" }
    return MoneyPhrase([.text(over ? "over " : "left of "), .amount(budget, .compact, hidden: 3)])
  }

  private var spoken: String {
    let amount = hidden ? "Amount hidden" : (refunded ? "plus " : "") + "AED \(MoneyFormat.string(figure.minor))"
    let when = [project.range, project.when].compactMap { $0 }.joined(separator: ", ")
    var out = project.name + (when.isEmpty ? "." : ", \(when).")
    out += " \(amount) \(caption.spoken(hidden: hidden))."
    if !project.pending.isZero {
      out += " " + MoneyPhrase([.amount(project.pending, .compact), .text(" waiting for review.")]).spoken(hidden: hidden)
    }
    if let line = project.mark?.line { out += " \(line)." }
    return out + (project.countInPlan ? "" : " Not counted in your monthly plan.")
  }
}

#if HASALA_MOCKS
  #Preview("Plan · October") {
    let app = AppModel(store: InMemoryLedger())
    PlanView(app: app, model: PlanViewModel(app: app))
  }
#endif
