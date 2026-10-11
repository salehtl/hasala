// Unit tests for CoreCategorize: the bundled dictionary, decide (03c §8.2),
// the sweep (§8.4, pipe-01..06), learned patterns (§5.4), the Latin gate
// (§8.6.2) and the model tier's budgets (§8.6.3). The v3 matcher is pinned by
// conformance/categorize.
import Foundation
import Synchronization
import Testing

@testable import CoreCategorize

struct Table: CategoryLookup {
  var retired: [String] = []
  func info(_ id: String) -> CategoryInfo? {
    guard let b = TaxonomyV1.builtin(id) else { return nil }
    return CategoryInfo(id: b.id, name: b.name, kind: b.kind, bucket: b.bucket, icon: b.icon, active: !retired.contains(id), builtin: true, sortKey: b.sortKey)
  }
}

@Suite("CoreCategorize")
struct CoreCategorizeTests {
  static let dictionary = try! MerchantDictionary.bundled().get()

  @Test("dict-01: the bundled dictionary loads clean against its manifest")
  func bundled() {
    #expect(Self.dictionary.bundle == DictionaryManifest.bundle)
    #expect(Self.dictionary.entries.count == DictionaryManifest.entries)
    #expect(Self.dictionary.defects.isEmpty)
  }

  @Test("dict-02/03/04: digest mismatch disables; regex and income entries refused")
  func dictionaryRefusals() {
    let doc = #"{"format":"hasala.merchant-dictionary","format_version":1,"bundle":"2026.10.11-1","taxonomy":1,"entries":[{"m":"regex","p":"^x","c":"dining"},{"m":"contains","p":"acme","c":"salary"},{"m":"contains","p":"ACME","c":"dining"},{"m":"contains","p":"acme","c":"dining"}]}"#
    let bytes = Array(doc.utf8)
    #expect(MerchantDictionary.load(bytes, expectedSHA256: String(repeating: "0", count: 64)) == .failure(.digestMismatch))
    let d = try! MerchantDictionary.load(bytes, expectedSHA256: nil).get()
    #expect(d.entries.count == 1)
    #expect(d.defects.map(\.code) == ["regex_not_allowed", "category_not_spending", "pattern_not_canonical"])
  }

  @Test("decide: rule beats dictionary, retired categories skipped, credit gate suggests")
  func decide() {
    let rules = [RuleInput(id: "01JC0000000000000000000004", patterns: ["carrefour"], match: "contains", category: "shopping", priority: 10)]
    let c = Categorizer(rules: rules, dictionary: Self.dictionary, categories: Table())
    #expect(c.decide(merchantRaw: "CARREFOUR MOE", direction: .debit).source == .rule(id: "01JC0000000000000000000004"))
    let d = c.decide(merchantRaw: "TALABAT DUBAI", direction: .debit)
    #expect(d.category == "dining")
    #expect(d.source == .dictionary(bundle: DictionaryManifest.bundle, entry: "contains:talabat"))
    #expect(d.display == "talabat")
    let credit = c.decide(merchantRaw: "TALABAT DUBAI", direction: .credit)
    #expect(credit.category == nil && credit.source == .none && credit.suggested == "dining")
    let retired = Categorizer(rules: rules, dictionary: Self.dictionary, categories: Table(retired: ["shopping"]))
    #expect(retired.decide(merchantRaw: "CARREFOUR MOE", direction: .debit).category == "groceries")
    #expect(retired.prepared.defects.contains(Defect(id: "01JC0000000000000000000004", code: "category_retired")))
    #expect(c.decide(merchantRaw: "   ", direction: .debit) == .none)
    #expect(c.decide(merchantRaw: "كارفور السيف", direction: .debit).category == "groceries")
  }

  @Test("pipe-02..06: the sweep re-files, never un-files, leaves user and held rows alone, keeps needs_review")
  func sweep() {
    let rules = [RuleInput(id: "01JC0000000000000000000004", patterns: ["spinneys"], match: "contains", category: "dining", priority: 10)]
    let c = Categorizer(rules: rules, dictionary: Self.dictionary, categories: Table())
    func row(_ id: String, _ m: String, _ cat: String?, _ k: SweepRow.SourceKind, ref: String? = nil, nr: Bool = true, dir: Direction = .debit)
      -> SweepRow
    {
      SweepRow(id: id, merchantRaw: m, direction: dir, category: cat, sourceKind: k, sourceRef: ref, needsReview: nr, candidate: true)
    }
    let rows = [
      row("a", "SPINNEYS JLT", "groceries", .dictionary, ref: "x"),  // re-filed by the rule
      row("b", "SPINNEYS JLT", "groceries", .user),  // user: untouched
      row("c", "SPINNEYS JLT", "groceries", .held, ref: "r"),  // held: untouched
      row("d", "UNKNOWN SHOP 42", "shopping", .dictionary, ref: "x"),  // no decision: never un-filed
      row("e", "UNKNOWN SHOP 42", nil, .none),  // model queue
      row("f", "CARREFOUR", "groceries", .dictionary, ref: "\(DictionaryManifest.bundle)|contains:carrefour", nr: false),  // unchanged
      row("g", "UNKNOWN SHOP 42", nil, .none, dir: .credit),  // credits never queue
    ]
    let (actions, queue) = Sweep.plan(rows, c)
    #expect(actions == [SweepAction(txnID: "a", category: "dining", source: .rule(id: "01JC0000000000000000000004"), needsReview: true)])
    #expect(queue.map(\.id) == ["e"])
  }

  @Test("learned patterns: the 03c §5.4 examples, the floors and the overreach guard")
  func learned() {
    #expect(LearnedPattern.propose(merchantRaw: "LULU HYPERMARKET DXB MARINA", category: "groceries")! == (.contains, "lulu"))
    #expect(LearnedPattern.propose(merchantRaw: "CARREFOUR MALL OF EMIRATES", category: "groceries")! == (.contains, "carrefour"))
    #expect(LearnedPattern.propose(merchantRaw: "DU TELECOM 0423", category: "utilities")! == (.startsWith, "du telecom"))
    #expect(LearnedPattern.propose(merchantRaw: "7-11", category: "groceries")! == (.startsWith, "7-11"))
    #expect(LearnedPattern.propose(merchantRaw: "X", category: "groceries") == nil)
    #expect(LearnedPattern.propose(merchantRaw: "AB", category: "groceries")! == (.exact, "ab"))
    let guarded = LearnedPattern.propose(
      merchantRaw: "CARREFOUR MALL OF EMIRATES", category: "groceries", userRows: [("CARREFOUR ELECTRONICS", "shopping")])
    #expect(guarded! == (.exact, "carrefour mall of emirates"))
  }

  @Test("latin.json subset: the gate passes Latin merchants only")
  func latin() {
    for s in ["talabat", "café de flore", "carrefour 24", "noon.com", "starbucks difc", "zara"] { #expect(LatinGate.passes(s), "\(s)") }
    for s in ["كارفور", "٧-١١", "ab", "pizza 🍕", "talabat كارفور", "12345"] { #expect(!LatinGate.passes(s), "\(s)") }
  }

  @Test("model tier: allowed set, prompt, budget and refusal handling")
  func modelTier() async {
    let infos = TaxonomyV1.builtins
    let allowed = ModelTier.allowed(infos)
    #expect(allowed.map(\.id) == ["rent", "utilities", "groceries", "transport", "healthcare", "insurance", "dining", "entertainment", "shopping", "travel", "subscriptions"])
    #expect(ModelTier.instructions(allowed).contains("- groceries: Groceries (supermarkets and grocery stores)"))
    #expect(ModelTier.prompt(subject: "café  de flore") == "Merchant: caf de flore")

    final class Fake: CategoryModel, @unchecked Sendable {
      let calls = Mutex(0)
      let modelTag = "apple-fm/26.1"
      func availability() -> ModelAvailability { .available }
      func suggest(subject: String, allowed: [AllowedCategory]) async -> ModelAnswer {
        calls.withLock { $0 += 1 }
        if subject.hasPrefix("zuma") { return .category("dining") }
        if subject.hasPrefix("weird") { return .category("salary") }
        return .unknown
      }
    }
    let fake = Fake()
    let r = await ModelTier.run(
      subjects: ["zuma", "zuma", "weird place", "كارفور", "mystery shop"], model: fake, allowed: allowed, context: .foreground,
      now: { 0 })
    #expect(r.suggestions == [ModelTier.Suggestion(subject: "zuma", category: "dining")])
    #expect(r.unknown == ["weird place", "mystery shop"])
    #expect(fake.calls.withLock { $0 } == 3)
    let none = await ModelTier.run(subjects: ["zuma"], model: fake, allowed: allowed, context: .refresh, now: { 0 })
    #expect(none.suggestions.isEmpty)
    #expect(ModelTier.cacheKey(subject: "zuma", taxonomyHash: ModelTier.taxonomyHash(allowed), modelTag: fake.modelTag).utf8.count == 64)
  }

  @Test("learned patterns over 128 scalars hide the toggle (03c §5.1)")
  func learnedTooLong() {
    #expect(LearnedPattern.propose(merchantRaw: String(repeating: "A", count: 129), category: "groceries") == nil)
    #expect(LearnedPattern.propose(merchantRaw: String(repeating: "A", count: 128), category: "groceries")?.pattern.unicodeScalars.count == 128)
    // The overreach guard's exact fallback is the whole subject: too long, nil.
    let long = "LULU " + String(repeating: "X", count: 200)
    #expect(LearnedPattern.propose(merchantRaw: long, category: "groceries", userRows: [("LULU EXCHANGE", "shopping")]) == nil)
  }

  @Test("model tier: a hung call times out and is skipped; a context overflow is retried once")
  func modelTimeouts() async {
    let allowed = ModelTier.allowed(TaxonomyV1.builtins)
    final class Hangs: CategoryModel, @unchecked Sendable {
      let calls = Mutex([String: Int]())
      /// The hung call answered (it never should before the sweep returns).
      let hangAnswered = Mutex(false)
      let modelTag = "apple-fm/26.1"
      func availability() -> ModelAvailability { .available }
      func suggest(subject: String, allowed: [AllowedCategory]) async -> ModelAnswer {
        let n = calls.withLock { c -> Int in
          c[subject, default: 0] += 1
          return c[subject]!
        }
        switch subject {
        case "hang forever":
          // Ignores cancellation and answers much later: the tier must not wait for it.
          await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + 60) { k.resume() }
          }
          hangAnswered.withLock { $0 = true }
          return .category("shopping")
        case "overflow once": return n == 1 ? .failed(.contextOverflow) : .category("dining")
        case "overflow twice": return .failed(.contextOverflow)
        default: return .category("groceries")
        }
      }
    }
    let m = Hangs()
    let clock = ContinuousClock()
    let started = clock.now
    let r = await ModelTier.run(
      subjects: ["hang forever", "overflow once", "overflow twice", "spinneys"], model: m, allowed: allowed, context: .foreground, now: { 0 },
      callTimeout: .milliseconds(200))
    // Load-independent: the sweep returned while the hung call was still
    // pending (a wall-clock bound on a 200 ms limit is flaky on a busy runner).
    #expect(!m.hangAnswered.withLock { $0 })
    #expect(clock.now - started < .seconds(60))
    #expect(r.suggestions == [.init(subject: "overflow once", category: "dining"), .init(subject: "spinneys", category: "groceries")])
    #expect(r.unknown.isEmpty && r.stoppedBy == nil)
    #expect(m.calls.withLock { $0 } == ["hang forever": 1, "overflow once": 2, "overflow twice": 2, "spinneys": 1])
    #expect(ModelTier.Context.foreground.budget.callMs == 6_000)
  }
}
