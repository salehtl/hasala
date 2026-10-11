// Profile · Your profile (and its page-14 variant with Sign-in & security) and Categories and rules.

public struct ProfileSnapshot: Sendable, Hashable {
  public var displayName: String
  public var initial: String
  /// "maya@example.com · Verified".
  public var emailLine: String
  public var mailbox: MailboxHealth
  public var accounts: MoneyPhrase
  public var bills: String
  public var newBills: Int
  public var categoriesAndRules: String
  public var projects: MoneyPhrase?
  public var signIn: SignInMethod
  public var prefs: DevicePrefs
  /// "← Want · Need →".
  public var swipeSummary: String
}

public struct RuleRowModel: Sendable, Hashable, Identifiable {
  public var id: RuleID
  /// "\"CAREEM\" or \"UBER\"".
  public var pattern: String
  /// "Starts with · Transport · 18 matches".
  public var detail: String
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
      bills: "\(tracked) tracked" + (found > 0 ? " · \(found) new found" : ""),
      newBills: found,
      categoriesAndRules: "\(categories) categories · \(s.rules.count) rule\(s.rules.count == 1 ? "" : "s")",
      projects: project.map { MoneyPhrase([.text("\($0.name) · "), .amount($0.left), .text(" left")]) },
      signIn: s.profile.signIn,
      prefs: s.prefs,
      swipeSummary: right ? "← Want · Need →" : "← Need · Want →"
    )
  }

  /// Rules, most used first, with match counts over every transaction.
  public static func rules(_ s: LedgerState) -> [RuleRowModel] {
    s.rules.map { r in
      let n = s.txns.filter { r.matches($0.merchant) || r.matches($0.provenance?.rawMerchant ?? "") }.count
      let c = s.category(r.categoryID)
      return RuleRowModel(
        id: r.id,
        pattern: r.patterns.map { "\"\($0)\"" }.joined(separator: " or "),
        detail: "\(r.match.label) · \(c?.name ?? "Uncategorized") · \(n) match\(n == 1 ? "" : "es")",
        glyph: c?.glyph ?? .review, hue: c?.hue ?? .other, enabled: r.enabled, learnedToday: r.learnedToday,
        matches: n
      )
    }.sorted { $0.matches > $1.matches }
  }
}
