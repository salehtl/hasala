import SwiftUI

/// Bills · Coming up and found, with its view model kept for as long as it is pushed
/// (from Home's widget, Profile and the bell). `showsToast: false` inside the profile
/// sheet, which hosts its own.
struct BillsScreen: View {
  @Bindable var app: AppModel
  var showsToast = true
  @State private var model: BillsViewModel

  init(app: AppModel, showsToast: Bool = true) {
    self.app = app
    self.showsToast = showsToast
    _model = State(initialValue: BillsViewModel(app: app))
  }

  var body: some View { BillsView(app: app, model: model, showsToast: showsToast) }
}
