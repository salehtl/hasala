import HasalaDesign
import HasalaModels
import SwiftUI

/// "Your account is frozen" (Paper P2.8 MTO, shown on every iPhone; spec 04 §6.11; copy
/// S-37), with "Unfreeze" pushing "Sign in fully" (MUT). An operator freeze offers no
/// Unfreeze anywhere: only the operator lifts it, and the app never sends #66 for it.
struct FrozenWall: View {
  let session: AccountSession
  let info: FreezeInfo
  @State private var path: [Route] = []
  @State private var confirmSignOut = false

  enum Route: Hashable { case unfreeze }

  var body: some View {
    NavigationStack(path: $path) {
      HeroAccountScreen(
        hero: HeroDisc(icon: .lockKeyhole, hue: .rose),
        title: "Your account is frozen",
        subtitle: info.by == .operator
          ? "We froze your account to protect it. Talk to us to unfreeze it."
          : Self.holderBody(info)
      ) {
        VStack(alignment: .leading, spacing: 12) {
          if info.by == .holder {
            OptionCard(icon: .key, hue: .sky, title: "Sign in fully to unfreeze",
                       detail: "Your passkey, or your password on one of your iPhones.", buttonTitle: "Unfreeze",
                       buttonKind: .primary, identifier: "frozen.unfreeze") { path = [.unfreeze] }
            NoteRow(icon: .shield,
                    text: "Didn't freeze it yourself? Someone may be reading your email. Unfreeze, then check Sign-in & security and change your email's password.")
          } else {
            WebLink(title: "Talk to a person", url: "https://hasala.app/support", identifier: "frozen.talk")
          }
        }
      } footer: {
        VStack(spacing: 8) {
          if session.canLeaveFrozen {
            SecondaryLink(title: "Leave it frozen", identifier: "frozen.leave") { session.leaveFrozen() }
          }
          SecondaryLink(title: "Sign out", identifier: "frozen.signOut") { confirmSignOut = true }
        }
      }
      .navigationDestination(for: Route.self) { _ in
        UnfreezeView(session: session)
      }
      .alert("Sign out of this iPhone?", isPresented: $confirmSignOut) {
        Button("Sign out", role: .destructive) { Task { await session.signOut() } }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text(AccountCopy.signOutMessage)
      }
    }
    #if HASALA_MOCKS
      .task {
        if (session.account as? MockAccountService)?.takeLaunchStep(.unfreeze) == true { path = [.unfreeze] }
      }
    #endif
  }

  /// MTO's body: where the freeze came from ("from our email", the cue for "Didn't freeze it
  /// yourself? Someone may be reading your email"), when, and what it stops.
  static func holderBody(_ info: FreezeInfo) -> String {
    let source = info.inApp ? "" : " from our email"
    let when = info.when.map { " \($0)" } ?? ""
    return "\u{201C}Freeze my account\u{201D} was used\(source)\(when). "
      + "Nobody can sign in or change your keys until you sign in fully."
  }
}

/// "Unfreeze your account · Sign in fully" (Paper MUT): the passkey on its own, or the
/// password on an iPhone whose key signs too. "Forgot password?" is hidden while frozen. A
/// password on an iPhone that has no key yet can't do it: the confirmation says so (IYT).
struct UnfreezeView: View {
  let session: AccountSession
  @State private var password = ""
  @State private var visible = false
  @State private var busy: SignInMethod?
  @State private var failure: AuthFailure?
  @State private var failedWith: SignInMethod?
  @State private var noKey = false
  @FocusState private var passwordFocused: Bool

  private var method: SignInMethod { session.account.profile?.method ?? .passkey }
  private var email: String { session.account.profile?.email ?? "" }
  private var offersPasskey: Bool { method == .passkey && session.capabilities.contains(.signInPasskey) }

  var body: some View {
    AccountScreen(title: "Unfreeze your account", subtitle: "Sign in fully, so we know it's really you.", back: .system) {
      VStack(alignment: .leading, spacing: 12) {
        if offersPasskey {
          VStack(spacing: 8) {
            Button("Sign in with Face ID") { Task { await run(password: nil) } }
              .buttonStyle(.pill(.primary, fill: true, loading: busy == .passkey, leadingIcon: .faceID))
              .disabled(busy != nil)
              .accessibilityIdentifier("unfreeze.passkey")
            Text("Your passkey is enough on its own.")
              .hType(.footnote)
              .foregroundStyle(HColor.textOnWashSecondary)
              .frame(maxWidth: .infinity)
            if failedWith == .passkey { FailureBanner(failure: failure) }
          }
          OrDivider(label: "or password on your iPhone")
        }
        if !email.isEmpty { ReadOnlyEmail(email: email) }
        FieldFrame(
          label: "Password",
          error: failedWith == .password && failure == .stepUpFailed ? Self.notConfirmed : nil,
          focused: passwordFocused, trailingPill: true, labelsField: true, onTap: { passwordFocused = true }
        ) {
          Group {
            if visible {
              TextField("Your password", text: $password)
            } else {
              SecureField("Your password", text: $password)
            }
          }
          .textContentType(.password)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .focused($passwordFocused)
          .accessibilityIdentifier("unfreeze.password")
          .accessibilityLabel("Password")
        } trailing: {
          ShowHidePill(visible: $visible)
        }
        Button { Task { await run(password: password) } } label: {
          Text("Sign in").foregroundStyle(password.isEmpty ? HColor.textDisabled : HColor.textPrimary)
        }
        .buttonStyle(.pill(.onGrouped, fill: true, loading: busy == .password))
        .disabled(password.isEmpty || busy != nil)
        .accessibilityIdentifier("unfreeze.submit")
        if failedWith == .password, failure != .stepUpFailed { FailureBanner(failure: failure) }
      }
    } footer: {
      WebLink(title: "Talk to a person", url: "https://hasala.app/support", identifier: "unfreeze.talk")
    }
    .sheet(isPresented: $noKey) {
      ConfirmItsYouSheet(
        request: ConfirmRequest(title: "Unfreeze your account", factor: .noKey), password: .constant(""),
        busy: false, failure: nil, onConfirm: {}, onClose: { noKey = false })
    }
  }

  static let notConfirmed = "That didn't confirm. A passkey or password added after the freeze can't unfreeze the account."

  private func run(password: String?) async {
    let using: SignInMethod = password == nil ? .passkey : .password
    busy = using
    defer { busy = nil }
    do {
      try await session.unfreeze(password: password)
      failure = nil
    } catch .cancelled {
      failure = nil
    } catch .noDeviceKey {
      // This iPhone's data is still sealed: no key to sign with (P2.6 IYT).
      self.password = ""
      failure = nil
      noKey = true
    } catch .frozenByOperator, .sessionEnded {
      // The session now shows the operator's wall, which says so itself, or Welcome.
      failure = nil
    } catch {
      self.password = ""
      failure = error
      failedWith = using
    }
  }
}

/// The account's address on the Unfreeze screen (Paper MUT "Field · Email", prefilled):
/// the account is known, so it isn't typed.
private struct ReadOnlyEmail: View {
  let email: String

  var body: some View {
    VStack(alignment: .leading, spacing: HSpacing.fieldLabelGap) {
      Text("Email").hType(.footnote.weight(.semibold)).foregroundStyle(HColor.textSecondary)
      Text(email)
        .hType(HType(size: 17, leading: 22, weight: .regular, textStyle: .body))
        .foregroundStyle(HColor.fieldText)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, HSpacing.fieldInsetInline)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, minHeight: HSpacing.fieldMinHeight, alignment: .leading)
        .background(HColor.fieldSurfaceOnGrouped, in: RoundedRectangle(cornerRadius: HRadius.field, style: .continuous))
    }
    .accessibilityElement(children: .combine)
  }
}

/// The banner shown while the account stays frozen ("Leave it frozen"). An operator
/// freeze offers no Unfreeze anywhere (spec 04 §6.11: the app never attempts #66 for it);
/// the banner then opens the wall's "Talk to a person".
struct FrozenBanner: View {
  var by: FreezeInfo.By
  var onShowWall: () -> Void
  var onSignOut: () -> Void
  @State private var confirmSignOut = false
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    Group {
      if typeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 0) {
          title.padding(.top, 10)
          ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { links }
            VStack(alignment: .leading, spacing: 0) { links }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        HStack(spacing: 10) {
          title
          Spacer()
          links
        }
      }
    }
    .padding(.horizontal, 16)
    .frame(minHeight: 44)
    .background(Hue.rose.start)
    .alert("Sign out of this iPhone?", isPresented: $confirmSignOut) {
      Button("Sign out", role: .destructive, action: onSignOut)
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(AccountCopy.signOutMessage)
    }
  }

  private var title: some View {
    HStack(spacing: 10) {
      HIconView(.lockKeyhole, size: 18, color: Hue.rose.ink)
      Text("Account frozen").hType(.rowTitle).foregroundStyle(Hue.rose.ink)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  @ViewBuilder private var links: some View {
    link("Sign out", id: "frozenBanner.signOut") { confirmSignOut = true }
    if by == .holder {
      link("Unfreeze", id: "frozenBanner.unfreeze", action: onShowWall)
    } else {
      link("Details", id: "frozenBanner.details", action: onShowWall)
    }
  }

  private func link(_ title: LocalizedStringKey, id: String, action: @escaping () -> Void) -> some View {
    Button(title, action: action)
      .hType(.rowTitle)
      .foregroundStyle(HColor.textLink)
      .frame(minHeight: 44)
      .accessibilityIdentifier(id)
  }
}
