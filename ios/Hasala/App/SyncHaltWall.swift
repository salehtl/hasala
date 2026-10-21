import CoreSync
import HasalaDesign
import SwiftUI
import UIKit

struct SyncHaltWall: View {
  let halt: HaltKind
  let retrying: Bool
  let tryAgain: () -> Void

  var body: some View {
    NavigationStack {
      AccountScreen(title: Self.title, subtitle: Self.reason(halt)) {
        NoteRow(icon: .phone, text: Self.kept)
        NoteRow(icon: .info, text: Self.next(halt))
          .accessibilityIdentifier("wall.syncHalted.code")
      } footer: {
        BusyButton(title: "Try again", busy: retrying, identifier: "wall.tryAgain", action: tryAgain)
        SupportLink(lead: "Still stopped?", identifier: "wall.support")
      }
    }
    .accessibilityIdentifier("wall.syncHalted")
    .accessibilityAddTraits(.isModal)
    .onAppear { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
  }

  static let title = "Hasala stopped syncing"

  static let kept =
    "Everything on this iPhone is kept, including changes that haven't uploaded yet. Nothing is removed."

  static func reason(_ halt: HaltKind) -> String {
    switch halt {
    case .tampered, .tamperedResend:
      "What the server sent doesn't match what this iPhone already holds, so Hasala stopped before anything got mixed up."
    case .serverRestored:
      "Our server was restored from an earlier copy and is missing changes this iPhone holds, so Hasala stopped before they could be lost."
    case .inconsistent:
      "Some changes in your account don't fit together, so Hasala stopped before anything got mixed up."
    case .rosterInvalid:
      "Hasala couldn't confirm which devices belong to your account, so it stopped before anything got mixed up."
    case .updateRequired:
      "This version of Hasala can't read the newest changes in your account."
    }
  }

  static func next(_ halt: HaltKind) -> String {
    "Try again in a while. If it stays stopped, email \(BuildSurface.supportEmail) and mention the code \(code(halt))."
  }

  static func code(_ halt: HaltKind) -> String {
    switch halt {
    case .tampered(let reason): "tampered.\(reason.rawValue)"
    case .tamperedResend: "tamperedResend"
    case .serverRestored: "serverRestored"
    case .inconsistent: "inconsistent"
    case .rosterInvalid: "rosterInvalid"
    case .updateRequired: "updateRequired"
    }
  }
}
