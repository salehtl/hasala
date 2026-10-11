// The Foundation Models tier, core side (spec 03c §8.6; 04 §8). The core sees
// only the `CategoryModel` protocol; the `HasalaModel` target implements it over
// `SystemLanguageModel` and is linked by the app only.
//
// The tier SUGGESTS: its answer becomes a `txn_categorized {source: model}`
// with `needs_review` unchanged, so a suggestion never counts in a total until
// a person confirms it (`MODEL_AUTO_CONFIRM = false`). It runs only on debits
// with no category, Latin-gated subjects, one call per distinct subject, within
// the context's budget, and never in a background refresh or a push wake.
import CorePrimitives
import Foundation
import HasalaText
import Synchronization

public enum ModelAvailability: String, Sendable, Equatable {
  case available, notEligible, notEnabled, notReady, unsupportedLanguage
}

public enum ModelFailure: String, Sendable, Equatable {
  case timeout, guardrail, refusal, rateLimited, busy, contextOverflow, assetsUnavailable, decoding, unsupportedLanguage, other
}

public enum ModelAnswer: Sendable, Equatable {
  case category(String)
  case unknown
  case failed(ModelFailure)
}

/// One category the model may answer with (03c §8.6.4).
public struct AllowedCategory: Sendable, Equatable {
  public let id: String
  public let name: String
  public let hint: String?

  public init(id: String, name: String, hint: String?) {
    self.id = id
    self.name = name
    self.hint = hint
  }
}

/// The model, behind a protocol (spec 04 §2.4 R1). Implemented by `HasalaModel`.
public protocol CategoryModel: Sendable {
  func availability() -> ModelAvailability
  /// `allowed` is the whole set; the answer is one of its ids or `.unknown`.
  func suggest(subject: String, allowed: [AllowedCategory]) async -> ModelAnswer
  /// `apple-fm/<major>.<minor>`, the `source.model` tag (03c §3.2.1).
  var modelTag: String { get }
}

public enum ModelTier {
  /// 03c §8.6.6: a model suggestion never auto-confirms. Flipping it is a spec change.
  public static let autoConfirm = false

  public enum Context: Sendable {
    case foreground, processing, refresh

    /// (max calls, phase budget ms, per-call ms) of 03c §8.6.3.
    public var budget: (calls: Int, phaseMs: Int64, callMs: Int64) {
      switch self {
      case .foreground: (40, 20_000, 6_000)
      case .processing: (200, 120_000, 6_000)
      case .refresh: (0, 0, 0)
      }
    }
  }

  /// The allowed set: active spending categories in need or want, in `ord` order.
  public static func allowed(_ categories: [CategoryInfo]) -> [AllowedCategory] {
    categories
      .filter { $0.active && $0.kind == .spending && ($0.bucket == .need || $0.bucket == .want) }
      .sorted { $0.sortKey != $1.sortKey ? $0.sortKey < $1.sortKey : compareUTF8($0.id, $1.id) < 0 }
      .map { c in
        AllowedCategory(id: c.id, name: c.name, hint: c.builtin ? TaxonomyV1.modelHints.first { $0.id == c.id }?.hint : nil)
      }
  }

  /// The instructions, verbatim (03c §8.6.4), then one line per allowed category.
  public static func instructions(_ allowed: [AllowedCategory]) -> String {
    var lines = [
      "You sort card payments made in the United Arab Emirates into budget categories.",
      "You are given one merchant name as printed by a bank.",
      "Choose the single category that best fits what is usually bought there.",
      "If you do not know the merchant, or it could fit several categories, choose unknown.",
      "Categories:",
    ]
    for a in allowed {
      lines.append(a.hint.map { "- \(a.id): \(a.name) (\($0))" } ?? "- \(a.id): \(a.name)")
    }
    return lines.joined(separator: "\n")
  }

  /// `Merchant: <s>`: the subject cut to 64 scalars, every scalar outside
  /// 0020-007E replaced by a space, runs collapsed. No other row data.
  public static func prompt(subject: String) -> String {
    var out = String.UnicodeScalarView()
    var lastSpace = false
    for s in truncateRunes(subject, 64).unicodeScalars {
      let c: Unicode.Scalar = (0x20...0x7E).contains(s.value) ? s : " "
      if c == " " {
        if lastSpace { continue }
        lastSpace = true
      } else {
        lastSpace = false
      }
      out.append(c)
    }
    return "Merchant: " + String(out).trimming(.asciiSpace)
  }

  /// `hasala/v1/category-taxonomy` hash of the allowed list (03c §1.10).
  public static func taxonomyHash(_ allowed: [AllowedCategory]) -> String {
    var text = "["
    for (i, a) in allowed.enumerated() {
      if i > 0 { text += "," }
      text += "\"\(a.id)\""
    }
    text += "]"
    return domainHash("hasala/v1/category-taxonomy", [Array(text.utf8)])
  }

  /// `fm_cache` key (03c §8.6.7).
  public static func cacheKey(subject: String, taxonomyHash: String, modelTag: String) -> String {
    domainHash("hasala/v1/fm-cache", [Array(subject.utf8), Array(taxonomyHash.utf8), Array(modelTag.utf8)])
  }

  static func domainHash(_ domain: String, _ fields: [[UInt8]]) -> String {
    var bytes = Array(domain.utf8)
    for f in fields {
      bytes.append(0)
      bytes += f
    }
    return Hex.encode(sha256(bytes))
  }

  /// One suggestion to author.
  public struct Suggestion: Sendable, Equatable {
    public let subject: String
    public let category: String
  }

  /// Asks the model about each distinct subject, in order, within `context`'s
  /// budget. `now` is a millisecond clock for the phase budget. Answers that
  /// are not in the allowed set read as unknown. Returns the suggestions and
  /// the subjects answered `unknown` (to cache for 30 days).
  ///
  /// Each call races the per-call limit (03c §8.6.3, 6 s; `callTimeout`
  /// overrides it in tests): a call still running then is cancelled and its
  /// row skipped, not cached (§8.6.5). `exceededContextWindowSize` is retried
  /// once (the model opens a fresh session for every call).
  public static func run(
    subjects: [String], model: any CategoryModel, allowed: [AllowedCategory], context: Context, now: @Sendable () -> Int64,
    callTimeout: Duration? = nil
  ) async -> (suggestions: [Suggestion], unknown: [String], stoppedBy: ModelFailure?) {
    let budget = context.budget
    let limit = callTimeout ?? .milliseconds(budget.callMs)
    guard budget.calls > 0, model.availability() == .available, !allowed.isEmpty else { return ([], [], nil) }
    let start = now()
    var seen: Set<String> = []
    var out: [Suggestion] = []
    var unknown: [String] = []
    var calls = 0
    for subject in subjects where LatinGate.passes(subject) && seen.insert(subject).inserted {
      if calls >= budget.calls || now() - start >= budget.phaseMs { break }
      calls += 1
      var answer = await suggest(model, subject: subject, allowed: allowed, within: limit)
      if answer == .failed(.contextOverflow) {
        answer = await suggest(model, subject: subject, allowed: allowed, within: limit)
      }
      switch answer {
      case .category(let id) where allowed.contains(where: { $0.id == id }):
        out.append(Suggestion(subject: subject, category: id))
      case .category, .unknown:
        unknown.append(subject)
      case .failed(let f):
        switch f {
        case .guardrail, .refusal: unknown.append(subject)
        case .rateLimited, .busy, .unsupportedLanguage, .assetsUnavailable: return (out, unknown, f)
        default: continue
        }
      }
    }
    return (out, unknown, nil)
  }

  /// One model call, cancelled after `limit` (or when the sweep's task is
  /// cancelled). Returns `.failed(.timeout)` without waiting for a call that
  /// ignores cancellation.
  static func suggest(_ model: any CategoryModel, subject: String, allowed: [AllowedCategory], within limit: Duration) async -> ModelAnswer {
    let race = Race()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { (k: CheckedContinuation<ModelAnswer, Never>) in
        race.start(
          k,
          call: Task { race.finish(await model.suggest(subject: subject, allowed: allowed)) },
          timer: Task {
            try? await Task.sleep(for: limit)
            race.finish(.failed(.timeout))
          })
      }
    } onCancel: {
      race.finish(.failed(.timeout))
    }
  }

  /// A call against its deadline: the first `finish` resumes the caller and
  /// cancels both tasks; later ones do nothing.
  private final class Race: Sendable {
    private struct Inner {
      var k: CheckedContinuation<ModelAnswer, Never>?
      var tasks: [Task<Void, Never>] = []
      var done: ModelAnswer?
    }
    private let inner = Mutex(Inner())

    func start(_ k: CheckedContinuation<ModelAnswer, Never>, call: Task<Void, Never>, timer: Task<Void, Never>) {
      let early: ModelAnswer? = inner.withLock { i in
        if let d = i.done { return d }
        i.k = k
        i.tasks = [call, timer]
        return nil
      }
      if let early {
        call.cancel()
        timer.cancel()
        k.resume(returning: early)
      }
    }

    func finish(_ a: ModelAnswer) {
      let (k, tasks) = inner.withLock { i -> (CheckedContinuation<ModelAnswer, Never>?, [Task<Void, Never>]) in
        guard i.done == nil else { return (nil, []) }
        i.done = a
        defer {
          i.k = nil
          i.tasks = []
        }
        return (i.k, i.tasks)
      }
      for t in tasks { t.cancel() }
      k?.resume(returning: a)
    }
  }
}
