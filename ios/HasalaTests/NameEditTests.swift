import HasalaMocks
import HasalaModels
import Testing

@testable import Hasala

@MainActor
@Suite("Name edit")
struct NameEditTests {
  final class Saved {
    var names: [String] = []
    var failure: AuthFailure?
  }

  func make(current: String = "Maya Rahman") -> (NameEditModel, Saved) {
    let saved = Saved()
    let model = NameEditModel(current: current) { name throws(AuthFailure) in
      if let failure = saved.failure { throw failure }
      saved.names.append(name)
      return name
    }
    return (model, saved)
  }

  @Test func theCheckTrimsAndFolds() {
    #expect(NameEditModel.check("  Maya  \n Rahman ") == .ok("Maya Rahman"))
    #expect(NameEditModel.check("Anne-Marie O\u{2019}Neil") == .ok("Anne-Marie O\u{2019}Neil"))
    #expect(NameEditModel.check("Mar\u{00ED}a") == .ok("Mar\u{00ED}a"))
    #expect(NameEditModel.check("\u{0645}\u{0627}\u{064A}\u{0627}") == .ok("\u{0645}\u{0627}\u{064A}\u{0627}"))
  }

  @Test func theCheckRefusesEmptyLongAndOddNames() {
    #expect(NameEditModel.check("") == .empty)
    #expect(NameEditModel.check("   \n ") == .empty)
    #expect(NameEditModel.check(String(repeating: "a", count: 64)) == .ok(String(repeating: "a", count: 64)))
    #expect(NameEditModel.check(String(repeating: "a", count: 65)) == .tooLong)
    #expect(NameEditModel.check("Maya \u{1F600}") == .characters)
    #expect(NameEditModel.check("Maya 42") == .characters)
    #expect(NameEditModel.check("...") == .characters)
    #expect(NameEditModel.check("john.smith92") == .characters)
  }

  @Test func eachRefusalHasItsWords() {
    #expect(NameEditModel.Check.empty.message == "Add your name.")
    #expect(NameEditModel.Check.tooLong.message == "Use 64 letters or fewer.")
    #expect(NameEditModel.Check.characters.message == AuthFailure.badName.message)
    #expect(NameEditModel.Check.ok("Maya").message == nil)
  }

  @Test func savingSendsTheFoldedNameOnce() async {
    let (model, saved) = make()
    model.text = "  Maya   K Rahman "
    #expect(model.changed)
    let result = await model.commit()
    #expect(result == "Maya K Rahman")
    #expect(saved.names == ["Maya K Rahman"])
    #expect(model.failure == nil)
    #expect(!model.saving)
  }

  @Test func anUnchangedNameSavesNothing() async {
    let (model, saved) = make()
    model.text = " Maya Rahman "
    #expect(!model.changed)
    #expect(await model.commit() == "Maya Rahman")
    #expect(saved.names.isEmpty)
  }

  @Test func anEmptyNameIsRefusedBeforeAnythingIsSent() async {
    let (model, saved) = make()
    model.text = "   "
    #expect(!model.canSave)
    #expect(await model.commit() == nil)
    #expect(model.failure == "Add your name.")
    #expect(saved.names.isEmpty)
    model.textChanged()
    #expect(model.failure == nil)
  }

  @Test func aTooLongNameIsRefusedBeforeAnythingIsSent() async {
    let (model, saved) = make()
    model.text = String(repeating: "b", count: 65)
    #expect(await model.commit() == nil)
    #expect(model.failure == "Use 64 letters or fewer.")
    #expect(saved.names.isEmpty)
  }

  @Test func aServerFailureIsShownAndNothingChanges() async {
    let (model, saved) = make()
    saved.failure = .offline
    model.text = "Maya K"
    #expect(await model.commit() == nil)
    #expect(model.failure == AuthFailure.offline.message)
    #expect(!model.saving)
    saved.failure = nil
    #expect(await model.commit() == "Maya K")
    #expect(model.failure == nil)
  }

  @Test func theNewNameReachesTheProfileAndTheInitial() {
    let app = AppModel(store: InMemoryLedger())
    let before = app.store.state.profile
    #expect(app.perform(.setDisplayName("Noor Haddad")))
    #expect(app.store.state.profile.displayName == "Noor Haddad")
    #expect(app.store.state.profile.initial == "N")
    #expect(app.store.state.profile.email == before.email)
    #expect(ProfileViewModel(app: app).snapshot.displayName == "Noor Haddad")
    #expect(ProfileViewModel(app: app).snapshot.initial == "N")
    #expect(app.avatarInitial == "N")
  }

  @Test func theInitialIsTheFirstLetter() {
    #expect(ProfileInfo(displayName: "maya", email: "").initial == "M")
    #expect(ProfileInfo(displayName: "\u{2019}Abd al-Rahman", email: "").initial == "A")
    #expect(ProfileInfo(displayName: "-Li", email: "").initial == "L")
    #expect(ProfileInfo(displayName: "\u{0645}\u{0627}\u{064A}\u{0627}", email: "").initial == "\u{0645}")
    #expect(ProfileInfo(displayName: "", email: "").initial == "?")
  }

  @Test func theMockAccountSavesTheNameToo() async throws {
    let account = MockAccountService(existing: .passkey, signedIn: true)
    account.delay = .zero
    #expect(account.capabilities.contains(.changeName))
    #expect(try await account.updateDisplayName(" Noor  Haddad ") == "Noor Haddad")
    #expect(account.profile?.displayName == "Noor Haddad")
    await #expect(throws: AuthFailure.badName) { _ = try await account.updateDisplayName("") }
    #expect(account.profile?.displayName == "Noor Haddad")
  }
}
