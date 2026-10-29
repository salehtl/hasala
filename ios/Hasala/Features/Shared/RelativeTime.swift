import Foundation
import HasalaModels

nonisolated enum RelativeTime {
  static func ago(ms: Int64, nowMs: Int64) -> String {
    let minutes = max(0, ms / 60_000)
    if minutes < 1 { return "just now" }
    if minutes < 60 { return "\(minutes) min ago" }
    if minutes < 48 * 60 { return "\(minutes / 60) h ago" }
    if minutes < 8 * 24 * 60 { return "\(minutes / (24 * 60)) days ago" }
    let then = localDate(nowMs &- ms)
    let today = localDate(nowMs)
    return "on " + (then.year == today.year ? then.dayMonth : "\(then.dayMonth) \(then.year)")
  }

  static func ago(_ date: Date, now: Date) -> String {
    let nowMs = Int64((now.timeIntervalSince1970 * 1000).rounded(.down))
    return ago(ms: Int64((now.timeIntervalSince(date) * 1000).rounded(.down)), nowMs: nowMs)
  }

  static func localDate(_ epochMs: Int64) -> LocalDate {
    let day: Int64 = 86_400_000
    let local = epochMs &+ 4 * 3_600_000
    let days = local / day - (local % day < 0 ? 1 : 0)
    return LocalDate(ordinal: Int(days))
  }
}
