import HasalaDesign
import SwiftUI

struct AppLockSecuritySection: View {
  @State private var model: AppLockSettingModel
  @Environment(\.openURL) private var openURL

  init(app: AppModel, lock: AppLockController) {
    _model = State(
      initialValue: AppLockSettingModel(
        lock: lock, read: { [app] in app.store.state.prefs.faceIDLock },
        write: { [app] in app.perform(.setFaceIDLock($0)) }))
  }

  var body: some View {
    let setting = model.setting
    VStack(alignment: .leading, spacing: 12) {
      Text("App lock").hType(.section).foregroundStyle(HColor.textPrimary).accessibilityAddTraits(.isHeader)
      HListCard {
        SettingSwitchRow(
          icon: setting.icon, title: setting.title,
          isOn: Binding(get: { model.isOn }, set: { on in Task { await model.setOn(on) } })
        )
        .disabled(model.busy || (!setting.canTurnOn && !model.isOn))
        .accessibilityIdentifier("security.appLock")
      }
      if model.failed {
        Text("That didn't work. Try again.")
          .hType(.footnote)
          .foregroundStyle(HColor.statusErrorForeground)
          .padding(.horizontal, 4)
          .accessibilityIdentifier("security.appLock.failed")
      }
      Text(setting.note)
        .hType(.footnote)
        .foregroundStyle(HColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 4)
        .accessibilityIdentifier("security.appLock.note")
      if setting.offersSettings {
        TextLink(title: "Open Settings", identifier: "security.appLock.settings") {
          if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        }
      }
    }
    .onAppear { model.refresh() }
  }
}
