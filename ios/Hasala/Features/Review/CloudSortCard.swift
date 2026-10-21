import Foundation
import HasalaDesign
import HasalaModels
import SwiftUI

nonisolated enum CloudSortCardState: Equatable, Sendable {
  case ready
  case running
  case paused(CloudSortStatus.Pause)
  case done

  static let minimumNames = 5
  static let namesPerMinute = 24

  static func of(_ status: CloudSortStatus, dismissedRun: Int64?) -> CloudSortCardState? {
    switch status.phase {
    case .off:
      return nil
    case .running:
      return .running
    case .paused(let p):
      return .paused(p)
    case .done:
      if let ended = status.lastRunEndedMs, ended != dismissedRun { return .done }
      return waiting(status)
    case .idle:
      return waiting(status)
    }
  }

  private static func waiting(_ status: CloudSortStatus) -> CloudSortCardState? {
    guard status.waitingNames >= minimumNames else { return nil }
    return status.remainingToday > 0 && status.nextRunNames > 0 ? .ready : .paused(.dayCap)
  }

  static func minutesLeft(_ status: CloudSortStatus) -> Int {
    let left = max(0, status.totalNames - status.askedNames)
    return max(1, (left + namesPerMinute - 1) / namesPerMinute)
  }

  static func eta(_ status: CloudSortStatus) -> String {
    let m = minutesLeft(status)
    return (m == 1 ? "About a minute." : "About \(m) minutes.") + " Keep Hasala open."
  }

  static func plural(_ n: Int, _ one: String, _ many: String) -> String {
    "\(n) \(n == 1 ? one : many)"
  }

  static func readyLead(_ status: CloudSortStatus) -> String {
    let n = status.waitingNames
    return "\(plural(n, "merchant", "merchants")) in Review \(n == 1 ? "isn't" : "aren't") on Hasala's list. Cloudflare's AI can sort the ones it's sure about and suggest the rest. It asks about each merchant name once, nothing else."
  }

  static func startLabel(_ status: CloudSortStatus) -> String {
    "Sort \(plural(status.nextRunNames, "merchant", "merchants"))"
  }

  static func progressLine(_ status: CloudSortStatus) -> String {
    "\(status.askedNames) of \(plural(status.totalNames, "merchant", "merchants")) · \(plural(status.filed, "payment", "payments")) sorted so far"
  }

  static func pauseLine(_ pause: CloudSortStatus.Pause, status: CloudSortStatus, timeZone: TimeZone = .current) -> String {
    switch pause {
    case .offline:
      return "Paused. No internet connection. It continues when you're back online."
    case .background:
      return "Paused while Hasala is in the background. Open Hasala to continue."
    case .busy(let until), .rateLimited(let until):
      return "Cloudflare's AI is busy. Hasala will try again at \(clock(until, timeZone: timeZone))."
    case .runCap:
      return "Paused after \(plural(status.askedNames, "merchant", "merchants")), today's limit for one run."
    case .dayCap:
      return "That's today's limit on this iPhone. You can sort the rest tomorrow."
    }
  }

  static func nextLabel(_ status: CloudSortStatus) -> String {
    "Sort the next \(status.nextRunNames)"
  }

  static func doneLine(_ status: CloudSortStatus) -> String {
    "\(plural(status.filed, "payment", "payments")) sorted, \(plural(status.suggested, "suggestion", "suggestions")) to check, \(status.leftForYou) for you to sort."
  }

  static func sendBackTitle(_ n: Int) -> String {
    "Send \(plural(n, "payment", "payments")) back to Review?"
  }

  static let sendBackMessage =
    "They keep Cloudflare's suggestion, and you confirm each one. Payments you've changed since stay as they are."

  static func sentBack(_ n: Int) -> String {
    n == 0 ? "Nothing to send back" : "Sent \(plural(n, "payment", "payments")) back to Review"
  }

  static func clock(_ ms: Int64, timeZone: TimeZone = .current) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_GB_POSIX")
    f.timeZone = timeZone
    f.dateFormat = "HH:mm"
    return f.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
  }

  var offersCheckSuggestions: Bool { self == .done }
}

enum CloudSortDismissal {
  static let key = "app.hasala.prefs.cloudSort.dismissedRun"
}

struct CloudSortCard: View {
  let app: AppModel
  let sort: any CloudSortControlling
  let state: CloudSortCardState
  let dismiss: () -> Void
  @State private var confirmUndo = false
  @Environment(\.dynamicTypeSize) private var typeSize

  private var status: CloudSortStatus { sort.status }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .top, spacing: 12) {
        Circle().fill(HColor.reviewSuggestionSurface).frame(width: 32, height: 32)
          .overlay { HIconView(.cloud, size: 16, color: HColor.actionAccent, strokeWidth: 2) }
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 4) {
          Text(title)
            .hType(.headline)
            .foregroundStyle(HColor.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("review.sort.title")
          ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
            Text(line.text)
              .hType(.footnote)
              .foregroundStyle(HColor.textSecondary)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier(line.id)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if state == .done {
          Button(action: dismiss) {
            HIconView(.close, size: HSpacing.iconSmall, color: HColor.iconSecondary)
              .frame(width: HSpacing.targetMinimum, height: HSpacing.targetMinimum)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .padding(.top, -12)
          .padding(.trailing, -12)
          .accessibilityLabel("Dismiss")
          .accessibilityIdentifier("review.sort.dismiss")
        }
      }
      if showsProgress {
        SlimProgressBar(Permille.ratio(Int64(status.askedNames), of: Int64(max(status.totalNames, 1))),
                        fill: HColor.feedbackProgressIndicator, track: HColor.feedbackProgressTrack)
          .accessibilityHidden(true)
      }
      if typeSize.isAccessibilitySize {
        VStack(spacing: 10) { buttons(inRow: false) }
      } else {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 10) { buttons(inRow: true) }
          VStack(spacing: 10) { buttons(inRow: false) }
        }
      }
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("review.sort.card")
    .alert(CloudSortCardState.sendBackTitle(status.filed), isPresented: $confirmUndo) {
      Button("Send back") { undo() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(CloudSortCardState.sendBackMessage)
    }
  }

  private var title: String {
    switch state {
    case .ready: "Sort with Cloudflare AI"
    case .running, .paused: "Sorting with Cloudflare AI"
    case .done: "Done"
    }
  }

  private var lines: [(id: String, text: String)] {
    switch state {
    case .ready:
      return [("review.sort.lead", CloudSortCardState.readyLead(status))]
    case .running:
      return [("review.sort.line", CloudSortCardState.progressLine(status)),
              ("review.sort.eta", CloudSortCardState.eta(status))]
    case .paused(let p):
      var out: [(id: String, text: String)] = []
      if status.totalNames > 0 { out.append(("review.sort.line", CloudSortCardState.progressLine(status))) }
      out.append(("review.sort.pause", CloudSortCardState.pauseLine(p, status: status)))
      return out
    case .done:
      return [("review.sort.line", CloudSortCardState.doneLine(status))]
    }
  }

  private var showsProgress: Bool {
    switch state {
    case .running: true
    case .paused: status.totalNames > 0
    case .ready, .done: false
    }
  }

  @ViewBuilder private func buttons(inRow: Bool) -> some View {
    switch state {
    case .ready:
      Button(CloudSortCardState.startLabel(status)) { sort.start() }
        .buttonStyle(.pill(.primary, size: .medium, fill: true))
        .accessibilityIdentifier("review.sort.start")
    case .running:
      stopButton
    case .paused(let p):
      switch p {
      case .busy, .rateLimited:
        Button("Try now") { sort.start() }
          .buttonStyle(.pill(.primary, size: .medium, fill: true))
          .accessibilityIdentifier("review.sort.tryNow")
      case .runCap:
        Button(CloudSortCardState.nextLabel(status)) { sort.start() }
          .buttonStyle(.pill(.primary, size: .medium, fill: true))
          .fixedSize(horizontal: inRow, vertical: false)
          .accessibilityIdentifier("review.sort.next")
      case .offline, .background, .dayCap:
        EmptyView()
      }
      if case .paused = status.phase { stopButton }
    case .done:
      if app.suggestionCount > 0 {
        Button("Check suggestions") { app.openCheckSuggestions() }
          .buttonStyle(.pill(.primary, size: .medium, fill: true))
          .fixedSize(horizontal: inRow, vertical: false)
          .accessibilityIdentifier("review.sort.check")
      }
      if status.canUndoLastRun {
        Button("Undo") { confirmUndo = true }
          .buttonStyle(.pill(.secondary, size: .medium, fill: true))
          .accessibilityIdentifier("review.sort.undo")
      }
    }
  }

  private var stopButton: some View {
    Button("Stop") { sort.stop() }
      .buttonStyle(.pill(.secondary, size: .medium, fill: true))
      .accessibilityIdentifier("review.sort.stop")
  }

  private func undo() {
    let sort = self.sort
    let app = self.app
    Task {
      let n = await sort.undoLastRun()
      app.say(CloudSortCardState.sentBack(n))
    }
  }
}
