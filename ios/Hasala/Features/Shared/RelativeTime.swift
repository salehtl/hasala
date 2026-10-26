import Foundation

nonisolated enum RelativeTime {
  static func ago(ms: Int64) -> String {
    let minutes = max(0, ms / 60_000)
    if minutes < 1 { return "just now" }
    if minutes < 60 { return "\(minutes) min ago" }
    if minutes < 48 * 60 { return "\(minutes / 60) h ago" }
    return "\(minutes / (24 * 60)) days ago"
  }

  static func ago(_ date: Date, now: Date) -> String {
    ago(ms: Int64((now.timeIntervalSince(date) * 1000).rounded(.down)))
  }
}
