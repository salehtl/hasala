import HasalaDesign
import HasalaModels
import SwiftUI

/// Profile › Get help: how to send feedback from TestFlight, and how to reach a person. Paper
/// draws no Get help page; this one is built from the profile's own parts (a white card of
/// rows on the large sheet's grey).
struct HelpPage: View {
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        HListCard {
          ProfileInfoRow(icon: .phone, title: "Send feedback from TestFlight",
                         text: "Take a screenshot in Hasala, then tap Share Beta Feedback. Or open TestFlight, choose Hasala and tap Send Beta Feedback.")
          HDivider(inset: .icon52)
          ProfileInfoRow(icon: .chat, title: "Talk to a person",
                         text: "Write to us about anything that isn't working or that you'd like changed. A person reads every email.")
        }
        SupportLink(lead: "Questions, or something not working?", identifier: "help.email", web: false)
        WebLink(title: "Help and support", url: "https://hasala.app/support", identifier: "help.support")
        WebLink(title: "Privacy policy", url: "https://hasala.app/privacy", identifier: "help.privacy")
      }
      .padding(.horizontal, HSpacing.sheetPadding)
      .padding(.top, 8)
      .padding(.bottom, 48)
    }
    .background(HColor.sheetSurfaceLarge)
    .navigationTitle("Get help")
    .navigationBarTitleDisplayMode(.inline)
  }
}

/// Settings › Notifications (spec 04 §16.2 X2; Debug only until notifications exist): one of
/// three levels, ticked, and what Important only keeps (page 18).
struct NotificationSettingsPage: View {
  let model: any ProfileModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        HListCard {
          ForEach(Array(DevicePrefs.NotificationLevel.allCases.enumerated()), id: \.element) { index, level in
            if index > 0 { HDivider(inset: .text16) }
            let selected = model.snapshot.prefs.notifications == level
            Button { model.setNotifications(level) } label: {
              HListRow(title: level.label, trailing: .check(selected))
            }
            .buttonStyle(HRowPressStyle())
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("notifications.\(level.rawValue)")
          }
        }
        Text("Important only keeps everything except new transactions under AED 100 and the daily sorting nudge. Turning it off adds both back. The Lock Screen stays generic unless you choose otherwise.")
          .hType(.footnote).foregroundStyle(HColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 4)
      }
      .padding(.horizontal, HSpacing.sheetPadding)
      .padding(.top, 8)
      .padding(.bottom, 48)
    }
    .background(HColor.sheetSurfaceLarge)
    .navigationTitle("Notifications")
    .navigationBarTitleDisplayMode(.inline)
  }
}
