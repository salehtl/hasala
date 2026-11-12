import HasalaDesign
import HasalaModels
import SwiftUI

/// Set your monthly plan · Starting plan (Paper 5GY-0): the split with its two handles, the three
/// buckets with what each gets a month (whole dirhams, following the handles), and "Use this
/// plan". The split and the salary stay as they were left through Back
/// and Forward.
struct PlanStep: View {
  @Bindable var model: MonthlyPlanModel

  static let resetTitle = "Reset to 50 / 30 / 20"

  static func subtitle(_ p: StartingPlan) -> String {
    "\(p.needsPercent)% needs, \(p.wantsPercent)% wants, \(p.savingsPercent)% savings. Hasala fills in your categories."
  }

  var body: some View {
    let p = model.plan
    AccountScreen(
      title: "Here's a plan to start with.",
      subtitle: Self.subtitle(p),
      back: .system,
      trailing: ("Skip", { Task { await model.savePlan(skip: true) } })
    ) {
      VStack(spacing: 0) {
        SplitHandles(plan: $model.plan)
          // Paper: the split 28 under the question (the template's content, 24).
          .padding(.top, 4)
        let amounts = model.savedIncomeMinor.map { p.amounts(income: $0) }
        VStack(spacing: 10) {
          BucketCard(bucket: .needs, icon: .rent, title: "Needs", amount: amounts?.needs, plan: $model.plan,
                     detail: "Rent, utilities, groceries, transport, healthcare, insurance")
          BucketCard(bucket: .wants, icon: .dining, title: "Wants", amount: amounts?.wants, plan: $model.plan,
                     detail: "Dining, entertainment, shopping, travel, subscriptions")
          BucketCard(bucket: .savings, icon: .savings, title: "Savings", amount: amounts?.savings, plan: $model.plan,
                     detail: "Savings, investments, paying off debt")
          if model.plan.changed {
            Button {
              model.plan = StartingPlan()
              AccessibilityNotification.Announcement(model.plan.splitAnnouncement).post()
            } label: {
              Text(Self.resetTitle)
                .hType(HType(size: 17, leading: 24, weight: .semibold, textStyle: .body))
                .foregroundStyle(HColor.textLink)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("plan.reset")
          }
          SetupFailureBanner(failure: model.failure)
        }
        .padding(.top, 24)
      }
    } footer: {
      BusyButton(title: "Use this plan", busy: model.busy, enabled: model.plan.isValid, identifier: "plan.use") {
        Task { await model.savePlan() }
      }
    }
  }
}

/// A bucket of the starting plan (Paper "Bucket · Needs"): its hue disc and icon, the name,
/// what it gets a month ("12,500 a month"), and what goes in it. Without an income the
/// amount isn't shown.
private struct BucketCard: View {
  let bucket: Bucket
  let icon: HIcon
  let title: String
  let amount: Int64?
  @Binding var plan: StartingPlan
  let detail: String

  private var percent: Int {
    switch bucket {
    case .needs: plan.needsPercent
    case .wants: plan.wantsPercent
    default: plan.savingsPercent
    }
  }

  var body: some View {
    VStack(spacing: 12) {
      summary
      HStack(spacing: 4) {
        Spacer(minLength: 52)
        stepButton(-5, icon: "minus", label: "Less for \(title.lowercased())")
        Text("\(percent)%")
          .hType(HType(size: 17, leading: 22, weight: .bold, textStyle: .headline))
          .monospacedDigit()
          .foregroundStyle(HColor.textPrimary)
          .frame(width: 52)
          .accessibilityHidden(true)
        stepButton(5, icon: "plus", label: "More for \(title.lowercased())")
      }
    }
    .padding(16)
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.brief, style: .continuous))
  }

  private func stepButton(_ delta: Int, icon: String, label: String) -> some View {
    let next = plan.stepping(bucket, by: delta)
    return Button {
      guard let next else { return }
      plan = next
      AccessibilityNotification.Announcement(next.splitAnnouncement).post()
    } label: {
      Image(systemName: icon)
        .font(.system(size: 16, weight: .bold))
        .foregroundStyle(next == nil ? HColor.textDisabled : HColor.iconPrimary)
        .frame(width: 44, height: 44)
        .background(HColor.surfaceSecondary, in: Circle())
    }
    .buttonStyle(.plain)
    .disabled(next == nil)
    .accessibilityLabel(label)
    .accessibilityValue("\(percent)%")
    .accessibilityIdentifier("plan.\(bucket.rawValue).\(delta > 0 ? "more" : "less")")
  }

  private var summary: some View {
    HStack(alignment: .top, spacing: 12) {
      CategoryDisc(hue: bucket.hue, icon: icon, size: .s40)
      VStack(alignment: .leading, spacing: 2) {
        ReflowingRow(alignment: .firstTextBaseline) {
          Text(title)
            .hType(HType(size: 17, leading: 22, weight: .semibold, textStyle: .headline))
            .foregroundStyle(HColor.textPrimary)
        } trailing: {
          if let amount {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
              MoneyText(Money.aed(amount), figure: HFigure.small.withTracking(-0.3), style: .rounded)
              Text("a month").hType(.footnote).foregroundStyle(HColor.textSecondary)
            }
          }
        }
        Text(detail)
          .hType(.footnote)
          .foregroundStyle(HColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityElement(children: .combine)
  }
}

extension HFigure {
  /// The same figure with Paper's tracking for one place.
  func withTracking(_ t: CGFloat) -> HFigure {
    var f = self
    f.tracking = t
    return f
  }
}
