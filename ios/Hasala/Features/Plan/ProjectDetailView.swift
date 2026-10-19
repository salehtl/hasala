import HasalaDesign
import HasalaModels
import SwiftUI

struct ProjectDetailView: View {
  @Bindable var app: AppModel
  let project: ProjectID
  @State private var model: ProjectDetailViewModel
  @State private var confirmRemove = false

  init(app: AppModel, project: ProjectID) {
    self.app = app
    self.project = project
    _model = State(initialValue: ProjectDetailViewModel(app: app, project: project))
  }

  private var inPlan: Bool { app.router.plan.contains(.project(project)) }

  var body: some View {
    if let d = model.detail {
      PlanDetailScreen(
        app: app, title: d.name, wash: .hue(.peach),
        more: [
          PlanMenuItem(title: "Edit project") { model.edit() },
          PlanMenuItem(title: "Remove project") { confirmRemove = true },
        ],
        hostsToast: inPlan
      ) {
        ProjectHero(detail: d, hidden: model.hidden)
        planSetting(d)
        if !d.categories.isEmpty { byCategory(d) }
        transactions(d)
        actions(d)
      }
      .confirmationDialog("Remove \(d.name)?", isPresented: $confirmRemove, titleVisibility: .visible) {
        Button("Remove project", role: .destructive) { model.remove() }
          .accessibilityIdentifier("project.removeConfirm")
      } message: {
        Text("Its transactions stay, and count in your monthly plan again.")
      }
    } else {
      PlanDetailScreen(app: app, title: "Project", wash: .hue(.peach), hostsToast: inPlan) {
        EmptyStateCard(icon: .project, tone: .neutral, title: "This project is gone",
                       message: "It was removed. Plan shows the projects you have now.")
          .padding(.horizontal, HSpacing.insetPage)
      }
    }
  }

  private func planSetting(_ d: ProjectDetail) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Toggle(isOn: Binding(get: { d.countInPlan }, set: { model.setCountInPlan($0) })) {
        Text("Count in monthly plan").hType(.rowTitle).foregroundStyle(HColor.listRowTitle)
          .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
      }
      .tint(HColor.controlSwitchTrackOn)
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

  private func transactions(_ d: ProjectDetail) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      CountedTitle(title: "Transactions", count: d.transactions.count)
      if d.transactions.isEmpty {
        Text("Nothing in this project yet. Add the transactions that belong to it.")
          .hType(.subheadline).foregroundStyle(HColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      } else {
        PlanListCard {
          ForEach(d.transactions) { row in
            Button { model.open(row.id) } label: { TransactionRow(row, hidden: model.hidden) }
              .buttonStyle(HRowPressStyle())
              .accessibilityIdentifier("project.txn.\(row.id)")
          }
        }
      }
    }
    .padding(.horizontal, HSpacing.insetPage)
  }

  private func actions(_ d: ProjectDetail) -> some View {
    VStack(spacing: 8) {
      Button("Add transactions") { model.addTransactions() }
        .buttonStyle(.pill(.onGrouped, fill: true, leadingIcon: .add))
        .accessibilityIdentifier("project.addTransactions")
      Button(d.complete ? "Reopen" : "Mark complete") { model.setComplete(!d.complete) }
        .buttonStyle(.pill(.tertiary, fill: true))
        .accessibilityIdentifier("project.markComplete")
    }
    .padding(.horizontal, HSpacing.insetPage)
  }
}

private struct ProjectHero: View {
  let detail: ProjectDetail
  let hidden: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 14) {
        HStack(spacing: 12) {
          CategoryDisc(hue: .peach, icon: detail.glyph.icon, size: .s56)
            .hElevation(.near)
          if detail.complete {
            StatusPillView(StatusPill("Completed", tone: .success), size: .s32, surface: .white)
          }
        }
        VStack(alignment: .leading, spacing: 4) {
          MoneyText(figure, figure: .hero, unit: .unit, hidden: hidden, hiddenGlyphs: 6,
                    color: over ? HColor.statusErrorForeground : HColor.textPrimary, unitGap: 6)
          PhraseText(caption, hidden: hidden).hType(.body).foregroundStyle(HColor.textOnWashSecondary)
          if !detail.pending.isZero {
            PhraseText(MoneyPhrase([.text("+ "), .amount(detail.pending, .compact, hidden: 3), .text(" waiting for review")]),
                       hidden: hidden)
              .hType(.footnote).foregroundStyle(HColor.textOnWashSecondary)
          }
        }
      }
      VStack(alignment: .leading, spacing: 10) {
        if detail.budget != nil {
          SlimProgressBar(detail.progress, fill: HColor.paceFill, track: HColor.progressTrackOnHue, height: 8)
        }
        if let line = dateLine {
          HStack(alignment: .top, spacing: 6) {
            HIconView(.calendar, size: 16, color: HColor.textOnWashSecondary)
              .padding(.top, 2)
            line
              .hType(.subheadline)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
    }
    .padding(.horizontal, HSpacing.insetPage)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(spoken)
    .accessibilityAddTraits(.isStaticText)
    .accessibilityIdentifier("project.hero")
  }

  private var over: Bool { detail.left?.isNegative == true }

  private var figure: Money {
    guard let left = detail.left else { return detail.spent }
    return .aed(abs(left.minor))
  }

  private var dateLine: Text? {
    switch (detail.range, detail.when) {
    case let (range?, when?):
      let r = Text(range).font(HType.subheadline.weight(.semibold).font).foregroundStyle(HColor.textPrimary)
      let w = Text(verbatim: " · \(when)").foregroundStyle(HColor.textOnWashSecondary)
      return Text("\(r)\(w)")
    case let (range?, nil):
      return Text(range).font(HType.subheadline.weight(.semibold).font).foregroundStyle(HColor.textPrimary)
    case let (nil, when?):
      return Text(when.prefix(1).uppercased() + when.dropFirst()).foregroundStyle(HColor.textOnWashSecondary)
    case (nil, nil):
      return nil
    }
  }

  private var caption: MoneyPhrase {
    guard let budget = detail.budget else { return "spent · no budget set" }
    return MoneyPhrase([.text(over ? "over " : "left of "), .amount(budget, .compact, hidden: 3)])
  }

  private var spoken: String {
    let amount = hidden ? "Amount hidden" : "AED \(MoneyFormat.string(figure.minor))"
    var out = "\(detail.name), \(amount) \(caption.spoken(hidden: hidden))."
    if !detail.pending.isZero {
      out += " " + MoneyPhrase([.amount(detail.pending, .compact), .text(" waiting for review.")]).spoken(hidden: hidden)
    }
    let when = [detail.range, detail.when].compactMap { $0 }.joined(separator: ", ")
    if !when.isEmpty { out += " \(when)." }
    return detail.complete ? out + " Completed." : out
  }
}
