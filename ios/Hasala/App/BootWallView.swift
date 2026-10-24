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

  var body: some View {
    NavigationStack {
      AccountScreen(title: title, subtitle: subtitle) {
        if let note {
          NoteRow(icon: .phone, text: note)
        }
      } footer: {
        if offersTryAgain {
          BusyButton(title: "Try again", busy: false, identifier: "wall.tryAgain") { boot.tryAgain() }
        }
        if offersErase {
          BusyButton(
            title: "Remove this iPhone's data", busy: boot.erasing, kind: offersTryAgain ? .onGrouped : .primary,
            identifier: "wall.erase"
          ) { confirmingErase = true }
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
        Text("Your account and everything already uploaded stay. Changes on this iPhone that haven't uploaded yet are lost.")
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
    case .unenrolled: "This iPhone needs to be set up again"
    case .restoring: "Your data isn't on this iPhone"
    case .openFailed: "Hasala couldn't open your data"
    case .updateRequired: "Update Hasala"
    }
  }

  private var subtitle: String {
    switch wall {
    case .otherAccount(let email):
      "Hasala on this iPhone still holds the data of \(email ?? "another account"). To use a different account here, remove that data first."
    case .foreignData:
      "The data on this iPhone doesn't belong to the account it's signed in to, so Hasala won't open it."
    case .unenrolled:
      "This iPhone's key for your account is missing, so it can't add changes any more."
    case .restoring:
      "Hasala's data didn't come back with this iPhone's backup. Start this iPhone again to download it."
    case .openFailed:
      "Something on this iPhone stopped Hasala from opening your account."
    case .updateRequired:
      "This version of Hasala is too old for the server. Install the newest build from TestFlight, then open Hasala again."
    }
  }

  private var note: String? {
    switch wall {
    case .otherAccount: "Your other account stays as it is. You can sign in to it again later, on this iPhone or another."
    case .foreignData, .unenrolled, .restoring:
      "Remove this iPhone's data, then sign in again. Everything you uploaded comes back."
    case .openFailed: "If it keeps happening, remove this iPhone's data and sign in again. Everything you uploaded comes back."
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
