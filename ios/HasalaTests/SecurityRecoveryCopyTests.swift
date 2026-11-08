import CoreAuth
import Foundation
import HasalaModels
import SwiftUI
import Testing
import UIKit

@testable import Hasala

@MainActor
@Suite("Security and recovery copy")
struct SecurityRecoveryCopyTests {
  @Test func aFreezeTheHolderCannotLiftOffersOnlyAPerson() {
    let needsUs = FreezeInfo(by: .holder, when: nil, holderCanLift: false)
    #expect(FrozenWall.subtitle(needsUs).contains("only we can lift it"))
    #expect(!FrozenWall.subtitle(needsUs).contains("unfreeze"))
    #expect(FrozenWall.subtitle(FreezeInfo(by: .holder, when: nil)) == FrozenWall.holderBody(FreezeInfo(by: .holder, when: nil)))
    #expect(FrozenWall.subtitle(FreezeInfo(by: .operator, when: nil)).hasPrefix("We froze your account"))
    #expect(SecurityView.frozenBody(needsUs, canUnfreeze: true) == "Only we can lift this freeze. Talk to us to unfreeze it.")
    #expect(SecurityView.frozenBody(FreezeInfo(by: .holder, when: nil), canUnfreeze: true)
      == "Your account is frozen. Confirm it's you to unfreeze it.")
  }

  @Test func theWallTellsAPersonUnderAttackToSecureTheirEmailFirst() {
    #expect(FrozenWall.notYouNote.contains("Change your email's password first. Then unfreeze"))
    #expect(!FrozenWall.holderBody(FreezeInfo(by: .holder, when: nil)).contains("Nobody can sign in"))
  }

  @Test func aPasskeyOnlyAccountIsNotOfferedAPassword() {
    #expect(FrozenWall.unfreezeDetail(FreezeInfo(by: .holder, when: nil, hasPassword: false)) == "Your passkey.")
    #expect(FrozenWall.unfreezeDetail(FreezeInfo(by: .holder, when: nil, hasPassword: true)).contains("password"))
    #expect(FrozenWall.unfreezeDetail(FreezeInfo(by: .holder, when: nil)).contains("password"))
  }

  @Test func theAccountSaysWhetherTheHolderCanLiftTheFreeze() throws {
    let json = #"{"user_id":"u","frozen":true,"frozen_by":"holder","holder_can_lift":false,"has_password":false}"#
    let a = try JSONDecoder().decode(AccountInfo.self, from: Data(json.utf8))
    let info = try #require(LiveAccountService.freeze(a, nowMs: 1_792_000_000_000))
    #expect(!info.holderCanLift)
    #expect(info.hasPassword == false)
    let older = try JSONDecoder().decode(AccountInfo.self, from: Data(#"{"user_id":"u","frozen":true,"frozen_by":"holder"}"#.utf8))
    #expect(LiveAccountService.freeze(older, nowMs: 1_792_000_000_000)?.holderCanLift == true)
  }

  @Test func aSealedIPhoneWithNoOtherDeviceNamesNoneAndOffersAPerson() {
    #expect(ConfirmItsYouSheet.noKeyLines(otherDevice: nil, entersWords: false)
      == ["Only an iPhone where your data is open can confirm this"])
    #expect(ConfirmItsYouSheet.noKeyLines(otherDevice: "Maya's iPhone", entersWords: false)
      == ["Make the change on Maya's iPhone, where your data is open"])
    #expect(ConfirmItsYouSheet.noKeyLines(otherDevice: nil, entersWords: true) == ["Enter your 12 words to open it here"])
    for entersWords in [true, false] {
      #expect(!ConfirmItsYouSheet.noKeyLines(otherDevice: nil, entersWords: entersWords).joined().contains("other iPhone"))
    }
  }

  @Test func unseenWordsAreNotCalledProtectedOrConfirmed() {
    let s = SecurityState(email: "maya@example.com", emailVerified: true,
                          passkeys: [PasskeyRow(id: "a", provider: "Passkey", detail: "", isThisCredential: true)],
                          passwordChanged: nil, devices: [], lastSignIn: "today", phraseConfirmed: "Shown at signup", frozen: nil)
    #expect(SecurityView.phraseDetail(s, unseen: true) == "Not written down yet")
    #expect(SecurityView.phraseDetail(s, unseen: false) == "Shown at signup")
    var frozen = s
    frozen.frozen = FreezeInfo(by: .holder, when: nil)
    #expect(SecurityView.phraseDetail(frozen, unseen: false) == "Unfreeze to view")
  }

  @Test func theEmailRowNamesWhatGoesThere() {
    #expect(SecurityView.emailDetail == "Verified · sign-in codes and security emails")
  }

  @Test func deleteSaysWhatEachSourceLeavesBehind() {
    let none = DeleteAccountView.lines(providers: [], texts: false).map(\.text)
    #expect(none.first == "Your transactions, plan and rules are erased here and on our server.")
    #expect(!none.joined().contains("Gmail") && !none.joined().contains("Outlook") && !none.joined().contains("Shortcuts"))
    let outlook = DeleteAccountView.lines(providers: [.outlook], texts: false).map(\.text).joined()
    #expect(outlook.contains("Hasala deletes its Outlook sign-in"))
    #expect(outlook.contains("(https://account.live.com/consent/Manage)"))
    #expect(!outlook.contains("Gmail"))
    let gmailTexts = DeleteAccountView.lines(providers: [.gmail], texts: true).map(\.text)
    #expect(gmailTexts.contains("Hasala ends its access to your Gmail."))
    #expect(gmailTexts.contains("Delete the automation in the Shortcuts app."))
    #expect(!gmailTexts.joined().contains("budget"))
  }

  @Test func aWrongPasswordNamesTheWayBack() {
    let beta: AccountCapabilities = [.signInPassword, .recoverAccess]
    #expect(SignInView.wrongPasswordLine(beta) == "That email and password don't match. Try again, or use your 12 words if you forgot it.")
    #expect(SignInView.wrongPasswordLine([.signInPassword]) == "That email and password don't match. Try again.")
  }

  @Test func youAreBackInPromisesNoNewWordsWithoutThatControl() {
    #expect(!BackInView.phraseDetail(rotates: false).contains("make new ones"))
    #expect(BackInView.phraseDetail(rotates: false).contains("talk to us"))
    #expect(BackInView.phraseDetail(rotates: true).contains("make new ones"))
  }

  @Test func aWordCanBeFixedInPlace() {
    let state = PhraseEntryState("absurd avoid scii orbit ")
    #expect(state.unknownIndex == 2)
    #expect(state.canEdit(2))
    #expect(!state.canEdit(4))
    let fixed = PhraseEntryState(state.replacing(2, with: "Scissors!"))
    #expect(fixed.text == "absurd avoid scissors orbit ")
    #expect(fixed.unknownIndex == nil)
    #expect(state.replacing(2, with: "") == state.text)
    #expect(state.replacing(9, with: "orbit") == state.text)
    #expect(PhraseEntryState("absurd avoid").replacing(0, with: "orbit") == "orbit avoid")
    #expect(PhraseEntryGrid.unknownLine(2) == "Word 3 isn't on the recovery list. Tap it to fix the spelling.")
  }

  @Test func entryCellsReadTheirWordOnlyWhenTheScreenIsNotCaptured() {
    #expect(PhraseEntryGrid.cellLabel(0, word: "orbit", masked: false) == "Word 1, orbit")
    #expect(PhraseEntryGrid.cellLabel(0, word: "orbit", masked: true) == "Word 1, hidden")
    #expect(PhraseEntryGrid.cellLabel(11, word: "", masked: false) == "Word 12, empty")
  }

  @Test func aFailureBannerIsAnnouncedWhenItAppearsAndWhenItChanges() async throws {
    var heard: [String] = []
    let saved = ErrorAnnouncer.post
    ErrorAnnouncer.post = { heard.append($0) }
    defer { ErrorAnnouncer.post = saved }

    let failure = Box<AuthFailure?>(nil)
    let host = UIHostingController(rootView: BannerHost(box: failure))
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 300))
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer { window.isHidden = true }

    try await settle()
    #expect(heard.isEmpty)
    failure.value = .wrongCredentials
    try await settle()
    #expect(heard == [AuthFailure.wrongCredentials.message].compactMap { $0 })
    failure.value = .codeMismatch
    try await settle()
    #expect(heard.last == AuthFailure.codeMismatch.message)
    #expect(heard.count == 2)
  }

  private func settle() async throws {
    for _ in 0..<10 {
      try await Task.sleep(for: .milliseconds(30))
      await Task.yield()
    }
  }
}

@MainActor
@Observable
private final class Box<T> {
  var value: T
  init(_ value: T) { self.value = value }
}

private struct BannerHost: View {
  let box: Box<AuthFailure?>
  var body: some View { FailureBanner(failure: box.value) }
}
