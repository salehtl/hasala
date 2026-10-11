import HasalaModels
import Observation
import SwiftUI

/// App-wide UI state for the tab shell: what Home shows, Hide amounts (which applies
/// to every screen, spec 04 §12), the transient toast and the profile sheet.
///
/// For now the snapshot is the Maya mock (Debug only); the live source replaces it
/// once HasalaCore's projection exists (spec 04 §15.2). It imports no SwiftUI
/// types into its API beyond what views bind to.
@MainActor
@Observable
final class AppModel {
  struct Toast: Equatable {
    var systemImage: String
    var title: String
    var subtitle: String?
    var actionTitle: String?
  }

  private(set) var snapshot: HomeSnapshot
  private(set) var amountsHidden: Bool
  private(set) var toast: Toast?
  var showingProfile = false

  private var toastTask: Task<Void, Never>?

  init(snapshot: HomeSnapshot, amountsHidden: Bool = false) {
    self.snapshot = snapshot
    self.amountsHidden = amountsHidden
  }

  /// The header eye (Paper "Home · Amounts hidden"): hiding persists until it is toggled back; a
  /// toast confirms it and offers "Show".
  func toggleAmountsHidden() {
    amountsHidden.toggle()
    if amountsHidden {
      show(Toast(systemImage: "eye.slash", title: "Amounts hidden", subtitle: "Until you tap the eye again",
                 actionTitle: "Show"))
    } else {
      dismissToast()
    }
  }

  func toastAction() {
    if amountsHidden { toggleAmountsHidden() } else { dismissToast() }
  }

  func dismissToast() {
    toastTask?.cancel()
    toast = nil
  }

  private func show(_ t: Toast) {
    toastTask?.cancel()
    toast = t
    toastTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(5))
      guard !Task.isCancelled else { return }
      self?.toast = nil
    }
  }
}
