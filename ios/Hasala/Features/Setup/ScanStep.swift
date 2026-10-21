import HasalaDesign
import HasalaModels
import SwiftUI

/// Setup · 2 of 4 · First scan (Paper FR2-0; with the connected mailbox, "Outlook
/// connected · First scan" 1NMP-0): the mailbox just connected, the live count with its
/// bar, what is happening right now, and "Set up your plan", which leaves the scan running.
/// Back shows the email step connected, and never connects again.
struct ScanStep: View {
  var model: SetupModel

  var body: some View {
    let mailbox = model.connectedMailbox
    AccountScreen(
      title: mailbox.map { "\($0.provider.appName) is connected. Reading your alerts now." }
        ?? "Reading your bank alerts, on this iPhone.",
      subtitle: "Your alerts are read here and sealed before anything syncs. It takes a minute or two, so set up your plan meanwhile.",
      steps: model.steps(2),
      back: .system
    ) {
      VStack(spacing: 12) {
        if let mailbox {
          // The board's mailbox card sits 20 under the question; the count card 20 under it.
          MailboxRow(mailbox)
            .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
            .padding(.bottom, 8)
            .hAnimation(.stateSwap, value: mailbox.state)
        }
        ScanCountCard(scan: model.scan, banks: model.bankList)
        ScanSteps(scan: model.scan, banks: model.bankList)
        SetupFailureBanner(failure: model.failure)
      }
      .padding(.top, -4)
    } footer: {
      Button("Set up your plan") { model.planWhileScanning() }
        .buttonStyle(.pill(.primary, fill: true))
        .accessibilityIdentifier("scan.setUpPlan")
    }
  }
}

/// The count card (Paper "Scan progress", page 17 §06): the app icon, the live count
/// ("182" + "of 268 alerts", rolling as it climbs), the banks, and an 8 bar. VoiceOver
/// reads one element, "Reading alerts, 182 of 268".
struct ScanCountCard: View {
  var scan: ScanProgress?
  var banks: String

  var body: some View {
    let read = scan?.read ?? 0
    let total = scan?.total ?? 0
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 14) {
        AppIconTile(size: 52, radius: 14)
          .shadow(color: HColor.blue950.opacity(0.18), radius: 1, x: 0, y: 1)
          .shadow(color: HColor.blue950.opacity(0.16), radius: 7, x: 0, y: 6)
        VStack(alignment: .leading, spacing: 0) {
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: "\(read)")
              .hFigure(HFigure(size: 28, leading: 32, weight: .bold, tracking: -0.5, textStyle: .title2))
              .foregroundStyle(HColor.textPrimary)
              .numberRoll(Double(read))
            Text(verbatim: "of \(total) alerts")
              .hFigure(HFigure(size: 17, leading: 22, weight: .semibold, textStyle: .body))
              .foregroundStyle(HColor.textSecondary)
          }
          Text("\(banks) · on this iPhone").hType(.footnote).foregroundStyle(HColor.textSecondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      ScanBar(fraction: scan?.fraction ?? 0)
    }
    .padding(20)
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.listGroup, style: .continuous))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Reading alerts")
    .accessibilityValue("\(read) of \(total)")
    .accessibilityIdentifier("scan.progress")
  }
}

/// The first scan's bar (Paper: 8 tall, radius 4, `pace-track` with an accent fill; the
/// spec's drift note keeps the board's values). It follows the count with the fill-update
/// curve; still under Reduce Motion.
private struct ScanBar: View {
  let fraction: Double

  var body: some View {
    GeometryReader { geo in
      ZStack(alignment: .leading) {
        Capsule().fill(HColor.paceTrack)
        Capsule().fill(HColor.actionAccent)
          .frame(width: geo.size.width * min(1, max(0, fraction)))
      }
    }
    .frame(height: 8)
    .hAnimation(.fillUpdate, value: fraction)
    .accessibilityHidden(true)
  }
}

/// What the scan is doing (Paper "Scan steps"): downloaded, inbox left alone, sorting
/// here, sealing next. Only one row is "now"; each finished step is announced once.
struct ScanSteps: View {
  var scan: ScanProgress?
  var banks: String

  private enum Stage: Int { case downloading, sorting, sealed }

  private var stage: Stage {
    switch scan?.phase {
    case .finished?: .sealed
    case .sorting?, .background?: .sorting
    default: .downloading
    }
  }

  var body: some View {
    StepCard {
      if stage == .downloading {
        StepRow(text: "Downloading alerts from \(banks)", state: .now)
      } else {
        StepRow(text: "Downloaded \(scan?.total ?? 0) alerts from \(banks)", state: .done)
      }
      StepRow(text: "Left the rest of your inbox alone", state: .done)
      StepRow(text: "Sorting, right here", state: stage == .sorting ? .now : stage == .sealed ? .done : .next,
              detail: Self.sortingDetail)
      StepRow(text: "Seal everything before it syncs", state: stage == .sealed ? .done : .next)
    }
    .onChange(of: stage) { _, now in
      // Announce each finished step, not every count (page 17).
      let finished = now == .sorting ? "Downloaded your alerts." : "Sorted and sealed."
      AccessibilityNotification.Announcement(finished).post()
    }
  }

  /// The on-device model tier (Foundation Models) is a later sweep, not part of this build's
  /// sorting, so a Release build doesn't name it.
  static var sortingDetail: String {
    if MerchantSuggestionsSetting.isEnabled() {
      return "A UAE merchant list first. Merchant names it can't place go to Cloudflare's AI, one at a time. Anything unsure waits for you."
    }
    return BuildSurface.showsUnfinished
      ? "A UAE merchant list first, then Apple's on-device model. Anything unsure waits for you. Nothing goes to an AI service."
      : "A UAE merchant list first. Anything unsure waits for you. Nothing goes to an AI service."
  }
}
