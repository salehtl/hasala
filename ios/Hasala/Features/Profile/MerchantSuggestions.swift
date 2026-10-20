import Foundation
import HasalaDesign
import Observation
import SwiftUI

@MainActor
@Observable
final class MerchantSuggestionsConsent {
  enum Ask: String, Identifiable {
    case suggestions, autoSort
    var id: String { rawValue }
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

struct CloudSuggestionsSection: View {
  @State private var consent = MerchantSuggestionsConsent()

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HSectionHeader("Cloud suggestions")
      ProfileListCard(inset: .icon52) {
        SettingSwitchRow(icon: .wand, title: "Merchant suggestions",
                         isOn: Binding(get: { consent.isOn }, set: { consent.request($0) }))
          .accessibilityIdentifier("profile.merchantSuggestions")
        SettingSwitchRow(icon: .done, title: "Sort automatically",
                         isOn: Binding(get: { consent.autoSortOn }, set: { consent.requestAutoSort($0) }))
          .disabled(!consent.autoSortAvailable)
          .opacity(consent.autoSortAvailable ? 1 : 0.5)
          .accessibilityHint(consent.autoSortAvailable ? "" : "Turn on Merchant suggestions first")
          .accessibilityIdentifier("profile.merchantAutoSort")
      }
      Text("When your rules and Hasala's merchant list can't sort a payment, Cloudflare's AI can suggest a category. Off unless you turn it on.")
        .hType(.footnote)
        .foregroundStyle(HColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 4)
    }
    .sheet(item: Bindable(consent).asking) { ask in
      switch ask {
      case .suggestions:
        CloudConsentSheet(content: .suggestions, turnOn: { consent.turnOn(.suggestions) }, notNow: { consent.notNow() })
      case .autoSort:
        CloudConsentSheet(content: .autoSort, turnOn: { consent.turnOn(.autoSort) }, notNow: { consent.notNow() })
      }
    }
  }
}

struct CloudConsentContent {
  let id: String
  let title: String
  let lead: String
  let points: [(icon: HIcon, title: String, text: String)]

  static let suggestions = CloudConsentContent(
    id: "merchantSuggestions",
    title: "Merchant suggestions",
    lead: "When Hasala can't sort a payment with your rules or its merchant list, it asks Cloudflare's AI service to suggest a category. Apple's on-device model is used when Cloudflare can't help.",
    points: [
      (.tag, "What's sent",
       "The merchant name as it appears in the alert, like \u{201C}CAFE EXAMPLE JBR\u{201D}, and Hasala's built-in category names."),
      (.eyeSlash, "What's not sent",
       "The amount, date, card or bank, your own category names, or anything about your account."),
      (.cloud, "What Cloudflare sees",
       "Your IP address, as with any internet request. The service doesn't record it, and doesn't store or log what you send. Cloudflare's terms say it doesn't keep what you send or use it to train models. Like any website it runs, Cloudflare keeps basic request records, such as the time and the country."),
      (.check, "You stay in charge",
       "Suggestions are marked and don't count in your totals until you confirm them. You can turn this off at any time."),
    ])

  static let autoSort = CloudConsentContent(
    id: "merchantAutoSort",
    title: "Sort automatically",
    lead: "Cloudflare AI will sort a payment by itself only when it is very sure.",
    points: [
      (.done, "Counted right away",
       "Those payments count in your totals right away and are marked \u{201C}Sorted by Cloudflare AI\u{201D}. You can change any of them."),
      (.check, "Everything else",
       "Stays a suggestion for you to confirm. You can turn this off at any time."),
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
            point(p.icon, p.title, p.text)
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

  private func point(_ icon: HIcon, _ title: String, _ text: String) -> some View {
    HStack(alignment: .top, spacing: 14) {
      HIconView(icon, size: HSpacing.iconGlass, color: HColor.listRowIcon, strokeWidth: 1.8)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).hType(.rowTitle).foregroundStyle(HColor.listRowTitle)
        Text(text).hType(.subheadline).foregroundStyle(HColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, HSpacing.listRowInsetInline)
    .padding(.vertical, 14)
    .accessibilityElement(children: .combine)
  }
}
