public struct ModelStage: Sendable {
  public let model: any CategoryModel
  public let accepts: @Sendable (String) -> Bool
  public let leavesDevice: Bool

  public init(model: any CategoryModel, accepts: @escaping @Sendable (String) -> Bool, leavesDevice: Bool = false) {
    self.model = model
    self.accepts = accepts
    self.leavesDevice = leavesDevice
  }

  public static func onDevice(_ model: any CategoryModel) -> ModelStage {
    ModelStage(model: model, accepts: LatinGate.passes)
  }

  public static func cloud(_ model: any CategoryModel) -> ModelStage {
    ModelStage(model: model, accepts: hasLetter, leavesDevice: true)
  }

  public static func hasLetter(_ subject: String) -> Bool {
    subject.unicodeScalars.contains { s in
      switch s.properties.generalCategory {
      case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: true
      default: false
      }
    }
  }
}

extension ModelTier {
  public struct StagedSuggestion: Sendable, Equatable {
    public let subject: String
    public let category: String
    public let modelTag: String
    public let autoFile: Bool

    public init(subject: String, category: String, modelTag: String, autoFile: Bool = false) {
      self.subject = subject
      self.category = category
      self.modelTag = modelTag
      self.autoFile = autoFile
    }
  }

  public typealias StagedRun = (
    suggestions: [StagedSuggestion], unknown: [(subject: String, modelTag: String)], stoppedBy: [String: ModelFailure],
    asked: [(subject: String, modelTag: String)], requests: Int, failed: [(subject: String, modelTag: String, failure: ModelFailure)],
    cloudRequests: Int
  )

  public static func stops(_ f: ModelFailure) -> Bool {
    switch f {
    case .rateLimited, .busy, .unsupportedLanguage, .assetsUnavailable, .notEnabled, .refused: true
    default: false
    }
  }

  public static func run(
    subjects: [String], stages: [ModelStage], allowed: [AllowedCategory], context: Context, now: @Sendable () -> Int64,
    callTimeout: Duration? = nil, isCached: @Sendable (_ subject: String, _ modelTag: String) -> Bool = { _, _ in false },
    mayLeaveDevice: @Sendable (String) -> Bool = { _ in true }, maxCalls: Int? = nil, maxCloudCalls: Int? = nil, concurrency: Int = 1
  ) async -> StagedRun {
    let budget = context.budget
    let callCap = min(budget.calls, maxCalls ?? budget.calls)
    let cloudCap = max(0, maxCloudCalls ?? Int.max)
    let limit = callTimeout ?? .milliseconds(budget.callMs)
    var live = stages.map { $0.model.availability() == .available && (!$0.leavesDevice || cloudCap > 0) }
    guard callCap > 0, live.contains(true), !allowed.isEmpty else { return ([], [], [:], [], 0, [], 0) }
    if concurrency > 1, stages.count == 1 {
      return await concurrent(
        subjects: subjects, stage: stages[0], allowed: allowed, callCap: stages[0].leavesDevice ? min(callCap, cloudCap) : callCap,
        phaseMs: budget.phaseMs, limit: limit, now: now, isCached: isCached, mayLeaveDevice: mayLeaveDevice, width: concurrency)
    }
    let start = now()
    var seen: Set<String> = []
    var out: [StagedSuggestion] = []
    var unknown: [(subject: String, modelTag: String)] = []
    var stopped: [String: ModelFailure] = [:]
    var asked: [(subject: String, modelTag: String)] = []
    var failed: [(subject: String, modelTag: String, failure: ModelFailure)] = []
    var calls = 0
    var cloudCalls = 0
    subjects: for subject in subjects where seen.insert(subject).inserted {
      for (i, stage) in stages.enumerated() where live[i] {
        let tag = stage.model.modelTag
        guard stage.accepts(subject), !stage.leavesDevice || mayLeaveDevice(subject), !isCached(subject, tag) else { continue }
        if stage.leavesDevice, cloudCalls >= cloudCap { continue }
        if calls >= callCap || now() - start >= budget.phaseMs || Task.isCancelled { break subjects }
        calls += 1
        if stage.leavesDevice { cloudCalls += 1 }
        asked.append((subject, tag))
        var reply = await graded(stage.model, subject: subject, allowed: allowed, within: limit)
        if reply.answer == .failed(.contextOverflow), calls < callCap, !stage.leavesDevice || cloudCalls < cloudCap {
          calls += 1
          if stage.leavesDevice { cloudCalls += 1 }
          reply = await graded(stage.model, subject: subject, allowed: allowed, within: limit)
        }
        switch reply.answer {
        case .category(let id) where allowed.contains(where: { $0.id == id }):
          out.append(StagedSuggestion(subject: subject, category: id, modelTag: tag, autoFile: reply.autoFile))
          continue subjects
        case .category, .unknown:
          unknown.append((subject, tag))
        case .failed(let f):
          switch f {
          case .guardrail, .refusal:
            unknown.append((subject, tag))
          default:
            failed.append((subject, tag, f))
            guard stops(f) else { continue }
            live[i] = false
            stopped[tag] = f
            if !live.contains(true) { break subjects }
          }
        }
      }
    }
    return (out, unknown, stopped, asked, calls, failed, cloudCalls)
  }

  static func concurrent(
    subjects: [String], stage: ModelStage, allowed: [AllowedCategory], callCap: Int, phaseMs: Int64, limit: Duration,
    now: @Sendable () -> Int64, isCached: @Sendable (String, String) -> Bool, mayLeaveDevice: @Sendable (String) -> Bool, width: Int
  ) async -> StagedRun {
    let model = stage.model
    let tag = model.modelTag
    var seen: Set<String> = []
    let queue = subjects.filter { s in
      seen.insert(s).inserted && stage.accepts(s) && (!stage.leavesDevice || mayLeaveDevice(s)) && !isCached(s, tag)
    }
    let start = now()
    var out: [StagedSuggestion] = []
    var unknown: [(subject: String, modelTag: String)] = []
    var stopped: [String: ModelFailure] = [:]
    var asked: [(subject: String, modelTag: String)] = []
    var failed: [(subject: String, modelTag: String, failure: ModelFailure)] = []
    var calls = 0
    var next = 0
    await withTaskGroup(of: (subject: String, reply: Graded, retry: Bool).self) { group in
      var inFlight = 0
      func launch() -> Bool {
        guard stopped.isEmpty, next < queue.count, calls < callCap, now() - start < phaseMs, !Task.isCancelled else { return false }
        let subject = queue[next]
        next += 1
        calls += 1
        asked.append((subject, tag))
        group.addTask { (subject, await graded(model, subject: subject, allowed: allowed, within: limit), false) }
        inFlight += 1
        return true
      }
      while inFlight < width, launch() {}
      while let r = await group.next() {
        inFlight -= 1
        if r.reply.answer == .failed(.contextOverflow), !r.retry, calls < callCap, !Task.isCancelled {
          calls += 1
          let subject = r.subject
          group.addTask { (subject, await graded(model, subject: subject, allowed: allowed, within: limit), true) }
          inFlight += 1
          continue
        }
        switch r.reply.answer {
        case .category(let id) where allowed.contains(where: { $0.id == id }):
          out.append(StagedSuggestion(subject: r.subject, category: id, modelTag: tag, autoFile: r.reply.autoFile))
        case .category, .unknown:
          unknown.append((r.subject, tag))
        case .failed(let f):
          switch f {
          case .guardrail, .refusal:
            unknown.append((r.subject, tag))
          default:
            failed.append((r.subject, tag, f))
            if stops(f), stopped[tag] == nil { stopped[tag] = f }
          }
        }
        while inFlight < width, launch() {}
      }
    }
    return (out, unknown, stopped, asked, calls, failed, stage.leavesDevice ? calls : 0)
  }
}

public enum CachedAnswer: Sendable, Equatable {
  case unknown
  case category(String, autoFile: Bool)
}

public protocol ModelAnswerCache: Sendable {
  func answer(subject: String, taxonomyHash: String, modelTag: String, now: Int64) throws -> CachedAnswer?
  func recordUnknown(_ entries: [(subject: String, modelTag: String)], taxonomyHash: String, now: Int64) throws
  func recordAnswers(_ entries: [ModelTier.StagedSuggestion], taxonomyHash: String, now: Int64) throws
}

extension ModelAnswerCache {
  public func isCached(subject: String, taxonomyHash: String, modelTag: String, now: Int64) throws -> Bool {
    try answer(subject: subject, taxonomyHash: taxonomyHash, modelTag: modelTag, now: now) != nil
  }
}
