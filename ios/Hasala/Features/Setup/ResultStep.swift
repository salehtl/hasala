import HasalaDesign
import HasalaModels
import SwiftUI

/// Setup · Result · First transactions sorted (Paper 7DG-0): the success badge, "264
/// transactions, sorted.", and how they were sorted. It never waits for the scan: until the
/// import finishes it says so, shows the count, and fills in (the badge landing) when it's
/// done. No header and no way back.
struct ResultStep: View {
  var model: SetupModel

  /// The window the first scan reads (`LiveMailboxConnecting.connect`).
  static let windowDays = 90

  var body: some View {
    if model.foundNoAlerts {
      NoAlertsResult(model: model)
    } else {
      sorted
    }
  }

  private var sorted: some View {
    let s = model.summary ?? SortSummary(total: 0, byRules: 0, byDictionary: 0, byModel: 0, toReview: 0)
    return CelebrationScreen(
      badge: model.scanDone ? .check : nil,
      title: title(s),
      subtitle: subtitle(s),
      wash: .itWorks,
      spacing: (40, 28)
    ) {
      VStack(spacing: 12) {
        if !model.scanDone {
          ScanCountCard(scan: model.scan, banks: model.bankList)
        }
        if model.scanDone, s.total > 0 {
          SortBreakdownCard(summary: s)
        }
        SetupFailureBanner(failure: model.failure)
      }
      .hAnimation(.stateSwap, value: model.scanDone)
    } footer: {
      Button("Continue") { model.afterResult() }
        .buttonStyle(.pill(.primary, fill: true))
        .accessibilityIdentifier("result.continue")
    }
  }

  private func title(_ s: SortSummary) -> String {
    if !model.scanDone { return "Importing your last \(Self.windowDays) days." }
    // None sorted itself (live Outlook while its trust gate is closed: each waits for review).
    return s.sortedThemselves == 0 ? "\(s.total) transactions found." : "\(s.total) transactions, sorted."
  }

  private func subtitle(_ s: SortSummary) -> String {
    if !model.scanDone {
      return "Carry on. They keep arriving in Hasala, newest included, and anything unsure waits for a quick swipe."
    }
    if s.toReview == 0 { return "All on this iPhone, and every one sorted itself." }
    if s.sortedThemselves == 0 { return "All on this iPhone. Each one waits for a quick swipe." }
    return "All on this iPhone. \(s.sortedThemselves) sorted themselves; \(s.toReview) wait for a quick swipe."
  }
}

private struct NoAlertsResult: View {
  var model: SetupModel
  @State private var helping: SupportedBank?

  private var mailbox: String { (model.connectedMailbox?.provider ?? model.provider).appName }

  var body: some View {
    ScrollView {
      VStack(spacing: 0) {
        VStack(spacing: 20) {
          Circle()
            .fill(HColor.statusWarningSurface)
            .frame(width: 72, height: 72)
            .overlay { HIconView(.envelope, size: 32, color: HColor.statusWarningForeground, strokeWidth: 1.8) }
            .accessibilityHidden(true)
          VStack(spacing: 8) {
            Text("No bank alerts yet.")
              .hType(.largeTitle)
              .foregroundStyle(HColor.textPrimary)
              .accessibilityAddTraits(.isHeader)
            Text("Hasala looked back \(ResultStep.windowDays) days in \(mailbox) for \(model.bankList). Your bank may send alerts only by SMS.")
              .hType(.body)
              .foregroundStyle(HColor.textOnWashSecondary)
              .frame(maxWidth: 320)
          }
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.top, 52)
        VStack(spacing: 12) {
          card
          SetupFailureBanner(failure: model.failure)
        }
        .padding(.horizontal, HSpacing.insetPage)
        .padding(.top, 28)
      }
      .padding(.bottom, 16)
    }
    .scrollBounceBehavior(.basedOnSize)
    .scrollEdgeEffectStyle(.soft, for: .bottom)
    .safeAreaBar(edge: .bottom) {
      ActionDock(keyboardUp: false) {
        Button("Check again") { Task { await model.checkAgain() } }
          .buttonStyle(.pill(.primary, fill: true, loading: model.checkingAgain))
          .dockPill()
          .accessibilityIdentifier("result.checkAgain")
        Button("Continue") { model.afterResult() }
          .buttonStyle(.pill(.onGrouped, fill: true))
          .disabled(model.checkingAgain)
          .dockPill()
          .accessibilityIdentifier("result.continue")
      }
    }
    .background(alignment: .top) {
      AmbientWash(.itWorks).ignoresSafeArea(edges: .top)
    }
    .background(HColor.surfaceSecondary)
    .navigationBarBackButtonHidden()
    .toolbar(.hidden, for: .navigationBar)
    .sheet(item: $helping) { bank in
      EmailAlertsHelpSheet(banks: [bank])
    }
  }

  private var card: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Turn on email alerts")
        .hType(.overline)
        .foregroundStyle(HColor.textSecondary)
        .accessibilityAddTraits(.isHeader)
        .padding(.bottom, 4)
      ForEach(Array(model.orderedBanks.enumerated()), id: \.element) { i, bank in
        if i > 0 { HColor.borderSubtle.frame(height: 1).accessibilityHidden(true) }
        HStack(spacing: 12) {
          Text(bank.name).hType(.rowTitle).foregroundStyle(HColor.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
          Button("How to") { helping = bank }
            .buttonStyle(.plain)
            .hType(HType.subheadline.weight(.medium))
            .foregroundStyle(HColor.textLink)
            .frame(minHeight: HSpacing.targetMinimum)
            .contentShape(Rectangle())
            .accessibilityLabel("How to turn on email alerts, \(bank.name)")
            .accessibilityIdentifier("result.howTo.\(bank.rawValue)")
        }
      }
      Text("New alerts are read as they arrive. Alerts go to another address? Use that mailbox instead.")
        .hType(.footnote)
        .foregroundStyle(HColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 8)
    }
    .padding(.top, 18)
    .padding(.horizontal, 16)
    .padding(.bottom, 16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.listGroup, style: .continuous))
  }
}

/// "How they were sorted" (Paper "How they were sorted"): a 10 bar in one segment per way,
/// then a legend of dots, names and counts. A way that sorted nothing has no row (the
/// on-device model in this beta), so nothing is promised that didn't happen.
private struct SortBreakdownCard: View {
  let summary: SortSummary

  private struct Way: Identifiable {
    let name: String
    let count: Int
    let color: Color
    var id: String { name }
  }

  private var ways: [Way] {
    [
      Way(name: "UAE merchant list", count: summary.byDictionary, color: HColor.blue600),
      Way(name: "Your rules", count: summary.byRules, color: HColor.blue400),
      Way(name: "Apple's on-device model", count: summary.byModel, color: HColor.blue300),
      Way(name: "Waiting for your swipe", count: summary.toReview, color: HColor.amber300),
    ].filter { $0.count > 0 }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("How they were sorted")
        .hType(.overline)
        .foregroundStyle(HColor.textSecondary)
        .accessibilityAddTraits(.isHeader)
      bar
      VStack(alignment: .leading, spacing: 8) {
        ForEach(ways) { way in
          HStack(spacing: 10) {
            Circle().fill(way.color).frame(width: 10, height: 10).accessibilityHidden(true)
            Text(way.name).hType(.subheadline).foregroundStyle(HColor.textPrimary)
              .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: "\(way.count)")
              .hFigure(HFigure.compact)
              .foregroundStyle(HColor.textPrimary)
          }
          .accessibilityElement(children: .combine)
        }
      }
      Rectangle().fill(HColor.borderSubtle).frame(height: 1).accessibilityHidden(true)
      Text(
        MerchantSuggestionsSetting.isEnabled()
          ? "From now on your own rules go first. Merchant names the list can't place go to Cloudflare's AI."
          : "From now on your own rules go first. Nothing was sent to an AI service.")
        .hType(.footnote)
        .foregroundStyle(HColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.top, 18)
    .padding(.horizontal, 16)
    .padding(.bottom, 16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.listGroup, style: .continuous))
  }

  /// One segment per way, 3 apart, each its share of the whole.
  private var bar: some View {
    GeometryReader { geo in
      let gaps = CGFloat(max(0, ways.count - 1)) * 3
      let total = CGFloat(max(1, ways.reduce(0) { $0 + $1.count }))
      HStack(spacing: 3) {
        ForEach(ways) { way in
          Capsule().fill(way.color).frame(width: (geo.size.width - gaps) * CGFloat(way.count) / total)
        }
      }
    }
    .frame(height: 10)
    .accessibilityHidden(true)
  }
}
