import CoreCrypto
import HasalaDesign
import Observation
import SwiftUI

@MainActor
@Observable
final class NameEditModel {
  static let maxLength = 64

  enum Check: Equatable {
    case ok(String)
    case empty
    case tooLong
    case characters

    var message: String? {
      switch self {
      case .ok: nil
      case .empty: "Add your name."
      case .tooLong: "Use \(NameEditModel.maxLength) letters or fewer."
      case .characters: AuthFailure.badName.message
      }
    }
  }

  var text: String
  private(set) var saving = false
  private(set) var failure: String?

  @ObservationIgnored private let current: String
  @ObservationIgnored private let save: (String) async throws(AuthFailure) -> String

  init(current: String, save: @escaping (String) async throws(AuthFailure) -> String) {
    self.current = current
    self.save = save
    text = current
  }

  static func check(_ raw: String) -> Check {
    let folded = NameOK.fold(raw)
    if folded.isEmpty { return .empty }
    if folded.unicodeScalars.count > maxLength { return .tooLong }
    switch DisplayName.validate(raw) {
    case .success(let name): return .ok(name)
    case .failure(.length): return .tooLong
    case .failure(.characters): return .characters
    }
  }

  var canSave: Bool { !saving && NameEditModel.check(text) != .empty }

  var changed: Bool {
    if case .ok(let name) = NameEditModel.check(text) { return name != current }
    return true
  }

  func textChanged() { failure = nil }

  func commit() async -> String? {
    guard !saving else { return nil }
    switch NameEditModel.check(text) {
    case .ok(let name):
      if name == current { return name }
      saving = true
      failure = nil
      defer { saving = false }
      do {
        return try await save(name)
      } catch {
        failure = error.message ?? "That didn't go through. Try again."
        return nil
      }
    case let other:
      failure = other.message
      return nil
    }
  }
}

struct NameEditPage: View {
  @Bindable var app: AppModel
  let session: AccountSession
  @State private var model: NameEditModel
  @FocusState private var focused: Bool

  init(app: AppModel, session: AccountSession) {
    self.app = app
    self.session = session
    let account = session.account
    _model = State(
      initialValue: NameEditModel(
        current: app.store.state.profile.displayName,
        save: { name throws(AuthFailure) in try await account.updateDisplayName(name) }))
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        TextField("Your name", text: $model.text)
          .hType(.body)
          .foregroundStyle(HColor.fieldText)
          .textContentType(.name)
          .textInputAutocapitalization(.words)
          .autocorrectionDisabled()
          .submitLabel(.done)
          .focused($focused)
          .onSubmit { Task { await save() } }
          .onChange(of: model.text) { model.textChanged() }
          .padding(.horizontal, 16)
          .frame(minHeight: 52)
          .background(HColor.fieldSurfaceOnGrouped, in: RoundedRectangle(cornerRadius: HRadius.field, style: .continuous))
          .accessibilityIdentifier("name.field")
        if let failure = model.failure {
          Text(failure)
            .hType(.footnote)
            .foregroundStyle(HColor.statusErrorForeground)
            .padding(.horizontal, 4)
            .accessibilityIdentifier("name.error")
        }
        Text("What Hasala calls you, in the app and in emails.")
          .hType(.footnote)
          .foregroundStyle(HColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 4)
        Button("Save name") { Task { await save() } }
          .buttonStyle(.pill(.primary, fill: true, loading: model.saving))
          .disabled(!model.canSave)
          .accessibilityIdentifier("name.save")
          .padding(.top, 12)
      }
      .padding(HSpacing.insetPage)
    }
    .background(HColor.sheetSurfaceLarge)
    .navigationTitle("Name")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear { focused = true }
  }

  private func save() async {
    guard let saved = await model.commit() else { return }
    if saved != app.store.state.profile.displayName {
      app.perform(.setDisplayName(saved))
      app.say("Name saved")
    }
    if !app.router.profile.isEmpty { app.router.profile.removeLast() }
  }
}
