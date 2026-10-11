import Foundation
import Observation

/// The signed-out routes: the stories, signup (C1, C1-P), sign-in (C2, C2-P), forgot
/// password (C9 side N) and access recovery (C4). Paper page 14 sections 14.1-14.4.
enum WelcomeRoute: Hashable {
  case welcome
  case invite
  case aboutYou
  case verifyEmail
  case method
  case password
  case phraseIntro
  case phraseShow
  case phraseConfirm
  case accountReady
  case signIn
  case forgotEmail
  case forgotCode
  case forgotCheck
  case forgotNewPassword
  case forgotWaiting
  case recoverIntro
  case recoverWords
  case recoverCode
  case recoverMethod
  case recoverPassword
  case honestEnd
}

/// Signup state, shared by the screens of section 14.1 and 14.2 (spec 04 §6.2 "Signup").
@MainActor
@Observable
final class SignupModel {
  private let account: AccountService
  var path: [WelcomeRoute] = []

  // Invite (§6.1.4)
  var inviteText = "" {
    didSet {
      // Any edit drops a link key: a typed code is never proven by a stale key.
      if oldValue != inviteText, inviteFromLink, InviteCode.normalize(inviteText) != linkCode {
        linkKey = nil
        inviteFromLink = false
      }
    }
  }
  private(set) var inviteFromLink = false
  private var linkKey: String?
  private var linkCode: String?
  private(set) var invitePasted = false

  // About you (§6.8)
  var displayName = ""
  var email = ""
  var nameError: String?
  var emailError: String?

  // Email code (§6.1.4)
  var code = ""
  private(set) var codeSentAt: Date?

  // Sign-in method and password (§6.1.2)
  var method: SignInMethod = .passkey
  var newPassword = ""
  var confirmPassword = ""

  // Phrase (§6.7)
  private(set) var phrase: RecoveryPhrase?
  var phraseRevealed = false
  /// The words placed in the four slots, in order of the slots.
  private(set) var placed: [String?] = [nil, nil, nil, nil]

  private(set) var ticket: SignupTicket?
  private(set) var profile: AccountProfile?
  private(set) var passkeyRegistered = false
  var busy = false
  var failure: AuthFailure?

  init(account: AccountService) {
    self.account = account
  }

  func go(_ route: WelcomeRoute) {
    failure = nil
    path.append(route)
  }

  func back() {
    failure = nil
    if !path.isEmpty { path.removeLast() }
  }

  // MARK: Invite

  var normalizedInvite: String { InviteCode.normalize(inviteText) }
  var inviteCode: InviteCode? { InviteCode(inviteText) }

  /// "Invite codes are 24 letters and numbers." once the text cannot be a code.
  var inviteHint: String? {
    let n = normalizedInvite
    guard !n.isEmpty else { return nil }
    if !InviteCode.isAlphabet(n) || n.count > InviteCode.length { return "Invite codes are 24 letters and numbers." }
    return nil
  }

  func applyInviteLink(_ link: InviteLink) {
    linkCode = link.code.value
    inviteText = link.code.grouped
    linkKey = link.linkKey
    inviteFromLink = true
    invitePasted = false
  }

  func paste(_ text: String) {
    inviteText = InviteCode.group(InviteCode.normalize(text))
    invitePasted = true
  }

  func submitInvite() {
    guard inviteCode != nil else {
      failure = nil
      return
    }
    go(.aboutYou)
  }

  // MARK: About you

  var aboutYouReady: Bool { !displayName.trimmingCharacters(in: .whitespaces).isEmpty && !email.isEmpty }

  func submitAboutYou() async {
    nameError = AccountFields.displayName(displayName) == nil ? AuthFailure.badName.message : nil
    emailError = AccountFields.email(email) == nil ? AuthFailure.badEmail.message : nil
    guard nameError == nil, emailError == nil, let invite = inviteCode else { return }
    busy = true
    defer { busy = false }
    do {
      let t = try await account.beginSignup(code: invite, linkKey: inviteFromLink ? linkKey : nil, email: email,
                                            displayName: displayName)
      ticket = t
      email = t.email
      linkKey = nil
      failure = nil
      if t.emailProven {
        go(.method)
      } else {
        codeSentAt = .now
        code = ""
        go(.verifyEmail)
      }
    } catch .notInvited {
      // Back to the code with Paper's "Not found" state.
      failure = .notInvited
      path.removeAll { $0 == .aboutYou }
    } catch {
      failure = error
    }
  }

  // MARK: Email code

  func resendCode() async {
    guard let ticket else { return }
    busy = true
    defer { busy = false }
    do {
      self.ticket = try await account.resendSignupCode(ticket)
      codeSentAt = .now
      code = ""
      failure = nil
    } catch {
      failure = error
    }
  }

  func submitCode() async {
    guard let ticket, code.count == 6 else { return }
    busy = true
    defer { busy = false }
    do {
      try await account.verifySignupEmail(ticket, code: code)
      failure = nil
      go(.method)
    } catch {
      failure = error
      code = ""
    }
  }

  // MARK: Method

  func continueWithMethod() async {
    switch method {
    case .password:
      go(.password)
    case .passkey:
      await registerPasskey()
    }
  }

  private func registerPasskey() async {
    guard let ticket else { return }
    if ticket.isExpired(now: .now) {
      failure = .signupExpired
      path = [.welcome, .invite, .aboutYou]
      return
    }
    busy = true
    defer { busy = false }
    do {
      try await account.registerPasskey(ticket)
      passkeyRegistered = true
      try startPhrase()
      go(.phraseIntro)
    } catch .unsupported {
      failure = .unsupported
      method = .password
    } catch {
      failure = error
    }
  }

  // MARK: Password

  var passwordAssessment: PasswordAssessment {
    PasswordRules.assess(newPassword, personal: [displayName, email, email.split(separator: "@").first.map(String.init) ?? ""])
  }

  var passwordsMatch: Bool { !confirmPassword.isEmpty && confirmPassword == newPassword }
  var passwordReady: Bool { passwordAssessment.acceptable && passwordsMatch }

  func submitPassword() {
    guard passwordReady else { return }
    do {
      try startPhrase()
      go(.phraseIntro)
    } catch {
      failure = error
    }
  }

  // MARK: Phrase

  private func startPhrase() throws(AuthFailure) {
    phrase = try account.makeRecoveryPhrase()
    phraseRevealed = false
    placed = [nil, nil, nil, nil]
  }

  var askedPositions: [Int] { phrase?.confirmPositions ?? [] }
  var choices: [String] { phrase.map(PhraseRules.confirmChoices) ?? [] }

  /// The slot's state: empty, right or wrong.
  enum SlotState: Equatable { case empty, right, wrong }

  func slotState(_ i: Int) -> SlotState {
    guard let phrase, let word = placed[i] else { return .empty }
    return phrase.words[phrase.confirmPositions[i]] == word ? .right : .wrong
  }

  var wrongSlot: Int? { (0..<4).first { slotState($0) == .wrong } }
  var confirmedCount: Int { (0..<4).filter { slotState($0) == .right }.count }
  var phraseConfirmed: Bool { confirmedCount == 4 }

  func isPlaced(_ word: String) -> Bool { placed.contains(word) }

  /// Tapping a chip fills the first empty slot (unless a wrong word is waiting to be
  /// taken back).
  func place(_ word: String) {
    guard wrongSlot == nil, !isPlaced(word), let i = placed.firstIndex(where: { $0 == nil }) else { return }
    placed[i] = word
  }

  /// Tapping a filled slot takes its word back.
  func takeBack(_ i: Int) {
    placed[i] = nil
  }

  func showWordsAgain() {
    placed = [nil, nil, nil, nil]
    phraseRevealed = false
    if let i = path.lastIndex(of: .phraseShow) { path.removeSubrange((i + 1)...) }
  }

  /// Publishes the keys (C1 steps 10-16 / C1-P's `password/register`). Nothing reaches
  /// the server before the four words are confirmed.
  func finish() async {
    guard phraseConfirmed, let ticket, let phrase else { return }
    busy = true
    defer { busy = false }
    let credential: NewCredential = method == .passkey ? .passkey : .password(newPassword)
    do {
      profile = try await account.finishAccount(ticket, credential: credential, phrase: phrase)
      // The phrase leaves memory once it is published.
      self.phrase = nil
      placed = [nil, nil, nil, nil]
      newPassword = ""
      confirmPassword = ""
      failure = nil
      go(.accountReady)
    } catch {
      failure = error
    }
  }
}
