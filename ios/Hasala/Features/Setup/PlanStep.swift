import HasalaDesign
import HasalaModels
import SwiftUI

/// Setup · 4 of 4 · Starting plan (Paper 5GY-0): the split with its two handles, the three
/// buckets with what each gets a month (whole dirhams, following the handles), the scan's
/// pill, and "Use this plan". The split and the salary stay as they were left through Back
/// and Forward.
struct PlanStep: View {
  @Bindable var model: SetupModel

  var body: some View {
    let p = model.plan
    AccountScreen(
      title: "Here's a plan to start with.",
      subtitle: "\(p.needsPercent)% for needs, \(p.wantsPercent)% for wants, \(p.savingsPercent)% for savings. Drag the handles to change the split. Hasala fills in your categories.",
      steps: model.steps(4),
      back: .system,
      trailing: ("Skip", { Task { await model.savePlan(skip: true) } })
    ) {
      VStack(spacing: 0) {
        SplitHandles(plan: $model.plan)
          // Paper: the split 28 under the question (the template's content, 24).
          .padding(.top, 4)
        let amounts = model.savedIncomeMinor.map { p.amounts(income: $0) }
        VStack(spacing: 10) {
          BucketCard(bucket: .needs, icon: .rent, title: "Needs", amount: amounts?.needs,
                     detail: "Rent, utilities, groceries, transport, healthcare, insurance")
          BucketCard(bucket: .wants, icon: .dining, title: "Wants", amount: amounts?.wants,
                     detail: "Dining, entertainment, shopping, travel, subscriptions")
          BucketCard(bucket: .savings, icon: .savings, title: "Savings", amount: amounts?.savings,
                     detail: "Savings, investments, paying off debt")
          SetupFailureBanner(failure: model.failure)
        }
        .padding(.top, 24)
      }
    } footer: {
      ScanPill(scan: model.scan, running: model.scanRunning)
        .padding(.bottom, 6)
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
  let detail: String

  var body: some View {
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
    .padding(16)
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.brief, style: .continuous))
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
