import Foundation
import HasalaCloud
import HasalaMocks
import HasalaModels
import Testing

@testable import Hasala

@MainActor
@Suite("Merchant suggestions")
struct MerchantSuggestionsTests {
  private func freshDefaults() -> UserDefaults {
    let name = "test.merchantSuggestions.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
  }

  @Test func theSettingIsOffByDefault() {
    let d = freshDefaults()
    #expect(!MerchantSuggestionsSetting.isEnabled(d))
    #expect(!MerchantSuggestionsConsent(defaults: d).isOn)
  }

  @Test func theSettingIsStoredOnThisIPhoneAndForgotten() {
    let d = freshDefaults()
    MerchantSuggestionsSetting.setEnabled(true, d)
    #expect(MerchantSuggestionsSetting.isEnabled(d))
    LocalAccountData.forget(defaults: d)
    #expect(!MerchantSuggestionsSetting.isEnabled(d))
  }

  @Test func theReaderRunsOffTheMainActor() async {
    let reader = MerchantSuggestionsSetting.isEnabledReader
    let value = await Task.detached { reader() }.value
    #expect(value == MerchantSuggestionsSetting.isEnabled())
  }

  @Test func autoSortNeedsSuggestions() {
    let d = freshDefaults()
    MerchantSuggestionsSetting.setAutoSortEnabled(true, d)
    #expect(!MerchantSuggestionsSetting.isAutoSortEnabled(d))
    MerchantSuggestionsSetting.setEnabled(true, d)
    #expect(!MerchantSuggestionsSetting.isAutoSortEnabled(d))
    MerchantSuggestionsSetting.setAutoSortEnabled(true, d)
    #expect(MerchantSuggestionsSetting.isAutoSortEnabled(d))
    MerchantSuggestionsSetting.setEnabled(false, d)
    #expect(!MerchantSuggestionsSetting.isAutoSortEnabled(d))
    MerchantSuggestionsSetting.setEnabled(true, d)
    #expect(!MerchantSuggestionsSetting.isAutoSortEnabled(d), "turning suggestions back on leaves auto off")
    MerchantSuggestionsSetting.setAutoSortEnabled(true, d)
    MerchantSuggestionsSetting.forget(d)
    #expect(!MerchantSuggestionsSetting.isEnabled(d))
    #expect(!MerchantSuggestionsSetting.isAutoSortEnabled(d))
  }

  @Test func theAutoSortSwitchWaitsForSuggestions() {
    let d = freshDefaults()
    let consent = MerchantSuggestionsConsent(defaults: d)
    #expect(!consent.autoSortAvailable)
    consent.requestAutoSort(true)
    #expect(consent.asking == nil)
    #expect(!consent.autoSortOn)

    consent.request(true)
    consent.turnOn(.suggestions)
    #expect(consent.autoSortAvailable)
    consent.requestAutoSort(true)
    #expect(consent.asking == .autoSort)
    #expect(!consent.autoSortOn)
    consent.notNow()
    #expect(consent.asking == nil)
    #expect(!consent.autoSortOn)
    #expect(!MerchantSuggestionsSetting.isAutoSortEnabled(d))

    consent.requestAutoSort(true)
    consent.turnOn(.autoSort)
    #expect(consent.autoSortOn)
    #expect(MerchantSuggestionsSetting.isAutoSortEnabled(d))
    #expect(MerchantSuggestionsConsent(defaults: d).autoSortOn)

    consent.requestAutoSort(false)
    #expect(consent.asking == nil)
    #expect(!consent.autoSortOn)
    consent.requestAutoSort(true)
    consent.turnOn(.autoSort)

    consent.request(false)
    #expect(consent.asking == nil)
    #expect(!consent.isOn)
    #expect(!consent.autoSortOn)
    #expect(!consent.autoSortAvailable)
    #expect(!MerchantSuggestionsSetting.isAutoSortEnabled(d))
  }

  @Test func aRefusalLastsUntilTheAppVersionChanges() {
    let name = "test.merchantSuggestions.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    defer { d.removePersistentDomain(forName: name) }
    let current = MerchantSuggestionsSetting.appVersion(marketing: "1.4", build: "261020.1")
    #expect(current == "1.4 (261020.1)")
    let record = MerchantSuggestionsSetting.refusal(version: current, suiteName: name)
    #expect(!record.isRecorded())
    record.record()
    #expect(record.isRecorded())
    #expect(MerchantSuggestionsSetting.isRefused(version: current, d))
    #expect(MerchantSuggestionsSetting.refusal(version: current, suiteName: name).isRecorded())
    let newBuild = MerchantSuggestionsSetting.appVersion(marketing: "1.4", build: "261021.1")
    let newMarketing = MerchantSuggestionsSetting.appVersion(marketing: "1.5", build: "261020.1")
    #expect(!MerchantSuggestionsSetting.refusal(version: newBuild, suiteName: name).isRecorded())
    #expect(!MerchantSuggestionsSetting.refusal(version: newMarketing, suiteName: name).isRecorded())
    MerchantSuggestionsSetting.setEnabled(true, d)
    #expect(MerchantSuggestionsSetting.isEnabled(d))
  }

  @Test func aRecordedRefusalKeepsTheCloudModelOff() throws {
    let name = "test.merchantSuggestions.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    defer { d.removePersistentDomain(forName: name) }
    let version = MerchantSuggestionsSetting.appVersion(marketing: "1.4", build: "261020.1")
    MerchantSuggestionsSetting.recordRefusal(version: version, d)
    let made = HasalaCloudFactory.makeCategoryModel(
      baseURL: URL(string: "https://assist.example.test"), clientVersion: "1.4", isEnabled: { true },
      isAutoFileEnabled: { false }, refusal: MerchantSuggestionsSetting.refusal(version: version, suiteName: name))
    let model = try #require(made)
    #expect(model.availability() == .notEligible)
    let stages = ModelSuggestionStage.stages(onDevice: model, cloud: model, onDeviceAlone: false)
    #expect(stages.count == 1 && stages.allSatisfy { !$0.leavesDevice })
  }

  @Test func theAutoSortReaderRunsOffTheMainActor() async {
    let reader = MerchantSuggestionsSetting.isAutoSortEnabledReader
    let value = await Task.detached { reader() }.value
    #expect(value == MerchantSuggestionsSetting.isAutoSortEnabled())
  }

  @Test func anIPhoneThatFinishedTheOldSetupCountsAsAnswered() {
    let old = freshDefaults()
    MerchantSuggestionsSetting.migrateReviewAsk(setupFinished: true, old)
    #expect(MerchantSuggestionsSetting.reviewAskAnswered(old) && !MerchantSuggestionsSetting.isEnabled(old))
    let fresh = freshDefaults()
    MerchantSuggestionsSetting.migrateReviewAsk(setupFinished: false, fresh)
    MerchantSuggestionsSetting.migrateReviewAsk(setupFinished: true, fresh)
    #expect(!MerchantSuggestionsSetting.reviewAskAnswered(fresh))
  }

  @Test func notNowKeepsTheSwitchOff() {
    let d = freshDefaults()
    let consent = MerchantSuggestionsConsent(defaults: d)
    consent.request(true)
    #expect(consent.asking == .suggestions)
    #expect(!consent.isOn)
    #expect(!MerchantSuggestionsSetting.isEnabled(d))
    consent.notNow()
    #expect(consent.asking == nil)
    #expect(!consent.isOn)
    #expect(!MerchantSuggestionsSetting.isEnabled(d))
  }

  @Test func onlyTurnOnTurnsItOn() {
    let d = freshDefaults()
    let consent = MerchantSuggestionsConsent(defaults: d)
    consent.request(true)
    consent.turnOn(.suggestions)
    #expect(consent.asking == nil)
    #expect(consent.isOn)
    #expect(MerchantSuggestionsSetting.isEnabled(d))
    #expect(MerchantSuggestionsConsent(defaults: d).isOn)
  }

  @Test func turningItOffAsksNothing() {
    let d = freshDefaults()
    MerchantSuggestionsSetting.setEnabled(true, d)
    let consent = MerchantSuggestionsConsent(defaults: d)
    consent.request(false)
    #expect(consent.asking == nil)
    #expect(!consent.isOn)
    #expect(!MerchantSuggestionsSetting.isEnabled(d))
    consent.request(true)
    #expect(consent.asking == .suggestions)
  }

  @Test func theAssistURLIsHTTPSOrNothing() {
    #expect(BuildInfo.assistURL("https://assist.hasala.app")?.absoluteString == "https://assist.hasala.app")
    #expect(BuildInfo.assistURL(" https://assist.hasala.app ")?.host() == "assist.hasala.app")
    for bad: Any? in [nil, "", "   ", "$(HASALA_ASSIST_BASE_URL)", "http://assist.hasala.app", "assist.hasala.app",
                      "https://", 42] {
      #expect(BuildInfo.assistURL(bad) == nil)
    }
  }

  @Test func theBuildCarriesTheAssistURL() throws {
    #expect(BuildInfo.assistBaseURL()?.absoluteString == "https://assist.hasala.app")
    #expect(BuildSurface.showsCloudSuggestions)
    var info = Bundle.main.infoDictionary ?? [:]
    info["HasalaAssistBaseURL"] = nil
    #expect(try BuildInfo(infoDictionary: info).assistBaseURL == nil)
  }

  @Test func theLabelNamesWhereTheSuggestionCameFrom() {
    #expect(CategorySource.suggestionLabel(modelTag: "cf-clef/1") == "Suggested by Cloudflare AI")
    #expect(CategorySource.suggestionLabel(modelTag: "apple-fm/1") == "Suggested on this iPhone")
    #expect(CategorySource.suggestionLabel(modelTag: nil) == "Suggested on this iPhone")
    #expect(CategorySource.suggestionLabel(modelTag: "other/2") == "Suggested")
    #expect(CategorySource.suggestionLabel(modelTag: "cf-clef/1", needsReview: true) == "Suggested by Cloudflare AI")
    #expect(CategorySource.suggestionLabel(modelTag: "cf-clef/1", needsReview: false) == "Sorted by Cloudflare AI")
    #expect(CategorySource.suggestionLabel(modelTag: "apple-fm/1", needsReview: false) == "Suggested on this iPhone")
    #expect(CategorySource.model(tag: "cf-clef/2").suggestionLabel() == "Suggested by Cloudflare AI")
    #expect(CategorySource.model(tag: "cf-clef/2").suggestionLabel(needsReview: false) == "Sorted by Cloudflare AI")
    #expect(CategorySource.dictionary.suggestionLabel() == nil)
    #expect(CategorySource.user.suggestionLabel(needsReview: false) == nil)
  }

  @Test func theMayaCloudSuggestionIsMarked() throws {
    let s = MayaLedger.state
    let lulu = try #require(s.txn("lulu"))
    #expect(lulu.categorySource == .model(tag: "cf-clef/1"))
    let card = ReviewEngine.card(lulu, s)
    #expect(card.suggestion?.id == "groceries")
    #expect(card.suggestedBy == "Suggested by Cloudflare AI")
    let detail = try #require(TransactionEngine.detail("lulu", s, now: MayaLedger.now))
    #expect(detail.sortedBy?.title == "Suggested by Cloudflare AI")
    #expect(detail.sortedBy?.detail == "Lulu Hypermarket → Groceries")

    var onDevice = lulu
    onDevice.categoryID = "groceries"
    onDevice.suggestion = nil
    onDevice.categorySource = .model(tag: "apple-fm/1")
    #expect(ReviewEngine.card(onDevice, s).suggestedBy == "Suggested on this iPhone")

    var sorted = lulu
    sorted.categoryID = "groceries"
    sorted.suggestion = nil
    sorted.needsReview = false
    var auto = s
    auto.txns = s.txns.map { $0.id == "lulu" ? sorted : $0 }
    #expect(!sorted.inReview)
    let sortedDetail = try #require(TransactionEngine.detail("lulu", auto, now: MayaLedger.now))
    #expect(sortedDetail.sortedBy?.title == "Sorted by Cloudflare AI")
    #expect(sortedDetail.sortedBy?.detail == "Lulu Hypermarket → Groceries")
    #expect(TransactionSheet.showsSource(try #require(sortedDetail.sortedBy)))

    var corrected = sorted
    _ = try LiveLedgerStore.patch(.categorize(corrected.id, "dining", learnRule: false, project: nil), &auto, now: MayaLedger.now)
    corrected = try #require(auto.txn("lulu"))
    #expect(corrected.categorySource == .user)
    #expect(TransactionEngine.detail("lulu", auto, now: MayaLedger.now)?.sortedBy?.title == "Sorted by you")

    let starbucks = try #require(s.txn("starbucks"))
    #expect(ReviewEngine.card(starbucks, s).suggestedBy == nil)
  }
}
