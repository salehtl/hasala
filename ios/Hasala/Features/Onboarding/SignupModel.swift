import Foundation
import Observation

/// Signup state, shared by the screens of section 14.1 and 14.2 (spec 04 §6.2 "Signup").
@MainActor
@Observable
final class SignupModel {
  private let account: AccountService
  private let unseenPhrase: any UnseenPhraseNoting
  private let accountCreated: () -> Void
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
        linkPasteboardChange = nil
      }
      // "Not found" goes as soon as the code changes (page 11: clear the error on fixing).
      if failure == .notInvited { failure = nil }
    }
  }
  private(set) var inviteFromLink = false
  /// The link's key, held until the account is made: a new signup on the link's path (Back,
  /// then a changed name) sends it again, so the invite's address still needs no code and
  /// About you's "no code" stays true. Editing the code drops it (above).
  private var linkKey: String?
  private var linkCode: String?
  private(set) var invitePasted = false
  private(set) var linkPasteboardChange: Int?
  var clearPasteboard: @MainActor (Int) -> Void = { clearPastedPhrase(changeCount: $0) }

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
  /// Five wrong tries used the current code up (the server refuses it from then on). Kept
  /// through Back and Forward like the other signup facts, so Check your email comes back
  /// expired with "Send a new code"; a new code or a new signup clears it.
  private(set) var codeUsedUp = false

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
  private(set) var passkeyPRF = false
  private(set) var passkeySynced = false
  private(set) var wordsInSignup = false
  var wordsLater: Bool {
    !replacing && !wordsInSignup && method == .passkey && passkeyPRF && passkeySynced && passkeyRegistered
      && capabilities.contains(.viewPhrase)
  }
  var busy = false
  var failure: AuthFailure?
  var now: () -> Date = { .now }

  /// The welcome stories' "Who can see what" sheet is open (the stories pause under it).
  var whoCanSeeOpen = false

  /// What this build can do (`AccountService.capabilities`); the copy follows it.
  var capabilities: AccountCapabilities { account.capabilities }

  init(
    account: AccountService, unseenPhrase: any UnseenPhraseNoting = InMemoryUnseenPhrase(),
    accountCreated: @escaping () -> Void = {}
  ) {
    self.account = account
    self.unseenPhrase = unseenPhrase
    self.accountCreated = accountCreated
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

  func applyInviteLink(_ link: InviteLink, pasteboardChange: Int? = nil) {
    linkCode = link.code.value
    inviteText = link.code.value
    linkKey = link.linkKey
    inviteFromLink = true
    invitePasted = false
    linkPasteboardChange = pasteboardChange
  }

  /// The Paste button: a copied code (hyphens and spaces or not) replaces the field, and a
  /// copied invite link is taken as if it had been opened.
  func paste(_ text: String, pasteboardChange: Int? = nil) {
    if let link = InviteLink.parse(pasted: text) {
      applyInviteLink(link, pasteboardChange: pasteboardChange)
      return
    }
    inviteText = InviteCode.entryCharacters(text)
    invitePasted = true
  }

  func usePastedInvite(_ text: String, pasteboardChange: Int? = nil) {
    failure = nil
    guard let link = InviteLink.parse(pasted: text) else {
      if InviteCode(InviteCode.entryCharacters(text)) != nil { paste(text) }
      path = [.invite]
      return
    }
    applyInviteLink(link, pasteboardChange: pasteboardChange)
    path = [.inviteReady]
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

  /// The code in the field came from an invite link that carries its key: a signup with it
  /// needs no code for the address the invite went to (spec 04 §13.5).
  var linkProvesAddress: Bool { inviteFromLink && linkKey != nil }

  /// The open ticket, when Continue on About you carries on with it: the same invite, name
  /// and address, and still alive. Anything else begins a new signup.
  private func reusableTicket(now: Date) -> SignupTicket? {
    guard let t = ticket, let invite = inviteCode, ticketInvite == invite.value, !t.isExpired(now: now),
      t.email == AccountFields.email(email), t.displayName == AccountFields.displayName(displayName)
    else { return nil }
    return t
  }

  /// The address in the field is confirmed, and Continue keeps it so (the "Confirmed" chip,
  /// Paper E7J-0): the open ticket carries on with its link or its code, or a new signup sends
  /// the link's key again for the same address. A changed name on the typed-code path is a new
  /// signup with a new code, so the chip goes.
  var emailConfirmed: Bool {
    if let t = reusableTicket(now: .now) { return t.emailProven || emailVerified }
    guard let t = ticket, t.emailProven, linkProvesAddress, ticketInvite == inviteCode?.value else { return false }
    return t.email == AccountFields.email(email)
  }

  /// About you's line under the email (spec 07 S6a, S6b): whether a code is coming, said as
  /// Continue will act on it.
  var emailHelp: String {
    if emailConfirmed {
      return ticket?.emailProven == true
        ? "Your invite link confirmed it, so there's no code. Security alerts go here."
        : "Your code confirmed it. Security alerts go here."
    }
    return linkProvesAddress
      ? "If it's the address your invite went to, there's no code. Security alerts go here."
      : "We'll send a code to confirm it. Security alerts go here too."
  }

  /// Continue on About you. Back and Forward never begin a second signup for the same
  /// name, email and invite: the open ticket carries on where it was (its code, or the
  /// method once the address is confirmed). A changed value begins again.
  func submitAboutYou() async {
    nameError = AccountFields.displayName(displayName) == nil ? AuthFailure.badName.message : nil
    emailError = AccountFields.email(email) == nil ? AuthFailure.badEmail.message : nil
    guard nameError == nil, emailError == nil, let invite = inviteCode else { return }
    if let t = reusableTicket(now: .now) {
      failure = nil
      go(t.emailProven || emailVerified ? .method : .verifyEmail)
      return
    }
    busy = true
    defer { busy = false }
    do {
      let t = try await account.beginSignup(code: invite, linkKey: linkProvesAddress ? linkKey : nil, email: email,
                                            displayName: displayName)
      ticket = t
      ticketInvite = invite.value
      clearPastedLink()
      emailVerified = false
      codeUsedUp = false
      email = t.email
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
        path = [.invite]
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
      codeUsedUp = false
      failure = nil
    } catch {
      failure = error
    }
  }

  /// How the code cells look: typing, wrong (every cell ringed, the digits kept) or expired
  /// (empty cells, no keyboard, "Send a new code"). A code also expires 10 minutes after it
  /// was sent (spec 04 §6.1.4), whatever the last answer was, and stays used up after five
  /// wrong tries however the person came back to it.
  func codeState(now: Date) -> CodeCells.State {
    if codeUsedUp || failure == .codeExpired || ticket?.codeExpired(now: now) == true { return .expired }
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
      if error == .codeExpired { codeUsedUp = true }
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
    if ticket.isExpired(now: now()) {
      startAgain()
      return
    }
    // Saved already for this signup (the person went Back, then Forward): no second sheet.
    if passkeyRegistered {
      if wordsLater {
        busy = true
        defer { busy = false }
        await finishWithoutWords()
        return
      }
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
      let made = try await account.registerPasskey(ticket)
      passkeyTicketID = ticket.id
      passkeyPRF = made.prf
      passkeySynced = made.synced
      wordsInSignup = false
      if wordsLater {
        await finishWithoutWords()
        return
      }
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
    if !replacing, ticket?.isExpired(now: now()) == true {
      startAgain()
      return
    }
    do {
      if phrase == nil { try startPhrase() }
      failure = nil
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
    if !replacing, ticket?.isExpired(now: now()) == true {
      startAgain()
      return
    }
    busy = true
    defer { busy = false }
    let credential: NewCredential = method == .passkey ? .passkey : .password(newPassword)
    do {
      if replacing {
        profile = try await account.finishInterruptedSetup(phrase: phrase)
      } else if let ticket {
        profile = try await account.finishAccount(ticket, credential: credential, phrase: phrase)
      }
      unseenPhrase.noteSeen()
      // The phrase leaves memory once it is published, and the link's key is no longer needed.
      self.phrase = nil
      linkKey = nil
      clearPastedLink()
      newPassword = ""
      confirmPassword = ""
      passwordShown = false
      failure = nil
      go(.accountReady)
    } catch .codeExpired where !replacing {
      startAgain()
    } catch {
      failure = error
    }
  }

  private func clearPastedLink() {
    guard let change = linkPasteboardChange else { return }
    clearPasteboard(change)
    linkPasteboardChange = nil
  }

  private func finishWithoutWords() async {
    guard wordsLater, let ticket else { return }
    if ticket.isExpired(now: now()) {
      startAgain()
      return
    }
    do {
      profile = try await account.finishAccountWithoutWords(ticket)
      unseenPhrase.noteUnseen(at: now())
      self.phrase = nil
      linkKey = nil
      failure = nil
      accountCreated()
    } catch .codeExpired {
      startAgain()
    } catch .wordsInSignup {
      wordsInSignup = true
      do {
        try startPhrase()
      } catch {
        failure = error
        return
      }
      failure = nil
      go(.phraseIntro)
    } catch {
      failure = error
    }
  }

  private func startAgain() {
    clearPastedLink()
    let reason: AuthFailure = phraseSeen ? .signupExpiredPhrase : .signupExpired
    phrase = nil
    phraseRevealed = false
    phraseSeen = false
    ticket = nil
    emailVerified = false
    codeUsedUp = false
    if let about = path.firstIndex(of: .aboutYou) { path = Array(path.prefix(through: about)) }
    failure = reason
  }
}
