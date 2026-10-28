// Profile · Your profile (and its page-14 variant with Sign-in & security) and Categories and rules.

public struct ProfileSnapshot: Sendable, Hashable {
  public var displayName: String
  public var initial: String
  public var email: String
  public var emailStatus: String
  public var mailbox: MailboxHealth
  /// "4 accounts · net worth 227,568", or "No accounts yet".
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
  public var projects: MoneyPhrase
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
  public var patterns: [String]
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
    let netWorth = s.homeTotal(s.accounts.map(\.balance))
    let tracked = s.bills.filter { $0.state == .tracked }.count
    let found = s.billCandidates.count
    let categories = s.categories.filter { !$0.archived }.count
    let activeProjects = s.projects.filter { !$0.complete }.count
    let right = s.prefs.swipeNeedOnRight
    return ProfileSnapshot(
      displayName: s.profile.displayName,
      initial: s.profile.initial,
      email: s.profile.email,
      emailStatus: s.profile.emailVerified ? "Verified" : "Not verified",
      mailbox: s.mailbox,
      accounts: accountsLine(s.accounts.count, netWorth),
      accountsKnown: s.accounts.contains { !$0.balance.isZero },
      bills: "\(tracked) tracked" + (found > 0 ? " · \(found) new found" : ""),
      newBills: found,
      categoriesAndRules: "\(categories) categories · \(s.rules.count) rule\(s.rules.count == 1 ? "" : "s")",
      projects: projectsLine(activeProjects),
      signIn: s.profile.signIn,
      prefs: s.prefs,
      swipeSummary: right ? "← Want · Need →" : "← Need · Want →",
      swipeSpoken: right ? "Swipe left for Want, right for Need" : "Swipe left for Need, right for Want"
    )
  }

  static func projectsLine(_ active: Int) -> MoneyPhrase {
    MoneyPhrase(stringLiteral: active > 0 ? "\(active) active" : "None active")
  }

  static func accountsLine(_ count: Int, _ netWorth: HomeTotal) -> MoneyPhrase {
    guard count > 0 else { return "No accounts yet" }
    let style: MoneyStyle = netWorth.money.minor != 0 && netWorth.money.minor.magnitude < 100 ? .compact : .rounded
    return MoneyPhrase([
      .text("\(MoneyFormat.count(count)) account\(count == 1 ? "" : "s") · net worth "),
      .amount(netWorth.money, style, hidden: 4),
    ] + (netWorth.mark?.caption.map { [.text(" · \($0)")] } ?? []))
  }

  static func matchCount(_ r: Rule, _ s: LedgerState) -> Int {
    s.txns.filter { r.matches($0.merchant) || r.matches($0.provenance?.rawMerchant ?? "") }.count
  }

  struct MerchantKey: Hashable {
    let merchant: String
    let raw: String
  }

  static func matchCounts(_ s: LedgerState) -> [RuleID: Int] {
    var merchants: [MerchantKey: Int] = [:]
    for t in s.txns {
      merchants[MerchantKey(merchant: t.merchant, raw: t.provenance?.rawMerchant ?? ""), default: 0] += 1
    }
    var out: [RuleID: Int] = [:]
    for r in s.rules {
      out[r.id] = merchants.reduce(0) { n, e in
        n + (r.matches(e.key.merchant) || r.matches(e.key.raw) ? e.value : 0)
      }
    }
    return out
  }

  /// Rules, most used first, with match counts over every transaction.
  public static func rules(_ s: LedgerState) -> [RuleRowModel] {
    let counts = matchCounts(s)
    return s.rules.map { r in
      let n = counts[r.id] ?? 0
      let c = s.category(r.categoryID)
      let match = "\(r.match.label) · \(c?.name ?? "Uncategorized")"
      let matches = "\(MoneyFormat.count(n)) match\(n == 1 ? "" : "es")"
      let quoted = r.patterns.map { "\u{201C}\($0)\u{201D}" }
      return RuleRowModel(
        id: r.id,
        pattern: quoted.joined(separator: " or "), patterns: quoted,
        detail: "\(match) · \(matches)", match: match, matchesLabel: matches,
        glyph: c?.glyph ?? .review, hue: c?.hue ?? .other, enabled: r.enabled, learnedToday: r.learnedToday,
        matches: n
      )
    }.sorted { $0.matches > $1.matches }
  }
}

extension RuleRowModel {
  public func patternLine(showing shown: Int) -> String {
    let k = max(1, min(shown, patterns.count))
    let head = patterns.prefix(k).joined(separator: " or ")
    return k < patterns.count ? "\(head) +\(patterns.count - k) more" : head
  }
}
