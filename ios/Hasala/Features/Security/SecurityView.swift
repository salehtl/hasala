import HasalaDesign
import HasalaModels
import SwiftUI

/// Sign-in & security (Paper P2.5 HB9 passkey user, HNJ password-only user; spec 04 §6.9),
/// pushed inside the profile's large sheet: the status hero, then Email, Passkeys, Password,
/// Devices and Recovery phrase, each a titled white card with a footnote, then sign out,
/// sign out everywhere and delete. Only the account actions this build carries out are
/// offered (`AccountSession.capabilities`); the rest point to support. Every change asks
/// "Are you sure?" where it can't be undone (native alerts), then "Confirm it's you".
struct SecurityView: View {
  let session: AccountSession
  @State private var model: SecurityModel
  @State private var alert: PendingAlert?
  @State private var deleting = false
  @State private var lockingDown = false

  init(session: AccountSession) {
    self.session = session
    _model = State(initialValue: SecurityModel(session: session))
  }

  /// The system alerts (Paper HS1, HWP, I1C, I5Z): the question names the thing; the
  /// message says what is lost and what stays; the button repeats the verb.
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
      VStack(alignment: .leading, spacing: 24) {
        if let s = model.state {
          hero(s)
          if let notice = model.notice {
            StatusLine(text: notice, tone: .success, size: .regular)
              .accessibilityIdentifier("security.notice")
          }
          if model.confirming == nil { FailureBanner(failure: model.failure) }
          section("Email") { emailCard(s) }
          if s.hasPasskey || can(.addPasskey) {
            section("Passkeys", footer: s.hasPasskey
              ? "A passkey signs you in and unlocks your data. iCloud Keychain keeps it on all your Apple devices."
              : "Add one and Face ID signs you in, and unlocks your data on a new iPhone.") { passkeys(s) }
          }
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
      .padding(.horizontal, HSpacing.insetPage)
      .padding(.top, 8)
      .padding(.bottom, 48)
      .fullScreenCover(isPresented: Binding(get: { model.viewedPhrase != nil }, set: { if !$0 { model.closePhrase() } })) {
        PhraseViewer(model: model)
      }
    }
    .background(HColor.surfaceSecondary)
    .navigationTitle("Sign-in & security")
    .navigationBarTitleDisplayMode(.inline)
    .task {
      await model.load()
      #if HASALA_MOCKS
        await ScreenLaunch.applySecurityLaunch(model, alert: $alert, lockingDown: $lockingDown)
      #endif
    }
    .confirmSheet(model, onEnterWords: BuildSurface.showsUnfinished ? { model.enterWordsToUnlock() } : nil)
    .navigationDestination(isPresented: $model.editingPassword) {
      PasswordEditPage(model: model)
    }
    .navigationDestination(isPresented: $deleting) {
      DeleteAccountView(session: session)
    }
    .navigationDestination(isPresented: $lockingDown) {
      LockdownView(model: model, context: .fromSecurity)
    }
    .fullScreenCover(item: $model.emailChange) { ticket in
      ChangeEmailFlow(account: model.accountForEmailChange, ticket: ticket) { newEmail in
        Task { await model.finishEmailChange(to: newEmail) }
      }
    }
    .alert(alertTitle, isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } }),
           presenting: alert) { a in
      alertButtons(a)
    } message: { a in
      Text(alertMessage(a))
    }
  }

  /// Whether this build offers `action` (spec: only actions in `capabilities` are shown).
  private func can(_ action: AccountCapabilities) -> Bool { model.capabilities.contains(action) }

  // MARK: Hero

  private func hero(_ s: SecurityState) -> some View {
    Group {
      if let frozen = s.frozen {
        StatusHero(
          title: "Frozen",
          body: frozen.by == .operator
            ? "We froze your account to protect it. Talk to us to unfreeze it."
            : can(.freeze) ? "Your account is frozen. Confirm it's you to unfreeze it." : "Your account is frozen.",
          hue: .rose, icon: .lockKeyhole)
      } else if s.hasPasskey {
        StatusHero(title: "Protected", body: "Passkey and 12 words are set.\nLast sign-in \(s.lastSignIn).",
                   hue: .mint, icon: .check)
      } else {
        StatusHero(
          title: "Password only",
          body: can(.addPasskey)
            ? "Your 12 words are set. A passkey\nwould make sign-in one glance."
            // The passkey hero's two lines in the same words, so neither wraps (HNJ-0).
            : "Password and 12 words are set.\nLast sign-in \(s.lastSignIn).",
          hue: .sand, icon: .faceID)
      }
    }
    .accessibilityIdentifier("security.hero")
  }

  // MARK: Sections

  private func section<C: View>(_ title: String, footer: String? = nil, @ViewBuilder _ content: () -> C) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title).hType(.section).foregroundStyle(HColor.textPrimary).accessibilityAddTraits(.isHeader)
      HListCard { content() }
      if let footer {
        Text(footer)
          .hType(.footnote)
          .foregroundStyle(HColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 4)
      }
    }
  }

  private func emailCard(_ s: SecurityState) -> some View {
    SecurityRow(tile: .plate(.envelope, .sky), title: s.email,
                detail: s.emailVerified ? "Verified · codes and alerts" : "Not verified yet",
                titleLabel: "Email address \(s.email)") {
      // The email change has no live ceremony yet (C6): Debug only, with the capability.
      if can(.changeEmail), BuildSurface.showsUnfinished {
        Button("Change") { model.requestEmailChange() }
          .buttonStyle(.pill(.secondary, size: .small))
          .accessibilityIdentifier("security.changeEmail")
      }
    }
  }

  private func passkeys(_ s: SecurityState) -> some View {
    Group {
      ForEach(Array(s.passkeys.enumerated()), id: \.element.id) { i, p in
        if i > 0 { HDivider() }
        SecurityRow(tile: p.isThisCredential ? .plate(.faceID, .sky) : .plate(.passkey, .other), title: p.provider,
                    detail: p.detail) {
          // The passkey in hand isn't removed from here; another way in must remain.
          if can(.removePasskey), !p.isThisCredential, s.passkeys.count > 1 || s.hasPassword {
            InlineDestructive(title: "Remove", identifier: "security.removePasskey.\(p.id)") {
              alert = .removePasskey(p)
            }
          }
        }
      }
      if can(.addPasskey) {
        if !s.passkeys.isEmpty { HDivider() }
        AddRow(title: "Add a passkey", identifier: "security.addPasskey") {
          Task { await model.request(.addPasskey) }
        }
      }
    }
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
    return can(.rotatePhrase) && BuildSurface.showsUnfinished
      ? "We can't see or reset your words. Viewing them emails you; new words replace the old ones everywhere."
      : "We can't see or reset your words. Viewing them emails you."
  }

  private func passwordCard(_ s: SecurityState) -> some View {
    Group {
      if let changed = s.passwordChanged {
        SecurityRow(tile: .plate(.password, .other), title: "Password", detail: changed) {
          if can(.changePassword) {
            Button("Change") { model.editingPassword = true }
              .buttonStyle(.pill(.secondary, size: .small))
              .accessibilityIdentifier("security.changePassword")
          }
        }
        if s.hasPasskey, can(.changePassword) {
          HDivider()
          AddRow(title: "Remove password", identifier: "security.removePassword", plus: false, destructive: true) {
            alert = .removePassword
          }
        }
      } else {
        SecurityRow(tile: .plate(.password, .other), title: "No password",
                    detail: can(.changePassword) ? "Optional. Signs you in where Face ID can't." : "You sign in with your passkey.") {
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
      if i > 0 { HDivider() }
      SecurityRow(tile: d.isThisDevice ? .plate(.phone, .mint) : .plate(d.isTablet ? .iPad : .phone, .other),
                  title: d.title, detail: d.detail) {
        if d.isThisDevice {
          HStack(spacing: 6) {
            Circle().fill(HColor.statusSuccessForeground).frame(width: 7, height: 7)
            Text("You").hType(.footnote.weight(.semibold)).foregroundStyle(HColor.statusSuccessForeground)
          }
          .accessibilityElement(children: .combine)
        } else if can(.removeDevice) {
          InlineDestructive(title: "Remove", identifier: "security.removeDevice.\(d.id)") { alert = .removeDevice(d) }
        }
      }
    }
  }

  private func phrase(_ s: SecurityState) -> some View {
    Group {
      if s.hasPasskey, can(.viewPhrase) {
        Button {
          model.requestPhrase()
        } label: {
          SecurityRow(tile: .disc(.paper, .sand), title: "View recovery phrase",
                      detail: "\(s.phraseConfirmed) · Asks for Face ID") {
            HIconView(.chevronRight, size: 16, color: HColor.listRowChevron)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(HRowPressStyle())
        .accessibilityIdentifier("security.viewPhrase")
      } else {
        SecurityRow(tile: .disc(.paper, .sand), title: "Recovery phrase", detail: s.phraseConfirmed) { EmptyView() }
      }
      // No ceremony makes new words yet (C7): Debug only, with the capability.
      if can(.rotatePhrase), BuildSurface.showsUnfinished {
        HDivider()
        AddRow(title: "New recovery phrase", identifier: "security.newWords", plus: false) {
          model.failure = .notInThisBuild
        }
      }
    }
  }

  private func footerActions(_ s: SecurityState) -> some View {
    VStack(spacing: 4) {
      if can(.signOut) {
        Button("Sign out of this iPhone") { alert = .signOut }
          .buttonStyle(.pill(.destructiveQuiet, fill: true))
          .accessibilityIdentifier("security.signOut")
      }
      if can(.signOutEverywhere) {
        TextLink(title: "Sign out everywhere", identifier: "security.signOutEverywhere") { alert = .signOutEverywhere }
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
        TextLink(title: "Freeze my account", identifier: "security.freeze") { alert = .freeze }
      }
      if model.offersLockdown {
        TextLink(title: "Something not right? Lock it down", identifier: "security.lockdown") { lockingDown = true }
      }
      if can(.deleteAccount) {
        TextLink(title: "Delete your account", identifier: "security.delete", destructive: true) { deleting = true }
      }
      if model.lacksAnAction {
        SupportLink(lead: "Need a change that isn't here?", identifier: "security.support")
      }
      Text(s.hasPasskey ? "Changes here ask for Face ID first." : "Changes here ask for your password, and this iPhone signs them too.")
        .hType(.footnote)
        .foregroundStyle(HColor.textSecondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }
    .padding(.top, 8)
  }

  // MARK: Alerts

  private var alertTitle: String {
    switch alert {
    case .removePasskey(let p): "Remove the \(p.provider) passkey?"
    case .removeDevice(let d): "Remove \(d.title)?"
    case .removePassword: "Remove your password?"
    case .signOut: "Sign out of this iPhone?"
    case .signOutEverywhere: "Sign out everywhere?"
    case .freeze: "Freeze your account?"
    case nil: ""
    }
  }

  private func alertMessage(_ a: PendingAlert) -> String {
    let confirmWith = model.state?.hasPasskey == true ? "Face ID" : "your password"
    switch a {
    case .removePasskey:
      return "It won't be able to sign in to Hasala. You'll confirm with \(confirmWith) next."
    case .removeDevice:
      return "It's signed out now. The next time it opens Hasala, its copy of your data is erased."
    case .removePassword:
      return "You'll sign in with your passkey only. You'll confirm with Face ID next."
    case .signOut:
      // The profile's Sign out says the same (requests/p8.md 4).
      return AccountCopy.signOutMessage
    case .signOutEverywhere:
      // Every session ends; each device keeps its copy and its keys (`02` §9.3).
      return "Every device signs out, this one too. Your data stays on each, and your sealed backup stays, ready for your next sign-in."
    case .freeze:
      return "Everyone will be signed out. No one can use your account with a password, reset the password or use the recovery phrase until you confirm it's you with a passkey, or with your password on one of your iPhones."
    }
  }

  @ViewBuilder private func alertButtons(_ a: PendingAlert) -> some View {
    Button("Cancel", role: .cancel) {}
    switch a {
    case .removePasskey(let p):
      Button("Remove", role: .destructive) { Task { await model.request(.removePasskey(id: p.id)) } }
    case .removeDevice(let d):
      Button("Remove", role: .destructive) { Task { await model.request(.removeDevice(id: d.id)) } }
    case .removePassword:
      Button("Remove", role: .destructive) { Task { await model.request(.removePassword) } }
    case .signOut:
      Button("Sign out", role: .destructive) { Task { await model.signOut() } }
    case .signOutEverywhere:
      Button("Sign out all", role: .destructive) { Task { await model.request(.signOutEverywhere) } }
    case .freeze:
      Button("Freeze my account", role: .destructive) { Task { await model.request(.freeze) } }
    }
  }
}

// MARK: - Rows

/// A Sign-in & security row (Paper "ListRow (two-line, with leading tile)"): a 40 tile, a
/// 16/22 title over a 13/18 line, and a trailing pill, action or status. At least 64 tall.
/// The line wraps beside the trailing part (Paper HB9 "Optional. Signs you in where / Face
/// ID can't." next to "Set one"); at the accessibility sizes the trailing part moves under
/// the text.
struct SecurityRow<Trailing: View>: View {
  enum Tile {
    /// Radius 12 (a key, an address, a device).
    case plate(HIcon, Hue)
    /// Round (the recovery phrase).
    case disc(HIcon, Hue)
  }

  var tile: Tile
  var title: String
  var detail: String?
  var titleLabel: String?
  @ViewBuilder var trailing: () -> Trailing

  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      tileView
      if typeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 4) {
          text
          trailing()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        HStack(spacing: 12) {
          text.frame(maxWidth: .infinity, alignment: .leading)
          trailing().fixedSize()
        }
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .frame(minHeight: 64)
  }

  private var text: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .hType(.rowTitle)
        .foregroundStyle(HColor.textPrimary)
        .lineLimitAtDefaultTextSize(1)
        .truncationMode(.middle)
        .accessibilityLabel(titleLabel ?? title)
      if let detail {
        Text(detail)
          .hType(.footnote)
          .foregroundStyle(HColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder private var tileView: some View {
    switch tile {
    case .plate(let icon, let hue):
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(hue.perceptualGradient)
        .frame(width: 40, height: 40)
        .overlay { HIconView(icon, size: 20, color: hue.ink) }
        .accessibilityHidden(true)
    case .disc(let icon, let hue):
      CategoryDisc(hue: hue, icon: icon)
    }
  }
}

/// An action row in the link colour (Paper "ListRow (action, accent)"): a 40 accent-subtle
/// tile with "+" (or an empty 40 lane), at least 56 tall.
private struct AddRow: View {
  var title: String
  var identifier: String
  var plus = true
  var destructive = false
  var action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 12) {
        if plus {
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(HColor.actionAccentSubtle)
            .frame(width: 40, height: 40)
            .overlay { HIconView(.add, size: 18, color: HColor.textLink, strokeWidth: 2.4) }
            .accessibilityHidden(true)
        } else {
          Color.clear.frame(width: 40, height: 1)
        }
        Text(title)
          .hType(.rowTitle)
          .foregroundStyle(destructive ? HColor.actionDestructive : HColor.textLink)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
      .frame(minHeight: 56)
      .contentShape(Rectangle())
    }
    .buttonStyle(HRowPressStyle())
    .accessibilityIdentifier(identifier)
  }
}

/// "Remove" inside a row (Paper "InlineDestructiveAction"): 15/20 semibold destructive in a
/// 44 target.
private struct InlineDestructive: View {
  var title: String
  var identifier: String
  var action: () -> Void

  var body: some View {
    Button(role: .destructive, action: action) {
      Text(title)
        .hType(.subheadline.weight(.semibold))
        .foregroundStyle(HColor.actionDestructive)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier(identifier)
  }
}

/// A 15/20 semibold text link in a 44 row (Paper "TextLink44" under the footer button).
struct TextLink: View {
  var title: String
  var identifier: String
  var destructive = false
  var action: () -> Void

  var body: some View {
    Button(role: destructive ? .destructive : nil, action: action) {
      Text(title)
        .hType(.subheadline.weight(.semibold))
        .foregroundStyle(destructive ? HColor.actionDestructive : HColor.textPrimary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, minHeight: 44)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier(identifier)
  }
}

// MARK: - Confirm it's you, hosted

extension View {
  /// "Confirm it's you" for the change waiting in `model`, when `host` is the page on top.
  /// `onEnterWords` lets the no-key variant open the words.
  func confirmSheet(
    _ model: SecurityModel, host: SecurityModel.Host = .page, onEnterWords: (() -> Void)? = nil
  ) -> some View {
    sheet(
      item: Binding(
        get: { model.confirmHost == host ? model.confirming : nil },
        set: { if $0 == nil, model.confirming != nil { model.cancelConfirmation() } }),
      onDismiss: { model.confirmationDismissed() }
    ) { _ in
      ConfirmSheetHost(model: model, onEnterWords: onEnterWords)
    }
  }
}

private struct ConfirmSheetHost: View {
  @Bindable var model: SecurityModel
  var onEnterWords: (() -> Void)?

  var body: some View {
    if let request = model.confirmRequest {
      ConfirmItsYouSheet(
        request: request, password: $model.confirmPassword, busy: model.busy, failure: model.failure,
        onConfirm: { Task { await model.confirm() } }, onEnterWords: onEnterWords,
        onClose: { model.cancelConfirmation() })
    }
  }
}

// MARK: - Password

/// Set or change the password (Paper doesn't draw it; spec 09 §21 "password screens"),
/// pushed inside the profile sheet: the new password, its strength and the repeat. Saving
/// asks "Confirm it's you" over this page, which closes once the change is through.
struct PasswordEditPage: View {
  @Bindable var model: SecurityModel

  var body: some View {
    AccountScreen(
      title: model.state?.hasPassword == true ? "Change your password" : "Set a password",
      subtitle: "12 characters or more. Other devices are signed out when it changes.",
      back: .system
    ) {
      NewPasswordBlock(password: $model.newPassword, confirm: $model.confirmNewPassword,
                       assessment: model.newPasswordAssessment,
                       matches: !model.confirmNewPassword.isEmpty && model.newPassword == model.confirmNewPassword)
    } footer: {
      BusyButton(title: "Save password", busy: model.busy, enabled: model.newPasswordReady,
                 identifier: "passwordEdit.save") {
        Task { await model.savePassword() }
      }
    }
    .confirmSheet(model, host: .passwordEditor,
                  onEnterWords: BuildSurface.showsUnfinished ? { model.enterWordsToUnlock() } : nil)
  }
}

/// The password page as a sheet, for a host that isn't a navigation stack ("Let's lock it
/// down" after "No, that's not me").
struct PasswordEditSheet: View {
  @Bindable var model: SecurityModel

  var body: some View {
    NavigationStack { PasswordEditPage(model: model) }
  }
}
