import HasalaDesign
import SwiftUI

/// Sign-in & security (Paper "Profile · Sign-in & security", passkey and password-only
/// boards; spec 04 §6.9).
struct SecurityView: View {
  @State private var model: SecurityModel
  @State private var alert: PendingAlert?
  @State private var deleting = false

  init(session: AccountSession) {
    _model = State(initialValue: SecurityModel(session: session))
  }

  /// The system alerts (Paper "Alerts · remove a passkey / device / sign out").
  enum PendingAlert: Identifiable {
    case removePasskey(PasskeyRow)
    case removeDevice(DeviceRow)
    case removePassword
    case signOut
    case signOutEverywhere
    case freeze

    var id: String {
      switch self {
      case .removePasskey(let p): "pk.\(p.id)"
      case .removeDevice(let d): "dev.\(d.id)"
      case .removePassword: "pw"
      case .signOut: "out"
      case .signOutEverywhere: "outAll"
      case .freeze: "freeze"
      }
    }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        if let s = model.state {
          hero(s)
          if let notice = model.notice {
            StatusLine(text: notice, tone: .success)
          }
          FailureBanner(failure: model.failure)
          section("Email") { emailCard(s) }
          if s.hasPasskey { section("Passkeys", footer: "A passkey signs you in and unlocks your data. iCloud Keychain keeps it on all your Apple devices.") { passkeys(s) } }
          else if can(.addPasskey) { section("Passkeys", footer: "A passkey would make sign-in one glance, and it can unlock your data on a new iPhone.") { addPasskeyRow } }
          section("Password", footer: passwordFooter(s)) { passwordCard(s) }
          section("Devices") { devices(s) }
          section("Recovery phrase", footer: phraseFooter(s)) { phrase(s) }
          footerActions(s)
        } else if model.failure != nil {
          FailureBanner(failure: model.failure)
        } else {
          ProgressView().frame(maxWidth: .infinity, minHeight: 200)
        }
      }
      .padding(HSpacing.insetPage)
      .disabled(model.busy)
    }
    .background(HColor.surfaceSecondary)
    .navigationTitle("Sign-in & security")
    .navigationBarTitleDisplayMode(.inline)
    .overlay { if model.busy { ProgressView().controlSize(.large) } }
    .task { await model.load() }
    .confirmSheet(model)
    .sheet(isPresented: $model.editingPassword) {
      PasswordEditSheet(model: model)
    }
    .fullScreenCover(isPresented: Binding(get: { model.viewedPhrase != nil }, set: { if !$0 { model.closePhrase() } })) {
      NavigationStack {
        PhraseShowView(revealed: $model.phraseRevealed, words: model.viewedPhrase ?? [], mode: .view,
                       onBack: model.closePhrase, onContinue: model.closePhrase)
      }
    }
    .navigationDestination(isPresented: $deleting) {
      DeleteAccountForm {
        // Back to Sign-in & security first, so a password sheet can present over it.
        deleting = false
        Task { await model.request(.deleteAccount) }
      }
    }
    .alert(item: $alert) { a in alertFor(a) }
  }


  /// Whether this build offers `action` (spec: only actions in `capabilities` are shown).
  private func can(_ action: AccountCapabilities) -> Bool { model.capabilities.contains(action) }

  // MARK: Sections

  private func hero(_ s: SecurityState) -> some View {
    let frozen = s.frozen != nil
    let protected = s.hasPasskey
    return HStack(alignment: .top, spacing: 14) {
      Image(systemName: frozen ? "snowflake" : protected ? "checkmark" : "key")
        .font(.system(size: 20, weight: .semibold))
        .foregroundStyle(frozen ? HColor.statusInfoForeground : protected ? HColor.statusSuccessForeground : HColor.statusWarningForeground)
        .frame(width: 56, height: 56)
        .background(HColor.white.opacity(0.7), in: Circle())
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        Text(frozen ? "Frozen" : protected ? "Protected" : "Password only")
          .hType(.title2)
          .foregroundStyle(frozen ? HColor.statusInfoForeground : protected ? HColor.statusSuccessForeground : HColor.statusWarningForeground)
        Text(frozen
          ? (s.frozen?.by == .operator
            ? "We froze your account to protect it. Talk to us to unfreeze it."
            : can(.freeze)
              ? "Your account is frozen. Confirm it's you to unfreeze it."
              : "Your account is frozen.")
          : protected
            ? "Passkey and 12 words are set. Last sign-in \(s.lastSignIn)."
            : can(.addPasskey)
              ? "Your 12 words are set. A passkey would make sign-in one glance."
              : "Your password and 12 words are set. Last sign-in \(s.lastSignIn).")
          .hType(.subheadline)
          .foregroundStyle(HColor.textPrimary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(frozen ? HColor.statusInfoSurface : protected ? HColor.statusSuccessSurface : HColor.statusWarningSurface,
                in: RoundedRectangle(cornerRadius: HRadius.listGroup, style: .continuous))
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("security.hero")
  }

  private func section<C: View>(_ title: String, footer: String? = nil, @ViewBuilder _ content: () -> C) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title).hType(.title3).foregroundStyle(HColor.textPrimary).accessibilityAddTraits(.isHeader)
      VStack(spacing: 0) { content() }.listCard()
      if let footer {
        Text(footer).hType(.footnote).foregroundStyle(HColor.textSecondary).fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 4)
      }
    }
  }

  private func row<T: View>(_ symbol: String, _ title: String, _ detail: String?, tint: Color = HColor.actionAccentSubtle,
                            ink: Color = HColor.actionAccent, titleLabel: String? = nil,
                            @ViewBuilder trailing: () -> T) -> some View {
    HStack(alignment: .top, spacing: 14) {
      IconDisc(systemImage: symbol, tint: tint, ink: ink)
      // The action moves under the text when both don't fit (spec 04 §17).
      ReflowingRow {
        VStack(alignment: .leading, spacing: 2) {
          Text(title).hType(.headline).foregroundStyle(HColor.textPrimary)
            .lineLimitAtDefaultTextSize(1)
            .truncationMode(.middle)
            .accessibilityLabel(titleLabel ?? title)
          if let detail { Text(detail).hType(.footnote).foregroundStyle(HColor.textSecondary) }
        }
        .accessibilityElement(children: .combine)
      } trailing: {
        trailing()
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .frame(minHeight: 64)
  }

  private func emailCard(_ s: SecurityState) -> some View {
    row("envelope", s.email, s.emailVerified ? "Verified · codes and alerts" : "Not verified yet",
        titleLabel: "Email address \(s.email)") {
      // TODO(spec 04 §6.9, C6): the email-change ceremony; the capability stays off until it exists.
      if can(.changeEmail) {
        Button("Change") { model.failure = .notInThisBuild }
          .buttonStyle(.pill(.secondary, size: .small))
          .accessibilityIdentifier("security.changeEmail")
      }
    }
  }

  private func passkeys(_ s: SecurityState) -> some View {
    Group {
      ForEach(s.passkeys) { p in
        row("person.badge.key", p.provider, p.detail) {
          if can(.removePasskey), s.passkeys.count > 1 || s.hasPassword {
            Button("Remove", role: .destructive) { alert = .removePasskey(p) }
              .hType(.rowTitle)
              .foregroundStyle(HColor.actionDestructive)
              .accessibilityIdentifier("security.removePasskey.\(p.id)")
          }
        }
        if can(.addPasskey) || p.id != s.passkeys.last?.id { Divider().padding(.leading, 70) }
      }
      if can(.addPasskey) { addPasskeyRow }
    }
  }

  private var addPasskeyRow: some View {
    Button {
      Task { await model.request(.addPasskey) }
    } label: {
      HStack(spacing: 14) {
        IconDisc(systemImage: "plus")
        Text("Add a passkey").hType(.headline).foregroundStyle(HColor.textLink)
        Spacer()
      }
      .padding(.horizontal, 16)
      .frame(minHeight: 60)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("security.addPasskey")
  }

  private func passwordFooter(_ s: SecurityState) -> String {
    s.hasPasskey
      ? "A password never unlocks your data. On a new iPhone you'd still need a passkey or your 12 words."
      : can(.addPasskey)
        ? "It's your only way to sign in, so it can't be removed until you add a passkey. It never unlocks your data."
        : "It's your only way to sign in. It never unlocks your data."
  }

  private func phraseFooter(_ s: SecurityState) -> String {
    guard s.hasPasskey else {
      return "Your recovery phrase can't be shown again on this account. Keep the copy you wrote down."
    }
    return can(.rotatePhrase)
      ? "We can't see or reset your words. Viewing them emails you; new words replace the old ones everywhere."
      : "We can't see or reset your words. Viewing them emails you."
  }

  private func passwordCard(_ s: SecurityState) -> some View {
    Group {
      if let changed = s.passwordChanged {
        row("ellipsis.rectangle", "Password", changed, tint: HColor.surfaceSecondary, ink: HColor.iconPrimary) {
          if can(.changePassword) {
            Button("Change") { model.editingPassword = true }
              .buttonStyle(.pill(.secondary, size: .small))
              .accessibilityIdentifier("security.changePassword")
          }
        }
        if s.hasPasskey, can(.changePassword) {
          Divider().padding(.leading, 70)
          LinkButton(title: "Remove password", identifier: "security.removePassword", role: .destructive) {
            alert = .removePassword
          }
        }
      } else {
        row("ellipsis.rectangle", "No password",
            can(.changePassword) ? "Optional. Signs you in where Face ID can't." : "You sign in with your passkey.",
            tint: HColor.surfaceSecondary, ink: HColor.iconPrimary) {
          if can(.changePassword) {
            Button("Set one") { model.editingPassword = true }
              .buttonStyle(.pill(.secondary, size: .small))
              .accessibilityIdentifier("security.setPassword")
          }
        }
      }
    }
  }

  private func devices(_ s: SecurityState) -> some View {
    ForEach(Array(s.devices.enumerated()), id: \.element.id) { i, d in
      if i > 0 { Divider().padding(.leading, 70) }
      row("iphone", d.title, d.detail, tint: d.isThisDevice ? HColor.statusSuccessSurface : HColor.surfaceSecondary,
          ink: d.isThisDevice ? HColor.statusSuccessForeground : HColor.iconPrimary) {
        if d.isThisDevice {
          StatusLine(text: "You", tone: .success)
        } else if can(.removeDevice) {
          Button("Remove", role: .destructive) { alert = .removeDevice(d) }
            .hType(.rowTitle)
            .foregroundStyle(HColor.actionDestructive)
            .accessibilityIdentifier("security.removeDevice.\(d.id)")
        }
      }
    }
  }

  private func phrase(_ s: SecurityState) -> some View {
    Group {
      if s.hasPasskey, can(.viewPhrase) {
        Button {
          Task { await model.viewPhrase() }
        } label: {
          row("doc.text", "View your 12 words", "\(s.phraseConfirmed) · Asks for Face ID",
              tint: HColor.huePeachStart, ink: HColor.huePeachInk) {
            Image(systemName: "chevron.right").foregroundStyle(HColor.listRowChevron)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("security.viewPhrase")
      } else {
        row("doc.text", "Recovery phrase", s.phraseConfirmed, tint: HColor.huePeachStart, ink: HColor.huePeachInk) {
          EmptyView()
        }
      }
      // TODO(spec 04 §6.2 C7): the rotation ceremony; the capability stays off until it exists.
      if can(.rotatePhrase) {
        Divider().padding(.leading, 70)
        LinkButton(title: "Make new words", identifier: "security.newWords") { model.failure = .notInThisBuild }
      }
    }
  }

  private func footerActions(_ s: SecurityState) -> some View {
    VStack(spacing: 6) {
      if can(.signOut) {
        Button("Sign out of this iPhone", role: .destructive) { alert = .signOut }
          .buttonStyle(.pill(.tertiary, fill: true))
          .foregroundStyle(HColor.actionDestructive)
          .accessibilityIdentifier("security.signOut")
      }
      if can(.signOutEverywhere) {
        LinkButton(title: "Sign out everywhere", identifier: "security.signOutEverywhere") { alert = .signOutEverywhere }
      }
      if let frozen = s.frozen {
        // Only the operator lifts an operator freeze (spec 04 §6.11): no Unfreeze then.
        if frozen.by == .holder, can(.freeze) {
          Button("Unfreeze") { Task { await model.request(.unfreeze) } }
            .buttonStyle(.pill(.primary, fill: true))
            .accessibilityIdentifier("security.unfreeze")
        } else {
          WebLink(title: "Talk to a person", url: "https://hasala.app/support", identifier: "security.frozenTalk")
        }
      } else if can(.freeze) {
        LinkButton(title: "Freeze my account", identifier: "security.freeze") { alert = .freeze }
      }
      if model.offersLockdown {
        NavigationLink {
          LockdownView(model: model)
        } label: {
          Text("Something not right? Lock it down")
            .hType(.button)
            .foregroundStyle(HColor.textLink)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .accessibilityIdentifier("security.lockdown")
      }
      if can(.deleteAccount) {
        LinkButton(title: "Delete your account", identifier: "security.delete", role: .destructive) { deleting = true }
      }
      if model.lacksAnAction {
        SupportLink(lead: "Need a change that isn't here?", identifier: "security.support")
      }
      Text(s.hasPasskey ? "Changes here ask for Face ID first." : "Changes here ask for your password, and this iPhone signs them too.")
        .hType(.footnote)
        .foregroundStyle(HColor.textSecondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }
    .padding(.top, 8)
  }

  private func alertFor(_ a: PendingAlert) -> Alert {
    switch a {
    case .removePasskey(let p):
      return Alert(title: Text("Remove this passkey?"),
                   message: Text("\(p.provider) will no longer sign you in to Hasala."),
                   primaryButton: .destructive(Text("Remove")) { Task { await model.request(.removePasskey(id: p.id)) } },
                   secondaryButton: .cancel())
    case .removeDevice(let d):
      return Alert(title: Text("Remove this device?"),
                   message: Text("\(d.title) (\(d.detail)) is signed out and can't sync any more. Its data stays on it until it's erased there."),
                   primaryButton: .destructive(Text("Remove")) { Task { await model.request(.removeDevice(id: d.id)) } },
                   secondaryButton: .cancel())
    case .removePassword:
      return Alert(title: Text("Remove your password?"), message: Text("You'll sign in with your passkey only."),
                   primaryButton: .destructive(Text("Remove")) { Task { await model.request(.removePassword) } },
                   secondaryButton: .cancel())
    case .signOut:
      return Alert(title: Text("Sign out of this iPhone?"),
                   message: Text("You'll need your passkey or password to sign back in. Your data stays on this iPhone."),
                   primaryButton: .destructive(Text("Sign out")) { Task { await model.signOut() } },
                   secondaryButton: .cancel())
    case .signOutEverywhere:
      return Alert(title: Text("Sign out everywhere?"),
                   message: Text("Every device is signed out, this iPhone too. Your data stays on each one; sign in again to carry on."),
                   primaryButton: .destructive(Text("Sign out everywhere")) { Task { await model.request(.signOutEverywhere) } },
                   secondaryButton: .cancel())
    case .freeze:
      return Alert(title: Text("Freeze your account?"),
                   message: Text("Everyone will be signed out. No one can use your account with a password, reset the password or use the recovery phrase until you confirm it's you with a passkey, or with your password on one of your iPhones."),
                   primaryButton: .destructive(Text("Freeze my account")) { Task { await model.request(.freeze) } },
                   secondaryButton: .cancel())
    }
  }
}

/// "Confirm it's you" for a password-only account (Paper "Confirm · Password user"):
/// the password plus this iPhone's key (spec 04 §6.3).
struct ConfirmSheet: View {
  var action: SecurityAction
  @Binding var password: String
  var onConfirm: () -> Void
  var onCancel: () -> Void
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    sheet
      .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.medium, .large])
  }

  private var sheet: some View {
    NavigationStack {
      // Scrolls, with Confirm pinned below: at the accessibility text sizes the content
      // outgrows a medium sheet and Confirm must stay reachable.
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          Text(action.explainer).hType(.title2).foregroundStyle(HColor.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
          LabeledField(label: "Current password") {
            PasswordInput(placeholder: "Your password", text: $password, isNew: false, identifier: "confirm.password")
          }
          HStack(spacing: 12) {
            IconDisc(systemImage: "iphone", size: 32)
            Text("This iPhone signs it too · its own key, never sent").hType(.footnote).foregroundStyle(HColor.textSecondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .padding(HSpacing.insetPage)
      }
      .safeAreaInset(edge: .bottom) {
        Button("Confirm", action: onConfirm)
          .buttonStyle(.pill(password.isEmpty ? .tertiary : .primary, fill: true))
          .disabled(password.isEmpty)
          .accessibilityIdentifier("confirm.submit")
          .padding(HSpacing.insetPage)
          .background(HColor.surfaceSecondary)
      }
      .background(HColor.surfaceSecondary)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button(role: .close, action: onCancel).accessibilityIdentifier("confirm.cancel")
        }
      }
    }
  }
}

struct PasswordEditSheet: View {
  @Bindable var model: SecurityModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ScrollView {
        NewPasswordBlock(password: $model.newPassword, confirm: $model.confirmNewPassword,
                         assessment: model.newPasswordAssessment,
                         matches: !model.confirmNewPassword.isEmpty && model.newPassword == model.confirmNewPassword)
          .padding(HSpacing.insetPage)
      }
      .background(HColor.surfaceSecondary)
      .navigationTitle(model.state?.hasPassword == true ? "Change your password" : "Set a password")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) { Button(role: .close) { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") { Task { await model.savePassword() } }
            .disabled(!model.newPasswordReady)
            .accessibilityIdentifier("passwordEdit.save")
        }
      }
    }
  }
}

/// Profile › Delete your account (Paper "Sign-in & security · Delete your account"; copy
/// S-22), reachable from the profile itself as App Review requires (Guideline 5.1.1(v)).
/// It runs the same ceremony as Sign-in & security: `AccountService.perform(.deleteAccount,
/// password:)` behind its step-up (Face ID for a passkey account; the password plus this
/// iPhone's key for a password-only one). Once it succeeds the session signs out and the
/// account gate shows the welcome screens.
struct DeleteAccountView: View {
  @State private var model: SecurityModel

  init(session: AccountSession) {
    _model = State(initialValue: SecurityModel(session: session))
  }

  var body: some View {
    DeleteAccountForm(failure: model.failure) {
      Task { await delete() }
    }
    .disabled(model.busy)
    .overlay { if model.busy { ProgressView().controlSize(.large) } }
    .task { await model.load() }
    .confirmSheet(model)
  }

  /// The step-up depends on whether the account has a passkey, which `load()` reads; a
  /// first load that failed (offline) is retried here.
  private func delete() async {
    if model.state == nil { await model.load() }
    guard model.state != nil else { return }
    await model.request(.deleteAccount)
  }
}

/// What deleting erases, and the button behind the system alert (shared by Profile ›
/// Delete your account and Sign-in & security).
struct DeleteAccountForm: View {
  /// Why the last attempt didn't go through, shown above the button.
  var failure: AuthFailure? = nil
  var onDelete: () -> Void
  @State private var confirming = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Text("What happens when you delete").hType(.title1).foregroundStyle(HColor.textPrimary)
        Text("This can't be undone. You'll confirm it's you first.").hType(.subheadline).foregroundStyle(HColor.textSecondary)
        VStack(alignment: .leading, spacing: 14) {
          item("trash", "Your budget, plan and rules are erased here and on our server.")
          item("envelope.badge.shield.half.filled", "Hasala disconnects Gmail on this iPhone.")
          item("clock", "Encrypted backups expire within 30 days.")
          item("key.slash", "Your passkeys and password stop working.")
        }
        .padding(18)
        .listCard()
        Text("Your encrypted data, keys, passkeys, password, name and email address are erased from our server straight away. We then send you one email to confirm the deletion; our record of that email keeps your address until it is sent, at most a day. After that, our records of the emails we sent you keep only a masked form like m\u{2022}\u{2022}\u{2022}@example.com, for up to 30 days. Encrypted backups expire within 30 days. Hasala also disconnects Gmail on this iPhone.")
          .hType(.footnote)
          .foregroundStyle(HColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
        FailureBanner(failure: failure)
      }
      .padding(HSpacing.insetPage)
    }
    .background(HColor.surfaceSecondary)
    .safeAreaInset(edge: .bottom) {
      Button("Delete my account") { confirming = true }
        .buttonStyle(.pill(.destructive, fill: true))
        .padding(HSpacing.insetPage)
        .accessibilityIdentifier("delete.confirm")
    }
    .navigationTitle("Delete account")
    .navigationBarTitleDisplayMode(.inline)
    .alert("Delete your Hasala account?", isPresented: $confirming) {
      Button("Delete", role: .destructive, action: onDelete)
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Everything is erased. This can't be undone.")
    }
  }

  private func item(_ symbol: String, _ text: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: symbol).foregroundStyle(HColor.actionDestructive).frame(width: 22).accessibilityHidden(true)
      Text(text).hType(.callout).foregroundStyle(HColor.textPrimary).fixedSize(horizontal: false, vertical: true)
    }
  }
}

private struct ConfirmBox: Identifiable {
  let action: SecurityAction
  var id: String { action.explainer }
}

extension View {
  /// The "Confirm it's you" password sheet for a password-only account's pending change.
  func confirmSheet(_ model: SecurityModel) -> some View {
    sheet(item: Binding(get: { model.confirming.map(ConfirmBox.init) }, set: { if $0 == nil { model.confirming = nil } })) {
      box in
      ConfirmSheet(action: box.action,
                   password: Binding(get: { model.confirmPassword }, set: { model.confirmPassword = $0 }),
                   onConfirm: { Task { await model.confirm() } },
                   onCancel: { model.confirming = nil })
    }
  }
}
