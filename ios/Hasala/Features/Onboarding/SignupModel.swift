import Foundation
import Observation

/// Signup state, shared by the screens of section 14.1 and 14.2 (spec 04 §6.2 "Signup").
@MainActor
@Observable
final class SignupModel {
  private let account: AccountService
  var path: [WelcomeRoute] = []
  /// The path as the navigation stack changes it: the system back button or its swipe
  /// (plan decision 7) leaves the failure of the screen it left behind, as `back()` does.
  var navigationPath: [WelcomeRoute] {
    get { path }
    set {
      if newValue.count < path.count { failure = nil }
      path = newValue
    }
  }

  // Invite (§6.1.4)
  /// The code characters entered (`InviteCode.entryCharacters`); the field shows them
  /// grouped (`InviteCodeEntry.text`).
  var inviteText = "" {
    didSet {
      guard oldValue != inviteText else { return }
      // Any edit drops a link key: a typed code is never proven by a stale key.
      if inviteFromLink, InviteCode.normalize(inviteText) != linkCode {
        linkKey = nil
        inviteFromLink = false
      }
      // "Not found" goes as soon as the code changes (page 11: clear the error on fixing).
      if failure == .notInvited { failure = nil }
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
  /// The digits typed so far. Typing again after a wrong code clears the error (page 11:
  /// "Typing again clears it").
  var code = "" {
    didSet {
      guard !code.isEmpty, case .codeWrong = failure else { return }
      failure = nil
      wrongCode = ""
    }
  }
  private(set) var codeSentAt: Date?
  /// The six digits the server refused, kept on screen with the error ring so they can be
  /// compared with the email, until the person types again (Paper EID-0).
  private(set) var wrongCode = ""
  /// The current ticket's address was proven by its six-digit code.
  private(set) var emailVerified = false

  // Sign-in method and password (§6.1.2)
  var method: SignInMethod = .passkey
  var newPassword = ""
  var confirmPassword = ""
  /// "Show" on the new password: the person's choice stays through Back and Forward.
  var passwordShown = false

  // Phrase (§6.7)
  private(set) var phrase: RecoveryPhrase?
  /// The words are drawn. Never while the screen is captured: the grid would draw dots,
  /// so a reveal then shows the person nothing and doesn't count.
  var phraseRevealed = false {
    didSet {
      if phraseRevealed, phraseMasked { phraseRevealed = false }
      if phraseRevealed { phraseSeen = true }
    }
  }
  /// The screen is being recorded or mirrored (`PhraseShowView` reports it): the words
  /// hide, and can't be shown until capture stops.
  var phraseMasked = false {
    didSet { if phraseMasked { phraseRevealed = false } }
  }
  /// The words were drawn for the person at least once. Nothing is published before
  /// (`docs/decisions/recovery-phrase-no-quiz.md`): there is no word check after them.
  private(set) var phraseSeen = false

  private(set) var ticket: SignupTicket?
  /// The invite the current ticket was begun with, so Back and Forward through About you
  /// reuse it rather than begin (and email) again.
  private var ticketInvite: String?
  /// C1 interrupted (spec 04 §6.2): a NEW phrase for an account that exists without
  /// keys; `finish()` publishes it with step-up `keys.bootstrap` instead of a signup.
  private(set) var replacing = false
  private(set) var profile: AccountProfile?
  /// The ticket a passkey was saved for: Back and Forward through the method screen never
  /// asks Face ID to save a second one for the same signup.
  private var passkeyTicketID: String?
  var passkeyRegistered: Bool { ticket != nil && passkeyTicketID == ticket?.id }
  var busy = false
  var failure: AuthFailure?

  /// The welcome stories' "Who can see what" sheet is open (the stories pause under it).
  var whoCanSeeOpen = false

  /// What this build can do (`AccountService.capabilities`); the copy follows it.
  var capabilities: AccountCapabilities { account.capabilities }

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
    inviteText = link.code.value
    linkKey = link.linkKey
    inviteFromLink = true
    invitePasted = false
  }

  /// The Paste button: a copied code (hyphens and spaces or not) replaces the field, and a
  /// copied invite link is taken as if it had been opened.
  func paste(_ text: String) {
    if let link = InviteLink.parse(pasted: text) {
      applyInviteLink(link)
      return
    }
    inviteText = InviteCode.entryCharacters(text)
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

  /// The address in the field is the one the open ticket confirmed, by the invite link or by
  /// its code (the "Confirmed" chip, Paper E7J-0).
  var emailConfirmed: Bool {
    guard let t = ticket, t.emailProven || emailVerified else { return false }
    return t.email == AccountFields.email(email)
  }

  /// Continue on About you. Back and Forward never begin a second signup for the same
  /// name, email and invite: the open ticket carries on where it was (its code, or the
  /// method once the address is confirmed). A changed value begins again.
  func submitAboutYou() async {
    nameError = AccountFields.displayName(displayName) == nil ? AuthFailure.badName.message : nil
    emailError = AccountFields.email(email) == nil ? AuthFailure.badEmail.message : nil
    guard nameError == nil, emailError == nil, let invite = inviteCode else { return }
    if let t = ticket, !t.isExpired(now: .now), ticketInvite == invite.value,
      t.email == AccountFields.email(email), t.displayName == AccountFields.displayName(displayName)
    {
      failure = nil
      go(t.emailProven || emailVerified ? .method : .verifyEmail)
      return
    }
    busy = true
    defer { busy = false }
    do {
      let t = try await account.beginSignup(code: invite, linkKey: inviteFromLink ? linkKey : nil, email: email,
                                            displayName: displayName)
      ticket = t
      ticketInvite = invite.value
      emailVerified = false
      email = t.email
      linkKey = nil
      failure = nil
      if t.emailProven {
        go(.method)
      } else {
        codeSentAt = .now
        code = ""
        wrongCode = ""
        go(.verifyEmail)
      }
    } catch .notInvited {
      // Back to the code with Paper's "Not found" state (E6F-0); a link's code is shown in
      // the same field, so it can be checked character by character.
      failure = .notInvited
      if path.contains(.inviteReady) {
        path = [.welcome, .invite]
      } else {
        path.removeAll { $0 == .aboutYou }
      }
    } catch {
      failure = error
    }
  }

  // MARK: Email code

  /// "Resend code" and "Send a new code": a fresh ceremony, a fresh code, five fresh tries.
  func resendCode() async {
    guard let ticket else { return }
    busy = true
    defer { busy = false }
    do {
      self.ticket = try await account.resendSignupCode(ticket)
      codeSentAt = .now
      code = ""
      wrongCode = ""
      emailVerified = false
      failure = nil
    } catch {
      failure = error
    }
  }

  /// How the code cells look: typing, wrong (every cell ringed, the digits kept) or expired
  /// (empty cells, no keyboard, "Send a new code"). A code also expires 10 minutes after it
  /// was sent (spec 04 §6.1.4), whatever the last answer was.
  func codeState(now: Date) -> CodeCells.State {
    if failure == .codeExpired || ticket?.codeExpired(now: now) == true { return .expired }
    if case .codeWrong = failure { return .wrong }
    return .typing
  }

  /// Checked on the sixth digit (page 11). A wrong code keeps its digits on screen; an
  /// expired one empties the cells.
  func submitCode() async {
    guard let ticket, code.count == 6 else { return }
    busy = true
    defer { busy = false }
    do {
      try await account.verifySignupEmail(ticket, code: code)
      failure = nil
      emailVerified = true
      go(.method)
    } catch {
      wrongCode = error == .codeExpired ? "" : code
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
      // Back to About you, on the way the person came (a typed code or a link).
      if let about = path.firstIndex(of: .aboutYou) { path = Array(path.prefix(through: about)) }
      return
    }
    // Saved already for this signup (the person went Back, then Forward): no second sheet.
    if passkeyRegistered {
      if phrase == nil {
        do {
          try startPhrase()
        } catch {
          failure = error
          return
        }
      }
      failure = nil
      go(.phraseIntro)
      return
    }
    busy = true
    defer { busy = false }
    do {
      try await account.registerPasskey(ticket)
      passkeyTicketID = ticket.id
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

  /// Starts the replacement phrase of an interrupted C1 (S-07 opens it).
  func startReplacement() {
    replacing = true
    method = .passkey
    do {
      try startPhrase()
      failure = nil
    } catch {
      failure = error
    }
  }

  private func startPhrase() throws(AuthFailure) {
    phrase = try account.makeRecoveryPhrase()
    phraseRevealed = false
    phraseSeen = false
  }

  /// "I've written them down": publishes the keys (C1 steps 10-16 / C1-P's
  /// `password/register`). Nothing reaches the server before the words were shown to the
  /// person; there is no word check (`docs/decisions/recovery-phrase-no-quiz.md`).
  func finish() async {
    guard phraseSeen, let phrase, replacing || ticket != nil else { return }
    busy = true
    defer { busy = false }
    let credential: NewCredential = method == .passkey ? .passkey : .password(newPassword)
    do {
      if replacing {
        profile = try await account.finishInterruptedSetup(phrase: phrase)
      } else if let ticket {
        profile = try await account.finishAccount(ticket, credential: credential, phrase: phrase)
      }
      // The phrase leaves memory once it is published.
      self.phrase = nil
      newPassword = ""
      confirmPassword = ""
      passwordShown = false
      failure = nil
      go(.accountReady)
    } catch {
      failure = error
    }
  }
}
