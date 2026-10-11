import HasalaDesign
import Observation
import SwiftUI

/// The approving iPhone (C9 side A; Paper "Signed-in iPhone · Approve a password reset";
/// spec 04 §6.12): checks the code from the new iPhone, then this iPhone's key approves.
@MainActor
@Observable
final class ResetApprovalModel {
  private let account: AccountService
  let request: PendingReset
  var code = ""
  var busy = false
  var failure: AuthFailure?
  private(set) var approved = false

  init(account: AccountService, request: PendingReset) {
    self.account = account
    self.request = request
  }

  /// 16 characters of `A-Z2-7` once spaces and hyphens are dropped.
  var codeReady: Bool {
    let n = code.uppercased().filter { $0 != " " && $0 != "-" }
    return n.count == 16 && InviteCode.isAlphabet(n)
  }

  func approve() async {
    guard codeReady else { return }
    busy = true
    defer { busy = false }
    do {
      try await account.approveReset(request, code: code)
      approved = true
      failure = nil
    } catch {
      failure = error
    }
  }
}

struct ResetApprovalSheet: View {
  @State private var model: ResetApprovalModel
  var onNotMe: () -> Void
  @Environment(\.dismiss) private var dismiss

  init(model: ResetApprovalModel, onNotMe: @escaping () -> Void) {
    _model = State(initialValue: model)
    self.onNotMe = onNotMe
  }

  var body: some View {
    NavigationStack {
      Group {
        if model.approved {
          AccountScreen(
            title: "Approved",
            subtitle: "Your other iPhone can set a new password now. Your data stays sealed there until it's unlocked.",
            wash: HColor.hueMintStart, centered: true
          ) {
            SuccessBadge().frame(maxWidth: .infinity)
          } footer: {
            Button("Done") { dismiss() }.buttonStyle(.pill(.primary, fill: true))
              .accessibilityIdentifier("approval.done")
          }
        } else {
          AccountScreen(
            title: "Is this you on a new iPhone?",
            subtitle: "An iPhone asked \(model.request.askedAgo). It typed a code we sent to \(model.request.email)."
          ) {
            VStack(alignment: .leading, spacing: 14) {
              NoteCard(systemImage: "exclamationmark.shield",
                       text: "A new iPhone wants to reset your Hasala password. Only continue if you're holding that iPhone now. Scan the code on its screen.",
                       tint: HColor.statusWarningSurface)
              LabeledField(label: "The code on your new iPhone",
                           footer: "16 letters and numbers, under the QR code.") {
                TextField("ABCD EFGH IJKL MNOP", text: $model.code)
                  .font(.system(.body, design: .monospaced).weight(.semibold))
                  .keyboardType(.asciiCapable)
                  .textInputAutocapitalization(.characters)
                  .autocorrectionDisabled()
                  .accessibilityIdentifier("approval.code")
              }
              // TODO(WS-14): the VisionKit QR scanner (spec 04 §6.1.4); typed entry works today.
              FailureBanner(failure: model.failure)
            }
          } footer: {
            BusyButton(title: "Approve with Face ID", busy: model.busy, enabled: model.codeReady,
                       identifier: "approval.approve") {
              Task { await model.approve() }
            }
            LinkButton(title: "No, that's not me", identifier: "approval.notMe", role: .destructive) {
              dismiss()
              onNotMe()
            }
          }
        }
      }
    }
  }
}

/// "Let's lock it down" (Paper "Secure your account"; spec 04 §6.12): an ordered
/// checklist after an unknown sign-in or a reset the user didn't ask for.
struct LockdownView: View {
  let model: SecurityModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Text("Let's lock it down").hType(.title1).foregroundStyle(HColor.textPrimary)
        Text("Do these in order. Each one asks you to confirm it's you.")
          .hType(.body).foregroundStyle(HColor.textSecondary)
        VStack(spacing: 0) {
          step(1, "Sign out everywhere", "Every other device has to sign in again.", "Sign out", "lockdown.signOutAll") {
            Task { await model.request(.signOutEverywhere) }
          }
          Divider().padding(.leading, 60)
          step(2, "Remove what you don't recognise", "Check passkeys and devices in Sign-in & security.", nil,
               "lockdown.review") {}
          Divider().padding(.leading, 60)
          step(3, "Change your password", "If you have one. Also change it on your email account.",
               model.state?.hasPassword == true ? "Change" : nil, "lockdown.password") {
            model.editingPassword = true
          }
          Divider().padding(.leading, 60)
          step(4, "Make new words", "Only if someone may have seen your paper.", nil, "lockdown.words") {}
        }
        .listCard()
        FailureBanner(failure: model.failure)
        if let notice = model.notice { StatusLine(text: notice, tone: .success) }
        Button("Freeze my account") { Task { await model.request(.freeze) } }
          .buttonStyle(.pill(.destructive, fill: true))
          .accessibilityIdentifier("lockdown.freeze")
        WebLink(title: "Talk to a person", url: "https://hasala.app/support", identifier: "lockdown.talk")
      }
      .padding(HSpacing.insetPage)
    }
    .background(HColor.surfaceSecondary)
    .navigationTitle("Secure your account")
    .navigationBarTitleDisplayMode(.inline)
  }

  private func step(_ n: Int, _ title: String, _ text: String, _ action: String?, _ id: String,
                    perform: @escaping () -> Void) -> some View {
    HStack(alignment: .top, spacing: 14) {
      Text("\(n)")
        .hType(.headline)
        .foregroundStyle(HColor.actionAccent)
        .frame(width: 32, height: 32)
        .background(HColor.actionAccentSubtle, in: Circle())
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).hType(.headline).foregroundStyle(HColor.textPrimary)
        Text(text).hType(.footnote).foregroundStyle(HColor.textSecondary).fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 8)
      if let action {
        Button(action, action: perform)
          .buttonStyle(.pill(.secondary, size: .small))
          .accessibilityIdentifier(id)
      }
    }
    .padding(16)
  }
}
