// HasalaModel (Model/), spec 04 §2.2. Owner: WS-10 / WS-16. The only code
// importing FoundationModels: `CategoryModel` over the on-device
// `SystemLanguageModel` (spec 03c §8.6). Linked by the app only; nothing in
// L0-L4 depends on it.
//
// Only `SystemLanguageModel` (on device). The cloud model type the iOS 27 SDK
// also ships is never referenced (03c §8.6.1).
//
// Off by default when unavailable: `availability()` maps the SDK's answer, and
// the pipeline skips the tier for anything but `.available` (rows stay in
// review). One session per suggestion keeps calls independent and sequential;
// the pipeline (`ModelTier.run`) owns budgets, the Latin gate and dedup.
import CoreCategorize
import Foundation

#if canImport(FoundationModels)
  import FoundationModels

  public struct FoundationModelsCategoryModel: CategoryModel {
    public let modelTag: String

    /// `modelTag` defaults to the running OS's `apple-fm/<major>.<minor>`
    /// (03c §8.6.6): the on-device model ships with the OS, and the tag is
    /// part of the `fm_cache` key, so an OS update invalidates the cache.
    public init(modelTag: String = HasalaModelFactory.osModelTag()) {
      self.modelTag = modelTag
    }

    /// Greedy, at most 24 tokens (03c §8.6.4).
    static var options: GenerationOptions { .greedy(maximumResponseTokens: 24) }

    public func availability() -> ModelAvailability {
      let model = SystemLanguageModel(useCase: .general)
      switch model.availability {
      case .available:
        let english = model.supportedLanguages.contains { $0.languageCode?.identifier == "en" }
        return english ? .available : .unsupportedLanguage
      case .unavailable(let reason):
        switch reason {
        case .deviceNotEligible: return .notEligible
        case .appleIntelligenceNotEnabled: return .notEnabled
        case .modelNotReady: return .notReady
        @unknown default: return .notReady
        }
      }
    }

    public func suggest(subject: String, allowed: [AllowedCategory]) async -> ModelAnswer {
      guard !allowed.isEmpty else { return .unknown }
      do {
        let session = LanguageModelSession(
          model: SystemLanguageModel(useCase: .general), instructions: ModelTier.instructions(allowed))
        let choice = DynamicGenerationSchema(name: "CategoryId", anyOf: allowed.map(\.id) + ["unknown"])
        let root = DynamicGenerationSchema(name: "Answer", properties: [.init(name: "category", schema: choice)])
        let schema = try GenerationSchema(root: root, dependencies: [])
        let reply = try await session.respond(
          to: ModelTier.prompt(subject: subject), schema: schema, includeSchemaInPrompt: true,
          options: Self.options)
        let id: String = try reply.content.value(String.self, forProperty: "category")
        return allowed.contains { $0.id == id } ? .category(id) : .unknown
      } catch let error as LanguageModelSession.GenerationError {
        return .failed(ModelFailure(error))
      } catch is CancellationError {
        return .failed(.timeout)
      } catch {
        return .failed(.other)
      }
    }
  }

  extension GenerationOptions {
    /// The iOS 27 SDK renamed the label to `samplingMode:` and deprecated
    /// `sampling:`; the iOS 26 SDK (Xcode 26, Swift 6.3, which CI builds with)
    /// has only `sampling:`.
    static func greedy(maximumResponseTokens: Int) -> GenerationOptions {
      #if compiler(>=6.4)
        GenerationOptions(samplingMode: .greedy, maximumResponseTokens: maximumResponseTokens)
      #else
        GenerationOptions(sampling: .greedy, maximumResponseTokens: maximumResponseTokens)
      #endif
    }
  }

  extension ModelFailure {
    init(_ error: LanguageModelSession.GenerationError) {
      switch error {
      case .exceededContextWindowSize: self = .contextOverflow
      case .rateLimited: self = .rateLimited
      case .concurrentRequests: self = .busy
      case .guardrailViolation: self = .guardrail
      case .refusal: self = .refusal
      case .unsupportedLanguageOrLocale: self = .unsupportedLanguage
      case .assetsUnavailable: self = .assetsUnavailable
      case .decodingFailure: self = .decoding
      default: self = .other
      }
    }
  }
#endif

/// The model when FoundationModels cannot be used: always unavailable, so the
/// tier is skipped and rows stay in review.
public struct UnavailableCategoryModel: CategoryModel {
  public let modelTag = "none"
  public init() {}
  public func availability() -> ModelAvailability { .notEligible }
  public func suggest(subject: String, allowed: [AllowedCategory]) async -> ModelAnswer { .failed(.assetsUnavailable) }
}

public enum HasalaModelFactory {
  /// `apple-fm/<major>.<minor>` of the running OS (03c §8.6.6).
  public static func osModelTag(_ v: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> String {
    "apple-fm/\(v.majorVersion).\(v.minorVersion)"
  }

  /// The device's model, or the unavailable stand-in.
  public static func make() -> any CategoryModel {
    #if canImport(FoundationModels)
      return FoundationModelsCategoryModel()
    #else
      return UnavailableCategoryModel()
    #endif
  }
}
