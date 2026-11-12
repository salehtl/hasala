import HasalaDesign
import SwiftUI
import UIKit

/// The walls the live gate puts in front of everything (spec 04 §6.5): data on this
/// iPhone that the gate can't open, or that belongs to another account, a store that
/// failed to open, and a build the server no longer takes. On the account template (no
/// board draws them): the question, a note, and the ways out in the dock; removing the
/// data asks first in a system alert, as every loss does (page 14).
struct BootWallView: View {
  let boot: BootController
  let wall: BootController.Wall
  @State private var confirmingErase = false
  @Environment(\.openURL) private var openURL

  static let testFlightURL = URL(string: "itms-beta://")!
  static let testFlightWebURL = URL(string: "https://testflight.apple.com")!

  var body: some View {
    NavigationStack {
      AccountScreen(title: title, subtitle: Self.subtitle(for: wall)) {
        if let note = Self.note(for: wall) {
          NoteRow(icon: .phone, text: note)
        }
      } footer: {
        if wall == .updateRequired {
          BusyButton(title: "Open TestFlight", busy: false, identifier: "wall.testFlight") {
            openURL(Self.testFlightURL) { opened in
              if !opened { openURL(Self.testFlightWebURL) }
            }
          }
        }
        if offersTryAgain {
          BusyButton(
            title: "Try again", busy: false, kind: wall == .updateRequired ? .onGrouped : .primary,
            identifier: "wall.tryAgain"
          ) { boot.tryAgain() }
        }
        if offersErase {
          BusyButton(
            title: Self.eraseTitle(for: wall), busy: boot.erasing, kind: Self.eraseKind,
            identifier: "wall.erase"
          ) { confirmingErase = true }
          .padding(.top, offersTryAgain ? 8 : 0)
        }
        if case .otherAccount = wall {
          SecondaryLink(title: "Back", identifier: "wall.back") { boot.dismissWall() }
        } else {
          WebLink(title: "Talk to a person", url: "https://hasala.app/support", identifier: "wall.talk")
        }
      }
      .alert("Remove this iPhone's Hasala data?", isPresented: $confirmingErase) {
        Button("Cancel", role: .cancel) {}
        Button("Remove", role: .destructive) { Task { await boot.eraseThisIPhone() } }
          .accessibilityIdentifier("wall.erase.confirm")
      } message: {
        Text("Your account and everything you uploaded stay. \(Self.lostChanges)")
      }
    }
    .accessibilityIdentifier("wall.\(identifier)")
    // A field of the screen underneath may still hold the keyboard.
    .onAppear { UIApplication.shared.dismissKeyboard() }
  }

  private var identifier: String {
    switch wall {
    case .otherAccount: "otherAccount"
    case .foreignData: "foreignData"
    case .unenrolled: "unenrolled"
    case .restoring: "restoring"
    case .openFailed: "openFailed"
    case .updateRequired: "updateRequired"
    }
  }

  private var title: String {
    switch wall {
    case .otherAccount, .foreignData: "This iPhone holds another account's data"
    case .unenrolled: "Set up this iPhone again"
    case .restoring: "Your data isn't on this iPhone"
    case .openFailed: "Hasala couldn't open your data"
    case .updateRequired: "Update Hasala"
    }
  }

  static let eraseKind: PillButtonStyle.Kind = .destructiveQuiet

  static let lostChanges = "Changes not uploaded yet are lost."

  static func eraseTitle(for wall: BootController.Wall) -> String {
    wall == .unenrolled ? "Remove data and sign in again" : "Remove this iPhone's data"
  }

  static func subtitle(for wall: BootController.Wall) -> String {
    switch wall {
    case .otherAccount(let email):
      "The data here belongs to \(email ?? "another account"). To switch accounts, remove it first."
    case .foreignData:
      "It doesn't belong to the account signed in here, so Hasala won't open it."
    case .unenrolled:
      "This iPhone lost its key to your account."
    case .restoring:
      "Hasala's data didn't come back with this iPhone's backup. Signing in again downloads it."
    case .openFailed:
      "Something on this iPhone got in the way."
    case .updateRequired:
      "This version is out of date. Update Hasala in TestFlight, then open it again."
    }
  }

  static func note(for wall: BootController.Wall) -> String? {
    switch wall {
    case .otherAccount:
      "That account stays as it is. \(lostChanges)"
    case .unenrolled: lostChanges
    case .foreignData, .restoring:
      "Remove this iPhone's data, then sign in again. \(lostChanges)"
    case .openFailed:
      "Still failing? Remove this iPhone's data and sign in again. \(lostChanges)"
    case .updateRequired: nil
    }
  }

  private var offersTryAgain: Bool {
    switch wall {
    case .openFailed, .updateRequired: true
    default: false
    }
  }

  private var offersErase: Bool { wall != .updateRequired }
}
