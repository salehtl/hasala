import HasalaDesign
import SwiftUI

/// Profile › Get help: how to send feedback from TestFlight, and how to reach a person.
struct HelpPage: View {
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        VStack(alignment: .leading, spacing: 14) {
          help("camera.viewfinder", "Send feedback from TestFlight",
               "Take a screenshot in Hasala, then tap Share Beta Feedback. Or open TestFlight, choose Hasala and tap Send Beta Feedback.")
          help("person.2", "Talk to a person",
               "Write to us about anything that isn't working or that you'd like changed. A person reads every email.")
        }
        .padding(18)
        .listCard()
        SupportLink(lead: "Questions, or something not working?", identifier: "help.email", web: false)
        WebLink(title: "Help and support", url: "https://hasala.app/support", identifier: "help.support")
        WebLink(title: "Privacy policy", url: "https://hasala.app/privacy", identifier: "help.privacy")
      }
      .padding(HSpacing.insetPage)
    }
    .background(HColor.surfaceSecondary)
    .navigationTitle("Get help")
    .navigationBarTitleDisplayMode(.inline)
  }

  private func help(_ symbol: String, _ title: String, _ text: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: symbol).foregroundStyle(HColor.iconPrimary).frame(width: 24).accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).hType(.headline).foregroundStyle(HColor.textPrimary)
        Text(text).hType(.subheadline).foregroundStyle(HColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .accessibilityElement(children: .combine)
  }
}
