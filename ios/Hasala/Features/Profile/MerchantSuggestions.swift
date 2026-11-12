import Foundation
import HasalaDesign
import HasalaModels
import Observation
import SwiftUI

@MainActor
@Observable
final class MerchantSuggestionsConsent {
  enum Ask: String, Identifiable {
    case suggestions, autoSort
    var id: String { rawValue }

    var content: CloudConsentContent {
      switch self {
      case .suggestions: .suggestions
      case .autoSort: .autoSort
      }
    }
  }

  private(set) var isOn: Bool
  private(set) var autoSortOn: Bool
  var asking: Ask?
  @ObservationIgnored private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    isOn = MerchantSuggestionsSetting.isEnabled(defaults)
    autoSortOn = MerchantSuggestionsSetting.isAutoSortEnabled(defaults)
  }

  var autoSortAvailable: Bool { isOn }

  func request(_ on: Bool) {
    if on {
      if !isOn { asking = .suggestions }
    } else {
      if asking != nil { asking = nil }
      MerchantSuggestionsSetting.setEnabled(false, defaults)
      isOn = false
      autoSortOn = false
    }
  }

  func requestAutoSort(_ on: Bool) {
    if on {
      if isOn, !autoSortOn { asking = .autoSort }
    } else {
      if asking == .autoSort { asking = nil }
      MerchantSuggestionsSetting.setAutoSortEnabled(false, defaults)
      autoSortOn = false
    }
  }

  func turnOn(_ ask: Ask) {
    switch ask {
    case .suggestions:
      MerchantSuggestionsSetting.setEnabled(true, defaults)
      isOn = true
    case .autoSort:
      MerchantSuggestionsSetting.setAutoSortEnabled(true, defaults)
      autoSortOn = MerchantSuggestionsSetting.isAutoSortEnabled(defaults)
    }
    asking = nil
  }

  func notNow() {
    asking = nil
  }
}

nonisolated enum CloudSendBack {
  static func title(_ n: Int) -> String {
    "Send \(MoneyFormat.count(n)) \(n == 1 ? "payment" : "payments") back to Review?"
  }

  static let message =
    "Each keeps Cloudflare's suggestion for you to confirm. Ones you've since changed stay put."

  static func done(_ n: Int) -> String {
    n == 0 ? "Nothing to send back" : "Sent \(MoneyFormat.count(n)) \(n == 1 ? "payment" : "payments") back to Review"
  }
}

struct CloudSuggestionsSection: View {
  static let autoSortLine = "Files a payment by itself when Cloudflare's AI is very sure."

  let app: AppModel
  @State private var consent = MerchantSuggestionsConsent()
  @State private var confirmSendBack = false

  private var status: CloudSortStatus? { app.cloudSort?.status }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HSectionHeader("Cloud suggestions")
      ProfileListCard(inset: .icon52) {
        SettingSwitchRow(icon: .wand, title: "Merchant suggestions",
                         isOn: Binding(get: { consent.isOn }, set: { consent.request($0) }))
          .accessibilityIdentifier("profile.merchantSuggestions")
        if consent.autoSortAvailable {
          SettingSwitchRow(icon: .done, title: "Sort automatically", detail: Self.autoSortLine,
                           isOn: Binding(get: { consent.autoSortOn }, set: { consent.requestAutoSort($0) }))
            .accessibilityIdentifier("profile.merchantAutoSort")
        }
        if let status, status.cloudSortedCount > 0 {
          Button { confirmSendBack = true } label: {
            SettingRow(icon: .history, title: "Send Cloudflare's sorting back to Review", chevron: false)
          }
          .buttonStyle(HRowPressStyle())
          .accessibilityAddTraits(.isButton)
          .accessibilityIdentifier("profile.cloudSendBack")
        }
      }
      Text("Cloudflare's AI suggests a category when Hasala can't. Off unless you turn it on.")
        .hType(.footnote)
        .foregroundStyle(HColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 4)
    }
    .task {
      #if HASALA_MOCKS
        await ScreenLaunch.applyCloudConsentLaunch(consent)
      #endif
      await app.cloudSort?.refresh()
    }
    .sheet(item: Bindable(consent).asking) { ask in
      CloudConsentSheet(content: ask.content, turnOn: { consent.turnOn(ask) }, notNow: { consent.notNow() })
    }
    .alert(CloudSendBack.title(status?.cloudSortedCount ?? 0), isPresented: $confirmSendBack) {
      Button("Send back") { sendBack() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(CloudSendBack.message)
    }
  }

  private func sendBack() {
    guard let sort = app.cloudSort else { return }
    let app = self.app
    Task {
      let n = await sort.sendAllBack()
      app.say(CloudSendBack.done(n))
    }
  }
}

struct CloudConsentContent {
  let id: String
  let title: String
  let lead: String
  let points: [(icon: HIcon, title: String, text: String)]

  static let cloudflareSees =
    "Your IP address. The service doesn't record it or keep what you send, and Cloudflare's terms say its AI doesn't keep it or train on it. Cloudflare keeps basic records, like time and country."

  static let suggestions = CloudConsentContent(
    id: "merchantSuggestions",
    title: "Merchant suggestions",
    lead: "When your rules, last picks and Hasala's merchant list can't sort a payment, Hasala asks Cloudflare's AI for a category. Apple's on-device model steps in when Cloudflare can't.",
    points: [
      (.tag, "What's sent",
       "The merchant name, like \u{201C}CAFE EXAMPLE JBR\u{201D} (sent in lower case), built-in categories and app version."),
      (.eyeSlash, "What's not sent",
       "The amount, date, card, bank, your own category names or anything about your account."),
      (.cloud, "What Cloudflare sees", cloudflareSees),
      (.check, "You stay in charge",
       "Suggestions are marked and wait in Review for you. Turn this off any time."),
    ])

  static let autoSort = CloudConsentContent(
    id: "merchantAutoSort",
    title: "Sort automatically",
    lead: "Cloudflare's AI files a payment by itself only when it's very sure.",
    points: [
      (.done, "Counted right away",
       "Marked \u{201C}Sorted by Cloudflare AI\u{201D}, and yours to change."),
      (.check, "Everything else",
       "Stays a suggestion for you to confirm. Turn this off any time."),
    ])
}

struct CloudConsentSheet: View {
  let content: CloudConsentContent
  let turnOn: () -> Void
  let notNow: () -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Text(content.title)
          .hType(HType(size: 22, leading: 28, weight: .bold, tracking: -0.35, textStyle: .title2))
          .foregroundStyle(HColor.textPrimary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityAddTraits(.isHeader)
          .padding(.horizontal, 4)
        Text(content.lead)
          .hType(.subheadline)
          .foregroundStyle(HColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 4)
        HListCard {
          ForEach(Array(content.points.enumerated()), id: \.offset) { i, p in
            if i > 0 { HDivider(inset: .icon52) }
            ProfileInfoRow(icon: p.icon, title: p.title, text: p.text)
          }
        }
      }
      .padding(.horizontal, HSpacing.sheetPadding)
      .padding(.top, 32)
      .padding(.bottom, 16)
    }
    .scrollBounceBehavior(.basedOnSize)
    .safeAreaInset(edge: .bottom) {
      VStack(spacing: 4) {
        Button("Turn on", action: turnOn)
          .buttonStyle(.pill(.primary, fill: true))
          .accessibilityIdentifier("\(content.id).turnOn")
        Button("Not now", action: notNow)
          .buttonStyle(.pill(.tertiary, fill: true))
          .accessibilityIdentifier("\(content.id).notNow")
      }
      .padding(.horizontal, HSpacing.sheetPadding)
      .padding(.top, 8)
      .padding(.bottom, 8)
      .background(HColor.sheetSurfaceLarge)
    }
    .background(HColor.sheetSurfaceLarge)
    .presentationDetents([.large])
    .presentationDragIndicator(.visible)
    .presentationCornerRadius(HRadius.sheetLarge)
    .presentationBackground(HColor.sheetSurfaceLarge)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("\(content.id).sheet")
  }
}
