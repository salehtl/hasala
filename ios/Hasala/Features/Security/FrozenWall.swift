import HasalaDesign
import SwiftUI

/// "Your account is frozen" (Paper "App · Account frozen", spec 04 §6.11; copy S-37).
/// An operator freeze hides "Unfreeze": only the operator lifts it.
struct FrozenWall: View {
  let session: AccountSession
  let info: FreezeInfo
  @State private var confirming = false
  @State private var password = ""
  @State private var busy = false
  @State private var failure: AuthFailure?

  var body: some View {
    NavigationStack {
      AccountScreen(
        title: "Your account is frozen",
        subtitle: info.by == .operator
          ? "We froze your account to protect it. Talk to us to unfreeze it."
          : (info.when.map { "\u{201C}Freeze my account\u{201D} was used \($0). " } ?? "")
            + "Nobody can sign in or change your keys until you confirm it's you."
      ) {
        VStack(alignment: .leading, spacing: 14) {
          if info.by == .holder {
            VStack(alignment: .leading, spacing: 14) {
              HStack(alignment: .top, spacing: 14) {
                IconDisc(systemImage: "key")
                VStack(alignment: .leading, spacing: 2) {
                  Text("Confirm it's you to unfreeze").hType(.headline).foregroundStyle(HColor.textPrimary)
                  Text("Your passkey, or your password on one of your iPhones. A passkey or password added after the freeze can't unfreeze it.")
                    .hType(.subheadline).foregroundStyle(HColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
              }
              BusyButton(title: "Unfreeze", busy: busy, identifier: "frozen.unfreeze") {
                Task { await unfreeze() }
              }
            }
            .padding(18)
            .listCard()
          }
          FailureBanner(failure: failure)
          LockNote(text: "Didn't freeze it yourself? Someone may be reading your email. Unfreeze, then check Sign-in & security and change your email's password.",
                   systemImage: "checkmark.shield")
          WebLink(title: "Talk to a person", url: "https://hasala.app/support", identifier: "frozen.talk")
        }
      } footer: {
        LinkButton(title: "Leave it frozen", identifier: "frozen.leave") { session.leaveFrozen() }
      }
      .sheet(isPresented: $confirming) {
        ConfirmSheet(action: .unfreeze, password: $password,
                     onConfirm: {
                       confirming = false
                       Task { await run(password: password) }
                     },
                     onCancel: { confirming = false })
      }
    }
  }

  private func unfreeze() async {
    if session.account.profile?.method == .password {
      password = ""
      confirming = true
    } else {
      await run(password: nil)
    }
  }

  private func run(password: String?) async {
    busy = true
    defer { busy = false }
    do {
      try await session.account.perform(.unfreeze, password: password)
      session.unfroze()
    } catch .stepUpFailed {
      failure = .badPhrase("That didn't confirm. A passkey or password added after the freeze can't unfreeze the account.")
    } catch {
      failure = error
    }
  }
}

/// The banner shown while the account stays frozen ("Leave it frozen"). An operator
/// freeze offers no Unfreeze anywhere (spec 04 §6.11: the app never attempts #66 for it);
/// the banner then opens the wall's "Talk to a person".
struct FrozenBanner: View {
  var by: FreezeInfo.By
  var onShowWall: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "snowflake").accessibilityHidden(true)
      Text("Account frozen").hType(.rowTitle)
      Spacer()
      if by == .holder {
        Button("Unfreeze", action: onShowWall).hType(.rowTitle).accessibilityIdentifier("frozenBanner.unfreeze")
      } else {
        Button("Details", action: onShowWall).hType(.rowTitle).accessibilityIdentifier("frozenBanner.details")
      }
    }
    .foregroundStyle(HColor.statusInfoForeground)
    .padding(.horizontal, 16)
    .frame(minHeight: 44)
    .background(HColor.statusInfoSurface)
  }
}
