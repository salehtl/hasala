import Foundation

/// How much of the app's unfinished surface this build shows.
///
/// A Release build shows only what works end to end: no placeholder screen, no "later
/// build" message, and no control whose destination isn't built yet (App Review
/// Guideline 2.1). Account actions are gated separately, by
/// `AccountSession.capabilities`.
///
/// Debug builds also show the unfinished parts, so they can be worked on, unless launched
/// with `-HasalaReleaseSurface`: the UI tests use it to walk what a Release build shows.
nonisolated enum BuildSurface {
  /// Whether screens offer placeholders and controls that lead to them.
  static let showsUnfinished: Bool = {
    #if DEBUG
      !ProcessInfo.processInfo.arguments.contains(releaseArgument)
    #else
      false
    #endif
  }()

  static let showsPlanTab: Bool = {
    #if DEBUG
      ProcessInfo.processInfo.arguments.contains(planTabArgument)
    #else
      false
    #endif
  }()

  #if DEBUG
    static let planTabArgument = "-HasalaPlanTab"
  #endif

  #if DEBUG
    /// The launch argument that gives a Debug build the Release surface.
    static let releaseArgument = "-HasalaReleaseSurface"
  #endif

  /// Where testers and reviewers write to (support@ is routed to the owner).
  static let showsCloudSuggestions: Bool = BuildInfo.assistBaseURL() != nil

  static let supportEmail = "support@hasala.app"
  static let supportMail = URL(string: "mailto:support@hasala.app")!
  /// The support page: how to reach us, for an iPhone where a mail link does nothing.
  static let supportPage = URL(string: "https://hasala.app/support")!
}
