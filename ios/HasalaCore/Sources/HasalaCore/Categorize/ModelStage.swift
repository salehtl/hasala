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

  public static func run(
    subjects: [String], stages: [ModelStage], allowed: [AllowedCategory], context: Context, now: @Sendable () -> Int64,
    callTimeout: Duration? = nil, isCached: @Sendable (_ subject: String, _ modelTag: String) -> Bool = { _, _ in false },
    mayLeaveDevice: @Sendable (String) -> Bool = { _ in true }
  ) async -> (
    suggestions: [StagedSuggestion], unknown: [(subject: String, modelTag: String)], stoppedBy: [String: ModelFailure],
    asked: [(subject: String, modelTag: String)], requests: Int
  ) {
    let budget = context.budget
    let limit = callTimeout ?? .milliseconds(budget.callMs)
    var live = stages.map { $0.model.availability() == .available }
    guard budget.calls > 0, live.contains(true), !allowed.isEmpty else { return ([], [], [:], [], 0) }
    let start = now()
    var seen: Set<String> = []
    var out: [StagedSuggestion] = []
    var unknown: [(subject: String, modelTag: String)] = []
    var stopped: [String: ModelFailure] = [:]
    var asked: [(subject: String, modelTag: String)] = []
    var calls = 0
    subjects: for subject in subjects where seen.insert(subject).inserted {
      for (i, stage) in stages.enumerated() where live[i] {
        let tag = stage.model.modelTag
        guard stage.accepts(subject), !stage.leavesDevice || mayLeaveDevice(subject), !isCached(subject, tag) else { continue }
        if calls >= budget.calls || now() - start >= budget.phaseMs || Task.isCancelled { break subjects }
        calls += 1
        asked.append((subject, tag))
        var reply = await graded(stage.model, subject: subject, allowed: allowed, within: limit)
        if reply.answer == .failed(.contextOverflow), calls < budget.calls {
          calls += 1
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
          case .rateLimited, .busy, .unsupportedLanguage, .assetsUnavailable, .notEnabled, .refused:
            live[i] = false
            stopped[tag] = f
            if !live.contains(true) { break subjects }
          default:
            continue
          }
        }
      }
    }
    return (out, unknown, stopped, asked, calls)
  }
}

public protocol ModelAnswerCache: Sendable {
  func isCached(subject: String, taxonomyHash: String, modelTag: String, now: Int64) throws -> Bool
  func recordUnknown(_ entries: [(subject: String, modelTag: String)], taxonomyHash: String, now: Int64) throws
}
