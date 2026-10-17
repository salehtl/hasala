import HasalaDesign
import HasalaModels
import SwiftUI

extension EnvironmentValues {
  /// Everything the account holds as a CSV, for "Keep a copy first" on Delete account; the
  /// host that has the ledger provides it. Without it the card isn't shown (no control that
  /// leads nowhere).
  @Entry var accountExport: CSVFile? = nil
}

/// Profile › Delete your account and Sign-in & security › Delete your account (Paper P2.5
/// IAM "updated copy"), pushed inside the profile's large sheet; reachable from the profile
/// itself as App Review asks (Guideline 5.1.1(v)). What deleting does, a copy to keep first,
/// then "Delete my account": the alert asks once (page 14: deleting touches access), then
/// "Confirm it's you" (Face ID, or the password and this iPhone's key) runs
/// `AccountService.perform(.deleteAccount, password:)`. Once it succeeds the session signs
/// out and the account gate shows the welcome screens.
struct DeleteAccountView: View {
  @State private var model: SecurityModel
  private let session: AccountSession
  @State private var asking = false
  @Environment(\.accountExport) private var export
  @Environment(\.dismiss) private var dismiss

  init(session: AccountSession) {
    self.session = session
    _model = State(initialValue: SecurityModel(session: session))
  }

  /// How this account confirms: the state once read, else how it signed in.
  private var confirmsWithFaceID: Bool {
    model.state?.hasPasskey ?? (session.account.profile?.method != .password)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        VStack(alignment: .leading, spacing: 6) {
          Text("What happens when you delete")
            .hType(.title1)
            .foregroundStyle(HColor.textPrimary)
            .accessibilityAddTraits(.isHeader)
          Text(confirmsWithFaceID
            ? "This can't be undone. You'll confirm with Face ID."
            : "This can't be undone. You'll confirm with your password.")
            .hType(.subheadline)
            .foregroundStyle(HColor.textSecondary)
            .accessibilityIdentifier("delete.subtitle")
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding([.top, .horizontal], 4)
        VStack(alignment: .leading, spacing: 14) {
          item(.trash, "Your budget, plan and rules are erased here and on our server.")
          item(.mailX, "Hasala's read-only access to your mailboxes is removed straight away.")
          item(.clock, "Your sealed backup is gone from our backups within 30 days.")
          item(.linkOff, "Your passkeys and password stop working.")
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
        if let export { keepACopy(export) }
        if model.confirming == nil { FailureBanner(failure: model.failure) }
      }
      .padding(.horizontal, HSpacing.insetPage)
      .padding(.top, 8)
      .padding(.bottom, 16)
    }
    .scrollBounceBehavior(.basedOnSize)
    .scrollEdgeEffectStyle(.soft, for: .bottom)
    .safeAreaBar(edge: .bottom) {
      VStack(spacing: 6) {
        Button("Delete my account") { asking = true }
          .buttonStyle(.pill(.destructive, fill: true))
          .accessibilityIdentifier("delete.confirm")
        Button { dismiss() } label: {
          Text("Cancel")
            .hType(.button)
            .foregroundStyle(HColor.textLink)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("delete.cancel")
      }
      .padding(.horizontal, HSpacing.insetPage)
      .padding(.top, 8)
    }
    .background(HColor.surfaceSecondary)
    .navigationTitle("Delete account")
    .navigationBarTitleDisplayMode(.inline)
    .task { await model.load() }
    .confirmSheet(model)
    .alert("Delete your Hasala account?", isPresented: $asking) {
      Button("Cancel", role: .cancel) {}
      Button("Delete", role: .destructive) { Task { await delete() } }
    } message: {
      Text("Everything is erased. This can't be undone.")
    }
  }

  /// The step-up depends on whether the account has a passkey, which `load()` reads; a
  /// first load that failed (offline) is tried again here.
  private func delete() async {
    if model.state == nil { await model.load() }
    guard model.state != nil else { return }
    await model.request(.deleteAccount)
  }

  private func item(_ icon: HIcon, _ text: String) -> some View {
    HStack(alignment: .top, spacing: 14) {
      HIconView(icon, size: 22, color: HColor.actionDestructive)
      Text(text)
        .hType(.callout)
        .foregroundStyle(HColor.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityElement(children: .combine)
  }

  /// "Keep a copy first" (Paper "Card · Keep a copy first"): the info surface, radius 20,
  /// and the on-grouped export button.
  private func keepACopy(_ file: CSVFile) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Keep a copy first").hType(.headline).foregroundStyle(HColor.textPrimary)
        Text("Download everything as a CSV file.").hType(.subheadline).foregroundStyle(HColor.textSecondary)
      }
      ShareLink(item: file, preview: SharePreview(file.name)) {
        Text("Export your data (CSV)")
      }
      .buttonStyle(.pill(.onGrouped, size: .medium, fill: true, leadingIcon: .download))
      .accessibilityIdentifier("delete.export")
    }
    .padding(.top, 18)
    .padding(.horizontal, 20)
    .padding(.bottom, 20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(HColor.statusInfoSurface, in: RoundedRectangle(cornerRadius: HRadius.tile, style: .continuous))
  }
}
