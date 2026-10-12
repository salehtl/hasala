import CoreAuth
import CoreDomain
import CoreMailbox
import CoreReplay
import CoreSync
import CoreTime
import Foundation

/// The setup steps' ops (spec 04 §6.6 "When ops are authored") over the open account:
/// each call is one blob through `OpAuthor` under the account's shared stamps, one
/// `Outbox.enqueue`, then a re-projection; the outbox's trigger uploads it.
///
///   - bank:   `bank_declared` and `sender_trust_set` for each bank's alert senders
///   - "Another bank? Tell us": #74 with `source: "app"` (the name only)
///   - income and plan: `income_source_set`, `budget_split_set` and the seeded
///     `budget_set`s, in one blob
@MainActor
final class LiveSetupAuthoring: SetupAuthoring {
  private let runtime: @MainActor () -> AccountRuntime?

  init(runtime: @escaping @MainActor () -> AccountRuntime?) {
    self.runtime = runtime
  }

  private func open() throws(SetupFailure) -> AccountRuntime {
    guard let rt = runtime() else { throw .failed("Hasala is still opening your account. Try again in a moment.") }
    return rt
  }

  func chooseBanks(_ banks: [SupportedBank]) async throws(SetupFailure) {
    let rt = try open()
    var trusted = BankDomains.effectiveTrusted((try? rt.projection.reader.senderTrust()) ?? [:])
    var domains: [String] = []
    for bank in banks {
      for d in GmailLane.senderDomains(bank: bank.rawValue) where !domains.contains(d) { domains.append(d) }
    }
    try await author(rt) { a throws(AuthorError) in
      for bank in banks { a.declareBank(bank.rawValue, active: true) }
      for d in domains where !trusted.contains(d) {
        try a.setSenderTrust(typed: d, trusted: true, currentTrusted: trusted)
        trusted.append(d)
      }
    }
  }

  func requestBank(_ name: String) async throws(SetupFailure) {
    let rt = try open()
    guard let token = try? rt.env.secrets.session()?.token else { throw .failed("You're signed out. Sign in again.") }
    do {
      try await rt.env.client.bankRequest(bank: "other", otherBank: name, bearer: token)
    } catch {
      if case .transport = error { throw .offline }
      throw .failed("Couldn't send that just now. Try again later.")
    }
  }

  func savePlan(income: Int64?, payday: Int?, plan: StartingPlan?) async throws(SetupFailure) {
    let rt = try open()
    let now = rt.context.clock.nowMs()
    guard let month = LocalClock.localMonth(now) else { throw .failed("The date is out of range.") }
    try await author(rt) { a throws(AuthorError) in
      if let income {
        a.setIncomeSource(id: "salary", name: "Salary", amountMinor: income, payday: Int64(payday ?? 28))
      }
      if let plan, plan.isValid {
        try a.setBudgetTemplate(
          need: Int64(plan.needsPercent), want: Int64(plan.wantsPercent), saving: Int64(plan.savingsPercent))
        if let income {
          a.seedPlan(
            income: income,
            split: BudgetSplit(
              need: Int64(plan.needsPercent), want: Int64(plan.wantsPercent), saving: Int64(plan.savingsPercent)),
            month: month)
        }
      }
    }
  }

  /// One blob: built, enqueued (durable), re-projected, and the screens reloaded.
  private func author(_ rt: AccountRuntime, _ body: (inout OpAuthor) throws(AuthorError) -> Void)
    async throws(SetupFailure)
  {
    do {
      let ctx = try await rt.observer.authorContext()
      guard let blob = try rt.observer.stamps.build(ctx, body) else { return }
      try await rt.outbox.enqueue(blob.ops)
      try await rt.observer.reproject()
    } catch {
      throw .failed("Couldn't save that. Try again.")
    }
    await rt.store.reload()
  }
}
