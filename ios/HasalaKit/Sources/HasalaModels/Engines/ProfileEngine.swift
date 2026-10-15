// Profile · Your profile (and its page-14 variant with Sign-in & security) and Categories and rules.

public struct ProfileSnapshot: Sendable, Hashable {
  public var displayName: String
  public var initial: String
  /// "maya@example.com · Verified".
  public var emailLine: String
  public var mailbox: MailboxHealth
  /// "4 · net worth 227,568".
  public var accounts: MoneyPhrase
  /// Some account has a balance (`AccountsSnapshot.hasBalances`): Accounts has something
  /// true to show.
  public var accountsKnown: Bool
  /// "9 tracked · 1 new found".
  public var bills: String
  /// Bills found and waiting for a decision (the row's badge).
  public var newBills: Int
  /// "18 categories · 23 rules".
  public var categoriesAndRules: String
  /// "Japan trip · 7,140.00 left".
  public var projects: MoneyPhrase?
  /// The project the Projects row opens.
  public var projectID: ProjectID?
  public var signIn: SignInMethod
  public var prefs: DevicePrefs
  /// "← Want · Need →".
  public var swipeSummary: String
  /// What VoiceOver reads for it: "Swipe left for Want, right for Need" (arrows aren't speech).
  public var swipeSpoken: String
}

public struct RuleRowModel: Sendable, Hashable, Identifiable {
  public var id: RuleID
  /// "\"CAREEM\" or \"UBER\"" (curly quotes).
  public var pattern: String
  /// "Starts with · Transport · 18 matches".
  public var detail: String
  /// "Starts with · Transport": how it matches and where it sorts.
  public var match: String
  /// "18 matches".
  public var matchesLabel: String
  public var glyph: Glyph
  public var hue: Hue
  public var enabled: Bool
  public var learnedToday: Bool
  public var matches: Int
}

public enum ProfileEngine {
  public static func snapshot(_ s: LedgerState, now: LocalDateTime) -> ProfileSnapshot {
    let netWorth = s.accounts.reduce(Int64(0)) { $0 + $1.balance.minor }
    let tracked = s.bills.filter { $0.state == .tracked }.count
    let found = s.billCandidates.count
    let categories = s.categories.filter { !$0.archived }.count
    let plan = PlanEngine.snapshot(s, now: now)
    let project = plan.projects.first
    let right = s.prefs.swipeNeedOnRight
    return ProfileSnapshot(
      displayName: s.profile.displayName,
      initial: s.profile.initial,
      emailLine: s.profile.email + (s.profile.emailVerified ? " · Verified" : " · Not verified"),
      mailbox: s.mailbox,
      accounts: MoneyPhrase([
        .text("\(s.accounts.count) · net worth "), .amount(.aed(netWorth), .rounded, hidden: 4),
      ]),
      accountsKnown: s.accounts.contains { !$0.balance.isZero },
      bills: "\(tracked) tracked" + (found > 0 ? " · \(found) new found" : ""),
      newBills: found,
      categoriesAndRules: "\(categories) categories · \(s.rules.count) rule\(s.rules.count == 1 ? "" : "s")",
      projects: project.map { MoneyPhrase([.text("\($0.name) · "), .amount($0.left), .text(" left")]) },
      projectID: project?.id,
      signIn: s.profile.signIn,
      prefs: s.prefs,
      swipeSummary: right ? "← Want · Need →" : "← Need · Want →",
      swipeSpoken: right ? "Swipe left for Want, right for Need" : "Swipe left for Need, right for Want"
    )
  }

  /// Rules, most used first, with match counts over every transaction.
  public static func rules(_ s: LedgerState) -> [RuleRowModel] {
    s.rules.map { r in
      let n = s.txns.filter { r.matches($0.merchant) || r.matches($0.provenance?.rawMerchant ?? "") }.count
      let c = s.category(r.categoryID)
      let match = "\(r.match.label) · \(c?.name ?? "Uncategorized")"
      let matches = "\(n) match\(n == 1 ? "" : "es")"
      return RuleRowModel(
        id: r.id,
        pattern: r.patterns.map { "\u{201C}\($0)\u{201D}" }.joined(separator: " or "),
        detail: "\(match) · \(matches)", match: match, matchesLabel: matches,
        glyph: c?.glyph ?? .review, hue: c?.hue ?? .other, enabled: r.enabled, learnedToday: r.learnedToday,
        matches: n
      )
    }.sorted { $0.matches > $1.matches }
  }
}
