import Foundation
import HasalaModels

public enum WidgetClock {
  public static let offsetSeconds: TimeInterval = 4 * 3600

  public static func today(at date: Date = .now) -> LocalDate {
    let days = Int(((date.timeIntervalSince1970 + offsetSeconds) / 86_400).rounded(.down))
    return LocalDate(ordinal: days)
  }

  public static func nextMidnight(after date: Date) -> Date {
    let days = ((date.timeIntervalSince1970 + offsetSeconds) / 86_400).rounded(.down) + 1
    return Date(timeIntervalSince1970: days * 86_400 - offsetSeconds)
  }
}

public struct WidgetReading: Sendable, Hashable {
  public var snapshot: WidgetSnapshot?
  public var stale: Bool

  public init(_ stored: WidgetSnapshot?, at date: Date) {
    let current = stored.map { $0.asOf == WidgetClock.today(at: date) } ?? false
    snapshot = current ? stored : nil
    stale = stored != nil && !current
  }
}
