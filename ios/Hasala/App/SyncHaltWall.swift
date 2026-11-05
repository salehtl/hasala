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
      AccountScreen(title: Self.title, subtitle: Self.subtitle) {
        NoteRow(icon: .info, text: Self.reason(halt))
        NoteRow(icon: .phone, text: Self.next(halt))
        SupportCodeLine(lead: Self.codeLead, code: Self.code(halt), identifier: "wall.syncHalted.code")
      } footer: {
        BusyButton(title: "Try again", busy: retrying, identifier: "wall.tryAgain", action: tryAgain)
        SupportLink(lead: "Still stopped?", identifier: "wall.support")
      }
    }
    .accessibilityIdentifier("wall.syncHalted")
    .accessibilityAddTraits(.isModal)
    .onAppear { UIApplication.shared.dismissKeyboard() }
  }

  static let title = "Hasala stopped syncing"

  static var subtitle: String { kept }

  static let codeLead = "If you email us, mention:"

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
    case .unprovedRevocation:
      "Our server said this iPhone was removed from your account, but your account's device list doesn't show that, so Hasala stopped before anything was removed."
    case .unexpectedGone:
      "Our server gave an answer Hasala doesn't expect, so it stopped before anything got mixed up."
    case .updateRequired:
      "This version of Hasala can't read the newest changes in your account."
    }
  }

  static func next(_ halt: HaltKind) -> String {
    switch halt {
    case .updateRequired:
      "Install the newest build from TestFlight, then open Hasala again. If it stays stopped, email \(BuildSurface.supportEmail)."
    default:
      "Try again in a while. If it stays stopped, email \(BuildSurface.supportEmail)."
    }
  }

  static func code(_ halt: HaltKind) -> String {
    switch halt {
    case .tampered(let reason): "tampered.\(reason.rawValue)"
    case .tamperedResend: "tamperedResend"
    case .serverRestored: "serverRestored"
    case .inconsistent: "inconsistent"
    case .rosterInvalid: "rosterInvalid"
    case .unprovedRevocation: "unprovedRevocation"
    case .unexpectedGone: "unexpectedGone"
    case .updateRequired: "updateRequired"
    }
  }
}

struct SupportCodeLine: View {
  let lead: String
  let code: String
  let identifier: String
  @State private var copied = false

  var body: some View {
    HStack(alignment: .bottom, spacing: 12) {
      VStack(alignment: .leading, spacing: 8) {
        Text(lead)
          .hType(.footnote)
          .foregroundStyle(HColor.textSecondary)
        Text(verbatim: code)
          .font(.system(.footnote, design: .monospaced).weight(.medium))
          .foregroundStyle(HColor.textPrimary)
          .textSelection(.enabled)
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
          .background(HColor.surfaceSecondary, in: RoundedRectangle(cornerRadius: HRadius.control, style: .continuous))
      }
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier(identifier)
      Spacer(minLength: 0)
      Button(copied ? "Copied" : "Copy") {
        UIPasteboard.general.string = code
        copied = true
      }
      .buttonStyle(.inlineLink)
      .accessibilityLabel(copied ? "Copied" : "Copy code")
      .accessibilityIdentifier("\(identifier).copy")
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
