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
          .infoTip(Self.reasonDetail(halt), about: "why syncing stopped")
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
    "Everything on this iPhone is kept, including changes not yet uploaded."

  static func reason(_ halt: HaltKind) -> String {
    switch halt {
    case .tampered, .tamperedResend:
      "The server's data doesn't match this iPhone's."
    case .serverRestored:
      "Our server was restored from an older copy that's missing changes this iPhone holds."
    case .inconsistent:
      "Some changes in your account don't fit together."
    case .rosterInvalid:
      "Hasala couldn't confirm your account's devices."
    case .unprovedRevocation:
      "Our server says this iPhone was removed; your device list disagrees."
    case .unexpectedGone:
      "Our server gave an unexpected answer."
    case .updateRequired:
      "This version can't read your newest changes."
    }
  }

  static let stoppedDetail =
    "Hasala checks everything it syncs, and stops rather than guess when something doesn't fit."

  static func reasonDetail(_ halt: HaltKind) -> String? {
    halt == .updateRequired ? nil : stoppedDetail
  }

  static func next(_ halt: HaltKind) -> String {
    switch halt {
    case .updateRequired:
      "Update Hasala in TestFlight, then open it again. Still stopped? Email \(BuildSurface.supportEmail)."
    default:
      "Try again later, or email \(BuildSurface.supportEmail)."
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
