import Foundation
import HasalaMocks
import HasalaModels
import Testing

@testable import Hasala

@MainActor
@Suite("Your profile setup")
struct UXSetupProfileTests {
  func app() -> AppModel {
    let app = AppModel(store: InMemoryLedger())
    app.router.profile = [.rules]
    return app
  }

  @Test func settingsRowsNameThePageTheyOpen() {
    #expect(ProfileSheet.exchangeRatesTitle == "Exchange rates")
    #expect(ProfileSheet.bankAlertsTitle == "Bank alerts")
  }

  @Test func sortAutomaticallyShowsOnlyOnceSuggestionsAreOn() throws {
    let suite = "ux-setup-profile-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let consent = MerchantSuggestionsConsent(defaults: defaults)
    #expect(!consent.autoSortAvailable)
    consent.request(true)
    #expect(consent.asking == .suggestions)
    consent.turnOn(.suggestions)
    #expect(consent.autoSortAvailable)
    #expect(CloudSuggestionsSection.autoSortLine == "Files a payment by itself when Cloudflare's AI is very sure.")
  }

  @Test func privacyAndDataSitsWithThePrivacySection() {
    #expect(GravatarSection.privacyURL.absoluteString == "https://hasala.app/privacy")
  }

  @Test func addingIsDisabledUntilANameAndCountsAsAreChosen() {
    let m = CategoryEditorModel(app: app(), category: nil)
    #expect(!m.canSave)
    #expect(m.missing == "Add a name")
    m.name = "   "
    #expect(m.missing == "Add a name")
    m.name = String(repeating: "a", count: CategoryLimits.maxName + 1)
    #expect(m.missing == "Keep the name to \(CategoryLimits.maxName) characters")
    m.name = "Coffee"
    #expect(m.missing == "Choose what it counts as")
    #expect(!m.canSave)
    m.parent = "dining"
    #expect(m.missing == nil)
    #expect(m.canSave)
  }

  @Test func editingNeedsOnlyAName() {
    let m = CategoryEditorModel(app: app(), category: "dining")
    #expect(m.canSave)
    m.name = ""
    #expect(!m.canSave)
    #expect(m.missing == "Add a name")
  }

  @Test func hideIsARowThatAsksFirst() {
    let app = app()
    let m = CategoryEditorModel(app: app, category: "dining")
    #expect(m.hideRowTitle == "Hide category")
    m.setHidden(!m.isHidden)
    #expect(m.confirmArchive)
    #expect(app.store.state.category("dining")?.archived == false)
    m.archive()
    #expect(m.hideRowTitle == "Show category")
    m.setHidden(!m.isHidden)
    #expect(app.store.state.category("dining")?.archived == false)
    #expect(m.hideRowTitle == "Hide category")
  }

  @Test func profileTilesAreNeutral() {
    #expect(ProfileSheet.tile(.receipt).hue == nil)
    #expect(ProfileSheet.tile(.bank, square: true).hue == nil)
    #expect(ProfileSheet.tile(.bank, square: true).square)
  }
}
