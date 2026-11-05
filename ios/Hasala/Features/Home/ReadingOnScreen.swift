import HasalaDesign
import HasalaModels
import SwiftUI

struct ReadingHold: Equatable {
  enum Link: Equatable {
    case none
    case signIn
    case seeWhy
    case importPast

    var title: String? {
      switch self {
      case .none: nil
      case .signIn: "Sign in again"
      case .seeWhy: "See why"
      case .importPast: "Import past email"
      }
    }
  }

  var caption: String?
  var overlineSuffix: String?
  var line: String?
  var link: Link = .none
  var warns = false
  var showsBar = true
}

enum ReadingOnScreen {
  static func hold(_ reading: ReadingState?, month: YearMonth) -> ReadingHold? {
    guard let r = reading, r.holdsVerdict(month) else { return nil }
    let thisMonth = month == r.today.yearMonth
    if r.isPartlyRead(month), let from = r.readsFrom {
      return ReadingHold(
        caption: thisMonth ? "spent since you connected" : "spent since \(from.dayMonth)",
        overlineSuffix: thisMonth ? "counting from \(from.dayMonth)" : nil,
        line: "Earlier \(month.name) isn't counted", link: .importPast, showsBar: false)
    }
    if r.isBeforeReading(month), let from = r.readsFrom {
      return ReadingHold(
        line: "Hasala reads from \(from.dayMonth). \(month.name) isn't counted.", link: .importPast, showsBar: false)
    }
    switch r.kind {
    case .stopped(let reason, let since):
      return ReadingHold(
        caption: since.map { "spent up to \($0.short)" },
        line: "Hasala stopped reading\(on(since, today: r.today)). Newer payments aren't counted.",
        link: reason == .signInAgain ? .signIn : .seeWhy, warns: true)
    case .elsewhere(let newest, true, _):
      return ReadingHold(
        caption: newest.map { "spent up to \($0.short)" },
        line: "Nothing new from your other iPhone\(since(newest, today: r.today)). Newer payments aren't counted.",
        link: .seeWhy, warns: true)
    case .importing:
      return ReadingHold(caption: "spent so far · still reading this month")
    default:
      return ReadingHold()
    }
  }

  static func on(_ day: LocalDate?, today: LocalDate) -> String {
    day.map { " on " + named($0, today: today) } ?? ""
  }

  static func since(_ day: LocalDate?, today: LocalDate) -> String {
    day.map { " since " + named($0, today: today) } ?? ""
  }

  static func named(_ day: LocalDate, today: LocalDate) -> String {
    if day == today { return "today" }
    let gap = day.days(until: today)
    return gap > 0 && gap < 7 ? day.weekdayShort : day.dayMonth
  }
}

struct ReadingHoldRow: View {
  let hold: ReadingHold
  var trailing: (title: String, identifier: String, action: () -> Void)?
  let open: (ReadingHold.Link) -> Void

  var body: some View {
    if let line = hold.line {
      if hold.warns {
        HStack(alignment: .top, spacing: 10) {
          Circle().fill(HColor.surfacePrimary).frame(width: 24, height: 24)
            .overlay { HIconView(.envelope, size: 14, color: HColor.statusWarningForeground, strokeWidth: 2.2) }
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 6) {
            Text(line).hType(.subheadline).foregroundStyle(HColor.statusWarningForeground)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("reading.hold.line")
            ReflowingRow(spacing: 12) {
              linkButton(tint: HColor.statusWarningForeground)
            } trailing: {
              if let trailing {
                Button(action: trailing.action) {
                  Text(trailing.title).hType(.subheadline.weight(.semibold)).foregroundStyle(HColor.textOnWashLink)
                    .padding(.vertical, 12).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, -12)
                .accessibilityIdentifier(trailing.identifier)
              }
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(HColor.statusWarningSurface,
                    in: RoundedRectangle(cornerRadius: HRadius.statTile, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reading.hold")
      } else {
        ReflowingRow(spacing: 12) {
          Text(line).hType(.subheadline).foregroundStyle(HColor.textOnWashSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("reading.hold.line")
        } trailing: {
          linkButton(tint: HColor.textOnWashLink)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reading.hold")
      }
    }
  }

  @ViewBuilder private func linkButton(tint: Color) -> some View {
    if let title = hold.link.title {
      Button { open(hold.link) } label: {
        Text(title).hType(.subheadline.weight(.semibold)).foregroundStyle(tint)
          .padding(.vertical, 12).contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .padding(.vertical, -12)
      .accessibilityIdentifier("reading.hold.link")
    }
  }
}
