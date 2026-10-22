import HasalaDesign
import HasalaModels
import SwiftUI

extension CloudConsentContent {
  static let sortTheRest = CloudConsentContent(
    id: "sort",
    title: "Sort the rest with Cloudflare AI?",
    lead: "Hasala's merchant list sorts the payments it knows. For the rest, Hasala can ask Cloudflare's AI service, one merchant name at a time. It stays off unless you turn it on.",
    points: [
      (.tag, "Only the merchant name",
       "As it appears in the alert, like \u{201C}CAFE EXAMPLE JBR\u{201D}, with Hasala's built-in category names. Each name is asked about once, not once per payment."),
      (.eyeSlash, "What's not sent",
       "The amount, date, card or bank, your own category names, your name, or anything about your account."),
      (.cloud, "What Cloudflare sees", CloudConsentContent.cloudflareSees),
      (.done, "Filed only when it's very sure",
       "Those payments count in your totals right away and are marked \u{201C}Sorted by Cloudflare AI\u{201D}. The rest wait in Review, as they would anyway, some with a suggestion."),
      (.check, "Yours to change",
       "This turns on Merchant suggestions and Sort automatically on this iPhone. Turn either off at any time in Profile \u{203A} Cloud suggestions."),
    ])
}

struct CloudSortAskCard: View {
  let turnOn: () -> Void
  let notNow: () -> Void
  @State private var details = false
  @State private var chosen: (() -> Void)?
  @Environment(\.dynamicTypeSize) private var typeSize

  private static let lines: [(icon: HIcon, text: String)] = [
    (.tag, "Sent: only the merchant name, like \u{201C}CAFE EXAMPLE JBR\u{201D}."),
    (.eyeSlash, "Not sent: the amount, date, card, bank, your name or your account."),
    (.done, "Filed only when it's very sure. Off any time in Profile \u{203A} Cloud suggestions."),
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 4) {
        Text(CloudConsentContent.sortTheRest.title)
          .hType(HType.title3.weight(.bold))
          .foregroundStyle(HColor.textPrimary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityAddTraits(.isHeader)
        Text("Hasala can ask Cloudflare's AI about the merchants it doesn't know, one name at a time. Off unless you turn it on.")
          .hType(.footnote)
          .foregroundStyle(HColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      VStack(alignment: .leading, spacing: 10) {
        ForEach(Array(Self.lines.enumerated()), id: \.offset) { _, line in
          HStack(alignment: .top, spacing: 10) {
            HIconView(line.icon, size: 18, color: HColor.listRowIcon, strokeWidth: 1.8)
              .accessibilityHidden(true)
            Text(line.text)
              .hType(.subheadline)
              .foregroundStyle(HColor.textPrimary)
              .fixedSize(horizontal: false, vertical: true)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .accessibilityElement(children: .combine)
        }
      }
      Button { details = true } label: {
        Text("What Cloudflare sees")
          .hType(.subheadline.weight(.medium))
          .foregroundStyle(HColor.textLink)
          .frame(minHeight: HSpacing.targetMinimum)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .padding(.vertical, -8)
      .accessibilityIdentifier("review.cloudSort.details")
      let layout = typeSize.isAccessibilitySize
        ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
      layout {
        Button("Turn on", action: turnOn)
          .buttonStyle(.pill(.primary, fill: true))
          .accessibilityIdentifier("review.cloudSort.turnOn")
        Button("Not now", action: notNow)
          .buttonStyle(.pill(.secondary, fill: true))
          .accessibilityIdentifier("review.cloudSort.notNow")
      }
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background {
      RoundedRectangle(cornerRadius: HRadius.widget, style: .continuous)
        .fill(HColor.widgetSurface)
        .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
        .shadow(color: .black.opacity(0.08), radius: 12, y: 8)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("review.cloudSort")
    .sheet(isPresented: $details, onDismiss: {
      let action = chosen
      chosen = nil
      action?()
    }) {
      CloudConsentSheet(
        content: .sortTheRest,
        turnOn: {
          chosen = turnOn
          details = false
        },
        notNow: {
          chosen = notNow
          details = false
        })
    }
  }
}
