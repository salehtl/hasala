// Pace arithmetic shared by Home, Plan, Activity's filtered summary and the
// transaction sheet. Integer only: money never becomes a float (CLAUDE.md).
//
// TODO(spec 04 §15.2): the live build takes these from CoreDomain's Plan engine
// (03a §6) once it lands; the numbers must agree (AT-REV-3 compares them).

public enum Pace {
  /// Where `spent` ends the month if it keeps today's daily rate: spent × days / day,
  /// rounded down (Paper: Groceries 812.40 on day 10 of 31 → "on course for 2,518").
  public static let minDay = 7
  public static let marginPercent: Int64 = 105

  public static func projected(_ spent: Int64, day: Int, days: Int, largest: Int64 = 0) -> Int64 {
    guard day > 0 else { return spent }
    let one = largest > 0 && largest.plus(largest) > spent ? largest : 0
    return one.plus(Fils.mulDiv(spent.minus(one), Int64(days), Int64(day)))
  }

  public static func showsProjection(day: Int) -> Bool { day >= minDay }

  public static func ahead(_ projected: Int64, of budget: Int64) -> Bool {
    Int128(projected) * 100 > Int128(budget) * Int128(marginPercent)
  }

  /// The verdict for a budget line. Bills and savings have no pace: they are on track
  /// until they are paid (`done`) or over budget.
  public static func verdict(spent: Int64, budget: Int64, day: Int, days: Int, paced: Bool, largest: Int64 = 0) -> Verdict {
    if budget <= 0 { return spent > 0 ? .overBudget : .onTrack }
    if spent > budget { return .overBudget }
    if !paced { return spent >= budget ? .done : .onTrack }
    guard showsProjection(day: day) else { return .onTrack }
    return ahead(projected(spent, day: day, days: days, largest: largest), of: budget) ? .overPace : .onTrack
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
