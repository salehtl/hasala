import HasalaDesign
import HasalaModels
import SwiftUI

struct SortStep: View {
  var model: SetupModel

  static let title = "Sort the rest with Cloudflare AI?"
  static let subtitle =
    "Hasala's merchant list sorts the payments it knows. For the rest, Hasala can ask Cloudflare's AI service, one merchant name at a time. It stays off unless you turn it on."

  static let points: [(icon: HIcon, title: String, text: String)] = [
    (.tag, "Only the merchant name",
     "As it appears in the alert, like \u{201C}CAFE EXAMPLE JBR\u{201D}, with Hasala's built-in category names. Each name is asked about once, not once per payment."),
    (.eyeSlash, "What's not sent",
     "The amount, date, card or bank, your own category names, your name, or anything about your account."),
    (.cloud, "What Cloudflare sees", CloudConsentContent.cloudflareSees),
    (.done, "Filed only when it's very sure",
     "Those payments count in your totals right away and are marked \u{201C}Sorted by Cloudflare AI\u{201D}. The rest wait in Review, as they would anyway, some with a suggestion."),
    (.check, "Yours to change",
     "This turns on Merchant suggestions and Sort automatically on this iPhone. Turn either off at any time in Profile \u{203A} Cloud suggestions."),
  ]

  var body: some View {
    SetupScreen(title: Self.title, subtitle: Self.subtitle, top: 28) {
      VStack(alignment: .leading, spacing: 12) {
        HListCard {
          ForEach(Array(Self.points.enumerated()), id: \.offset) { i, p in
            if i > 0 { HDivider(inset: .icon52) }
            SortPoint(icon: p.icon, title: p.title, text: p.text)
          }
        }
        if model.cloudSortOn {
          Text("On. Hasala sorts a few names at a time while it's open.")
            .hType(.footnote)
            .foregroundStyle(HColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
            .accessibilityIdentifier("sort.on")
        }
      }
      .padding(.horizontal, HSpacing.insetPage)
      .padding(.top, 24)
    } dock: {
      VStack(spacing: 8) {
        if model.cloudSortOn {
          Button("Continue") { model.turnOnCloudSort() }
            .buttonStyle(.pill(.primary, fill: true))
            .accessibilityIdentifier("sort.continue")
        } else {
          Button("Turn on") { model.turnOnCloudSort() }
            .buttonStyle(.pill(.primary, fill: true))
            .accessibilityIdentifier("sort.turnOn")
          Button("Not now") { model.cloudSortNotNow() }
            .buttonStyle(.pill(.secondary, fill: true))
            .accessibilityIdentifier("sort.notNow")
        }
      }
      .padding(.horizontal, HSpacing.insetPage)
      .padding(.top, 8)
    }
  }
}

private struct SortPoint: View {
  let icon: HIcon
  let title: String
  let text: String

  var body: some View {
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
