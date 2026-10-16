import HasalaDesign
import HasalaModels
import SwiftUI

/// A project (Paper "Plan · Japan trip (project)", 5JD-0), pushed from Plan and from Your
/// profile: the peach wash and hero (the flag disc, what is left of the money set aside, its
/// progress with no tick, the dates), whether it counts in the monthly plan, By category and
/// Transactions. Money set aside outside the plan, so nothing here paces.
///
/// "Count in monthly plan" is a status: no edit can change it yet, so a Release build states
/// it ("Off") and Debug draws the switch disabled. "Add transactions" and "Mark complete" are
/// Debug only for the same reason (plan D.2).
struct ProjectDetailView: View {
  @Bindable var app: AppModel
  let project: ProjectID
  @State private var model: ProjectDetailViewModel

  init(app: AppModel, project: ProjectID) {
    self.app = app
    self.project = project
    _model = State(initialValue: ProjectDetailViewModel(app: app, project: project))
  }

  /// Pushed on Plan's stack, the screen hosts its toast; inside Your profile the sheet does.
  private var inPlan: Bool { app.router.plan.contains(.project(project)) }

  var body: some View {
    if let d = model.detail {
      PlanDetailScreen(app: app, title: d.name, wash: .hue(.peach), hostsToast: inPlan) {
        ProjectHero(detail: d, hidden: model.hidden)
        planSetting(d)
        if !d.categories.isEmpty { byCategory(d) }
        if !d.transactions.isEmpty { transactions(d) }
        if BuildSurface.showsUnfinished { actions }
      }
    } else {
      PlanDetailScreen(app: app, title: "Project", wash: .hue(.peach), hostsToast: inPlan) {
        EmptyStateCard(icon: .project, tone: .neutral, title: "This project is gone",
                       message: "It was completed or removed. Plan shows the projects you have now.")
          .padding(.horizontal, HSpacing.insetPage)
      }
    }
  }

  // MARK: Count in monthly plan

  private func planSetting(_ d: ProjectDetail) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Group {
        if BuildSurface.showsUnfinished {
          // TODO(spec 12 §10): turning it on needs a project edit (plan D.2). The whole row
          // is the switch, as drawn, and it is the one element ("Count in monthly plan, Off").
          Toggle(isOn: .constant(d.countInPlan)) {
            Text("Count in monthly plan").hType(.rowTitle).foregroundStyle(HColor.listRowTitle)
              .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
          }
          .tint(HColor.controlSwitchTrackOn)
          .disabled(true)
        } else {
          // Nothing can change it yet, so Release states it.
          HStack(spacing: 14) {
            Text("Count in monthly plan").hType(.rowTitle).foregroundStyle(HColor.listRowTitle)
              .frame(maxWidth: .infinity, alignment: .leading)
            Text(d.countInPlan ? "On" : "Off").hType(.subheadline).foregroundStyle(HColor.textSecondary)
          }
          .frame(minHeight: 52)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("Count in monthly plan")
          .accessibilityValue(d.countInPlan ? "On" : "Off")
          .accessibilityAddTraits(.isStaticText)
        }
      }
      // 56 tall with 4 above (Paper "Row · Count in monthly plan").
      .padding(.horizontal, 16)
      .padding(.top, 4)
      .accessibilityIdentifier("project.countInPlan")
      PhraseText(d.explainer, hidden: model.hidden).hType(.footnote).foregroundStyle(HColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .accessibilityIdentifier("project.explainer")
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .listCard()
    .padding(.horizontal, HSpacing.insetPage)
  }

  // MARK: By category

  /// "By category ……… 4,860.00 spent": a row per category the money went to.
  private func byCategory(_ d: ProjectDetail) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      ReflowingRow(alignment: .firstTextBaseline) {
        Text("By category").hType(.section).foregroundStyle(HColor.textPrimary).accessibilityAddTraits(.isHeader)
      } trailing: {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
          MoneyText(d.spent, figure: .compact, hidden: model.hidden, hiddenGlyphs: 3, color: HColor.textPrimary)
          Text("spent").hType(.subheadline).foregroundStyle(HColor.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityIdentifier("project.spent")
      }
      PlanListCard {
        ForEach(d.categories) { c in
          HListRow(leading: .disc(c.hue, c.glyph.icon), title: c.name, supporting: .text(c.detail),
                   trailing: .amount(c.spent), hidden: model.hidden)
            .accessibilityIdentifier("project.category.\(c.id)")
        }
      }
    }
    .padding(.horizontal, HSpacing.insetPage)
  }

  // MARK: Transactions

  /// "Transactions 2": the project's payments in the order they were made; a row opens the
  /// transaction sheet.
  private func transactions(_ d: ProjectDetail) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      CountedTitle(title: "Transactions", count: d.transactions.count)
      PlanListCard {
        ForEach(d.transactions) { row in
          Button { model.open(row.id) } label: { TransactionRow(row, hidden: model.hidden) }
            .buttonStyle(HRowPressStyle())
            .accessibilityIdentifier("project.txn.\(row.id)")
        }
      }
    }
    .padding(.horizontal, HSpacing.insetPage)
  }

  // MARK: Actions (Debug only)

  private var actions: some View {
    VStack(spacing: 8) {
      Button("Add transactions") { model.addTransactions() }
        .buttonStyle(.pill(.onGrouped, fill: true, leadingIcon: .add))
        .accessibilityIdentifier("project.addTransactions")
      Button("Mark complete") { model.markComplete() }
        .buttonStyle(.pill(.tertiary, fill: true))
        .accessibilityIdentifier("project.markComplete")
    }
    .padding(.horizontal, HSpacing.insetPage)
  }
}

/// "Hero · Japan trip": the 56 flag disc, "AED 7,140.00" over "left of 12,000", the 8 bar
/// (blue, no tick) and the dates: "📅 14–28 Dec · 65 days to go". One VoiceOver element.
private struct ProjectHero: View {
  let detail: ProjectDetail
  let hidden: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 14) {
        CategoryDisc(hue: .peach, icon: .project, size: .s56)
          .hElevation(.near)
        VStack(alignment: .leading, spacing: 4) {
          MoneyText(.aed(abs(detail.left.minor)), figure: .hero, unit: .unit, hidden: hidden, hiddenGlyphs: 6,
                    color: detail.left.isNegative ? HColor.statusErrorForeground : HColor.textPrimary, unitGap: 6)
          PhraseText(caption, hidden: hidden).hType(.body).foregroundStyle(HColor.textOnWashSecondary)
        }
      }
      VStack(alignment: .leading, spacing: 10) {
        SlimProgressBar(detail.progress, fill: HColor.paceFill, track: HColor.progressTrackOnHue, height: 8)
        HStack(alignment: .top, spacing: 6) {
          HIconView(.calendar, size: 16, color: HColor.textOnWashSecondary)
            .padding(.top, 2)
          let range = Text(detail.range).font(HType.subheadline.weight(.semibold).font)
            .foregroundStyle(HColor.textPrimary)
          let when = Text(verbatim: " · \(detail.when)").foregroundStyle(HColor.textOnWashSecondary)
          Text("\(range)\(when)")
            .hType(.subheadline)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .padding(.horizontal, HSpacing.insetPage)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(spoken)
    .accessibilityAddTraits(.isStaticText)
    .accessibilityIdentifier("project.hero")
  }

  private var caption: MoneyPhrase {
    MoneyPhrase([.text(detail.left.isNegative ? "over " : "left of "), .amount(detail.budget, .compact, hidden: 3)])
  }

  private var spoken: String {
    let amount = hidden ? "Amount hidden" : "AED \(MoneyFormat.string(detail.left.minor))"
    return "\(detail.name), \(amount) \(caption.spoken(hidden: hidden)). \(detail.range), \(detail.when)."
  }
}
