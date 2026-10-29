import Foundation
import Testing

@testable import Hasala

@Suite("Account rules")
struct AccountRulesTests {
  // MARK: Invite code (spec 04 §6.1.4)

  @Test func inviteCodesNormalizeAndGroup() throws {
    let code = try #require(InviteCode("abcd efgh-ijkl mnop qrst uvwx"))
    #expect(code.value == "ABCDEFGHIJKLMNOPQRSTUVWX")
    #expect(code.grouped == "ABCD-EFGH-IJKL-MNOP-QRST-UVWX")
    #expect(InviteCode("ABCDEFGHIJKLMNOPQRSTUVW") == nil)  // 23
    #expect(InviteCode("ABCDEFGHIJKLMNOPQRSTUVW1") == nil)  // 1 is not base32
    #expect(InviteCode("HSL-7Q4M") == nil)  // the withdrawn short form
  }

  // MARK: Universal link (spec 04 §13.5's four rules)

  static let key = String(repeating: "a", count: 40) + "_-9"

  @Test func inviteLinkWithKey() throws {
    let link = try #require(InviteLink.parse(URL(string: "https://hasala.app/i/ABCD-EFGH-IJKL-MNOP-QRST-UVWX#\(Self.key)")!))
    #expect(link.code.value == "ABCDEFGHIJKLMNOPQRSTUVWX")
    #expect(link.linkKey == Self.key)
  }

  @Test func inviteLinkWithoutAValidKeyIsCodeOnly() throws {
    let noKey = try #require(InviteLink.parse(URL(string: "https://hasala.app/i/abcdefghijklmnopqrstuvwx")!))
    #expect(noKey.linkKey == nil)
    let shortKey = try #require(InviteLink.parse(URL(string: "https://hasala.app/i/ABCDEFGHIJKLMNOPQRSTUVWX#short")!))
    #expect(shortKey.linkKey == nil)
  }

  @Test func legacyFragmentFormIsCodeOnly() throws {
    let link = try #require(InviteLink.parse(URL(string: "https://hasala.app/i#ABCDEFGHIJKLMNOPQRSTUVWX")!))
    #expect(link.code.value == "ABCDEFGHIJKLMNOPQRSTUVWX")
    #expect(link.linkKey == nil)
  }

  @Test(arguments: [
    "http://hasala.app/i/ABCDEFGHIJKLMNOPQRSTUVWX",
    "https://www.hasala.app/i/ABCDEFGHIJKLMNOPQRSTUVWX",
    "https://hasala.app:443/i/ABCDEFGHIJKLMNOPQRSTUVWX",
    "https://hasala.app/i/ABCDEFGHIJKLMNOPQRSTUVWX?x=1",
    "https://hasala.app/i/ABCDEFGHIJKLMNOPQRSTUVWX/extra",
    "https://hasala.app/i/NOTACODE",
    "https://hasala.app/freeze#token",
    "https://user@hasala.app/i/ABCDEFGHIJKLMNOPQRSTUVWX",
  ])
  func otherURLsAreIgnored(_ s: String) {
    #expect(InviteLink.parse(URL(string: s)!) == nil)
  }

  // MARK: Address and name (spec 04 §6.8)

  @Test func addressesNormalize() {
    #expect(AccountFields.email("  Maya.R+bills@Example.COM ") == "maya.r+bills@example.com")
    #expect(AccountFields.email("maya@example") == nil)
    #expect(AccountFields.email("mäya@example.com") == nil)
  }

  @Test func namesFollowTheServerRule() {
    #expect(AccountFields.displayName("  Maya   Rahman ") == "Maya Rahman")
    #expect(AccountFields.displayName("O'Neil-Smith Jr.") == "O'Neil-Smith Jr.")
    #expect(AccountFields.displayName("مريم") == "مريم")
    #expect(AccountFields.displayName("Maya2") == nil)
    #expect(AccountFields.displayName("maya@example.com") == nil)
    #expect(AccountFields.displayName("   ") == nil)
  }

  // MARK: Passwords (spec 04 §6.1.2)

  @Test func shortPasswordsAreRefusedFirst() {
    let a = PasswordRules.assess("short pw")
    #expect(a.strength == .tooShort)
    // Paper EQ6: "Too short. 8 of 12 characters." (one scalar per composed character).
    #expect(a.message == "Too short. 8 of 12 characters.")
    #expect(!a.acceptable)
    #expect(PasswordRules.assess("cafe\u{301} latte").message == "Too short. 10 of 12 characters.")
  }

  @Test(arguments: ["Password2026!!!", "HasalaBudgeting1", "passwordpassword", "123456789012"])
  func commonPasswordsAreRefused(_ pw: String) {
    let a = PasswordRules.assess(pw)
    #expect(!a.notCommon, "\(pw) should be refused")
    #expect(!a.acceptable)
  }

  @Test func theBundledListLoaded() {
    #expect(PasswordRules.blocklist.count > 100)
  }

  @Test func personalPasswordsAreRefused() {
    let a = PasswordRules.assess("mayarahman2026", personal: ["Maya Rahman", "maya@example.com"])
    #expect(!a.notPersonal)
    #expect(!a.acceptable)
  }

  @Test func aPassphraseIsStrong() {
    let a = PasswordRules.assess("copper lantern quietly 42", personal: ["Maya Rahman"])
    #expect(a.acceptable)
    #expect(a.strength == .strong)
  }

  // MARK: Phrase (spec 04 §6.7)

  @Test func generatedPhrasesValidate() throws {
    let p = try PhraseRules.generate()
    #expect(p.words.count == 12)
    if case .failure = PhraseRules.validate(p.words.joined(separator: "  ")) { Issue.record("own phrase refused") }
  }

  @Test func phraseErrorsAreS16() {
    guard case .failure(.badPhrase(let len)) = PhraseRules.validate("orbit canvas") else { Issue.record("len"); return }
    #expect(len == "A recovery phrase has 12 words. This has 2.")
    let unknown = Array(repeating: "abandon", count: 11) + ["notaword"]
    guard case .failure(.badPhrase(let u)) = PhraseRules.validate(unknown.joined(separator: " ")) else { Issue.record("unknown"); return }
    #expect(u.hasPrefix("Word 12, "))
    let bad = Array(repeating: "abandon", count: 12)
    guard case .failure(.badPhrase(let c)) = PhraseRules.validate(bad.joined(separator: " ")) else { Issue.record("checksum"); return }
    #expect(c.hasPrefix("Every word is real"))
  }

  /// What happened, then what to do (spec 01 §7.4, spec 07 S4 and S7, spec 08 FWD), verbatim.
  @Test func failuresSayWhatHappenedThenWhatToDo() {
    #expect(AuthFailure.codeWrong(triesLeft: 4).message
      == "That code isn't right. Check the newest email from us, or get a new code. 4 tries left.")
    #expect(AuthFailure.codeWrong(triesLeft: 1).message?.hasSuffix(" 1 try left.") == true)
    #expect(AuthFailure.codeExpired.message == "That code expired. Codes last 10 minutes, so we'll send you a fresh one.")
    #expect(AuthFailure.wrongCredentials.message == "That email and password don't match. Try again, or reset your password.")
    #expect(AuthFailure.notInvited.message == "We couldn't find that invite. Check each character against your email.")
  }

  @Test func suggestionsComeFromTheList() {
    #expect(PhraseRules.suggestions(for: "orb") == ["orbit"])
    #expect(PhraseRules.suggestions(for: "a").isEmpty)
  }

  @Test(arguments: ["\u{0661}\u{0662}\u{0663}\u{0664}\u{0665}\u{0666}", "\u{06F1}\u{06F2}\u{06F3}\u{06F4}\u{06F5}\u{06F6}", "123456"])
  func codeCellsKeepASCIIDigits(_ typed: String) {
    #expect(CodeCells.digits(typed) == "123456")
  }

  @Test func codeCellsDropEverythingElse() {
    #expect(CodeCells.digits("12-34 5a6") == "123456")
    #expect(CodeCells.digits("1234567890") == "123456")
    #expect(CodeCells.digits("\u{2167}12") == "12")
    #expect(CodeCells.digits("") == "")
  }

  @Test func pastedInviteEmailsKeepTheCode() {
    let key = String(repeating: "k", count: 43)
    let mail = String(repeating: "Hello from Hasala, your invite is below. ", count: 10)
    #expect(InviteCode.entryCharacters(mail + "Your code: ABCD-EFGH-IJKL-MNOP-QRST-UVWX. Thanks") == "ABCDEFGHIJKLMNOPQRSTUVWX")
    #expect(InviteCode.entryCharacters(mail + "Open https://hasala.app/i/ABCDEFGHIJKLMNOPQRSTUVWX#\(key) on your iPhone")
      == "ABCDEFGHIJKLMNOPQRSTUVWX")
    #expect(InviteCode.entryCharacters(mail).count == InviteCode.length + 8)
    #expect(InviteCode.entryCharacters("abcd efgh ijkl mnop qrst uvwx") == "ABCDEFGHIJKLMNOPQRSTUVWX")
    #expect(InviteCode.entryCharacters("ABCD1") == "ABCD1")
    #expect(InviteCode.entryCharacters("this text will help when your code is ABCD-EFGH-IJKL-MNOP-QRST-UVWX")
      == "ABCDEFGHIJKLMNOPQRSTUVWX")
    #expect(InviteCode.entryCharacters("this text will help when your code is ABCD EFGH IJKL MNOP QRST UVWX")
      == "ABCDEFGHIJKLMNOPQRSTUVWX")
    let e = InviteCodeEntry.edit("", range: NSRange(location: 0, length: 0), replacement: mail)
    #expect(e.characters.count == InviteCode.length + 8)
    #expect(e.caret == e.characters.count)
  }

  @Test func passwordCountsOnlyWhenCharactersAndScalarsAgree() {
    #expect(PasswordRules.assess("\u{1F469}\u{1F3FD}\u{200D}\u{1F4BB}").message == "Too short. Use 12 characters or more.")
    #expect(PasswordRules.assess("short pw").message == "Too short. 8 of 12 characters.")
  }

  @Test func greetingsUseTheWholeName() {
    let arabic = AccountProfile(displayName: "\u{0639}\u{0628}\u{062F} \u{0627}\u{0644}\u{0631}\u{062D}\u{0645}\u{0646}", email: "a@b.co", method: .passkey)
    #expect(arabic.greetingName == "\u{0639}\u{0628}\u{062F} \u{0627}\u{0644}\u{0631}\u{062D}\u{0645}\u{0646}")
    #expect(AccountProfile(displayName: " Dr. Aisha Al-Suwaidi ", email: "a@b.co", method: .password).greetingName
      == "Dr. Aisha Al-Suwaidi")
  }

  @Test func signupFieldsSayWhenTheyAreTooLong() {
    #expect(AccountFields.nameTooLong(String(repeating: "a", count: 65)))
    #expect(!AccountFields.nameTooLong(String(repeating: "a", count: 64)))
    #expect(!AccountFields.nameTooLong("   "))
    #expect(AccountFields.emailTooLong(String(repeating: "a", count: 245) + "@example.c"))
    #expect(!AccountFields.emailTooLong(String(repeating: "a", count: 244) + "@example.c"))
  }
}
