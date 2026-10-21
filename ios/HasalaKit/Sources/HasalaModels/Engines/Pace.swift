// Pace arithmetic shared by Home, Plan, Activity's filtered summary and the
// transaction sheet. Integer only: money never becomes a float (CLAUDE.md).
//
// TODO(spec 04 §15.2): the live build takes these from CoreDomain's Plan engine
// (03a §6) once it lands; the numbers must agree (AT-REV-3 compares them).

public enum Pace {
  /// Where `spent` ends the month if it keeps today's daily rate: spent × days / day,
  /// rounded down (Paper: Groceries 812.40 on day 10 of 31 → "on course for 2,518").
  public static func projected(_ spent: Int64, day: Int, days: Int) -> Int64 {
    guard day > 0 else { return spent }
    return Fils.mulDiv(spent, Int64(days), Int64(day))
  }

  /// The verdict for a budget line. Bills and savings have no pace: they are on track
  /// until they are paid (`done`) or over budget.
  public static func verdict(spent: Int64, budget: Int64, day: Int, days: Int, paced: Bool) -> Verdict {
    if budget <= 0 { return spent > 0 ? .overBudget : .onTrack }
    if spent > budget { return .overBudget }
    if !paced { return spent >= budget ? .done : .onTrack }
    return projected(spent, day: day, days: days) > budget ? .overPace : .onTrack
  }

  /// The month gone, in whole percent as permille ("32% of October gone" draws its tick at 320).
  public static func monthGone(day: Int, days: Int) -> Permille {
    guard days > 0 else { return Permille(0) }
    return Permille(day * 100 / days * 10)
  }

  /// What is left per day for the rest of the month, today included (7,417.55 / 22 days).
  public static func perDay(left: Int64, day: Int, days: Int) -> Int64 {
    let remaining = max(1, days - day + 1)
    return max(0, left) / Int64(remaining)
  }
}

extension Verdict {
  /// The tone of a verdict pill.
  public var tone: StatusTone {
    switch self {
    case .onTrack: .accent
    case .overPace: .warning
    case .overBudget: .error
    case .done: .success
    }
  }
}
