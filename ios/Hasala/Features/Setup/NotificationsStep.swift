import HasalaDesign
import HasalaModels
import SwiftUI

/// Setup · Notifications · Lock Screen stays generic (Paper GMV-0): what a notification
/// looks like on the Lock Screen by default, before iOS asks. No header. Once iOS has asked
/// here, the button only continues (plan B3.2 rule 2).
///
/// This build writes no notifications yet (`CoreSignals` is empty; the owner kept the step),
/// so a Release build says so before the system asks (Guideline 5.1.1). Nor can it change
/// the Lock Screen choice later (Profile has no Notifications row), so it offers none:
/// notes show no amounts or names.
struct NotificationsStep: View {
  @Bindable var model: SetupModel

  private var subtitle: String {
    BuildSurface.showsUnfinished
      ? "A short note when a transaction lands, a bill is due or a budget reaches 80%."
      : "For a short note when a transaction lands, a bill is due or a budget reaches 80%. This beta doesn't send them yet. Allow them now, or later in Settings."
  }

  var body: some View {
    SetupScreen(title: "A nudge when money moves.", subtitle: subtitle, wash: .notifications, top: 28) {
      VStack(spacing: 0) {
        VStack(spacing: 10) {
          LockScreenPreview(date: model.today, details: model.showDetails)
          if BuildSurface.showsUnfinished {
            Text("What your Lock Screen shows by default")
              .hType(.footnote.weight(.medium))
              .foregroundStyle(HColor.textSecondary)
              .multilineTextAlignment(.center)
          } else {
            Text("Your Lock Screen shows no amounts or names.")
              .hType(.footnote.weight(.medium))
              .foregroundStyle(HColor.textSecondary)
              .multilineTextAlignment(.center)
              .accessibilityIdentifier("notifications.lockScreen")
          }
        }
        .padding(.top, 24)
        if BuildSurface.showsUnfinished {
          DetailsSwitch(isOn: $model.showDetails)
            .padding(.top, 20)
        }
      }
      .padding(.horizontal, HSpacing.insetPage)
    } dock: {
      VStack(spacing: 4) {
        // Once iOS has asked, the step only goes on.
        Button(model.notificationsAllowed ? "Continue" : "Allow notifications") {
          Task { await model.allowNotifications() }
        }
        .buttonStyle(.pill(.primary, fill: true))
        .accessibilityIdentifier("notifications.allow")
        if !model.notificationsAllowed {
          Button("Not now") { model.notNow() }
            .buttonStyle(.pill(.tertiary, fill: true))
            .accessibilityIdentifier("notifications.notNow")
        }
      }
      .padding(.horizontal, HSpacing.insetPage)
      .padding(.top, 8)
    }
  }
}

/// "Show amounts and merchants" (Paper "Setting · Show amounts and merchants"): off by
/// default, the native switch.
private struct DetailsSwitch: View {
  @Binding var isOn: Bool

  var body: some View {
    Toggle(isOn: $isOn) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Show amounts and merchants").hType(.rowTitle).foregroundStyle(HColor.textPrimary)
        Text("Off by default, so a glance at your Lock Screen shows no amounts or names.")
          .hType(.footnote)
          .foregroundStyle(HColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .tint(HColor.controlSwitchTrackOn)
    .padding(.vertical, 14)
    .padding(.horizontal, 16)
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.listGroup, style: .continuous))
    .accessibilityIdentifier("notifications.details")
  }
}

/// The Lock Screen as it will look (Paper "Lock Screen preview"): today's date, "9:41", and
/// Hasala's banner, which says only the kind of thing that happened unless the person
/// turned details on. An illustration of the system's own screen at its own size; it grows
/// with the text a little, then stops (a capped figure, like the hero).
private struct LockScreenPreview: View {
  let date: LocalDate
  let details: Bool

  // The board's wallpaper, converted from its OKLab stops (spec 05 §0); an illustration of
  // the system's Lock Screen, not a Hasala surface, so no token names it.
  private static let wallpaper = [
    Color(HRGBA(0x1F, 0x2C, 0x5C, 1)), Color(HRGBA(0x44, 0x48, 0x8A, 1)), Color(HRGBA(0xA9, 0x80, 0x9A, 1)),
  ]

  var body: some View {
    VStack(spacing: 2) {
      Text(LedgerToday.lockScreenDate(date))
        .font(.system(.subheadline, weight: .semibold))
        .foregroundStyle(HColor.white.opacity(0.92))
      Text(verbatim: "9:41")
        .font(.system(size: 64, weight: .semibold, design: .rounded))
        .tracking(-1.2)
        .foregroundStyle(HColor.white.opacity(0.94))
        .minimumScaleFactor(0.5)
        .lineLimit(1)
        .padding(.bottom, 14)
      banner
    }
    .padding(.top, 22)
    .padding(.horizontal, 14)
    .padding(.bottom, 16)
    .frame(maxWidth: .infinity)
    .background(LinearGradient(colors: Self.wallpaper, startPoint: .top, endPoint: .bottom))
    .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
    .shadow(color: HColor.hueSkyInk.opacity(0.16), radius: 15, x: 0, y: 14)
    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Lock Screen preview: \(details ? "amount and merchant shown" : "New transaction")")
    .accessibilityIdentifier(hasalaCappedFigureIdentifier)
  }

  private var banner: some View {
    HStack(spacing: 12) {
      AppIconTile(size: 38, radius: 10)
      VStack(alignment: .leading, spacing: 1) {
        HStack {
          Text("Hasala").font(.system(.subheadline, weight: .semibold)).foregroundStyle(HColor.appleLabelsVibrantPrimary)
          Spacer(minLength: 8)
          Text("now").font(.system(.footnote)).foregroundStyle(HColor.appleLabelsSecondary)
        }
        Text(details ? "AED 342.15 at Carrefour" : "New transaction")
          .font(.system(.subheadline))
          .foregroundStyle(HColor.appleLabelsVibrantPrimary)
      }
    }
    .padding(.vertical, 12)
    .padding(.leading, 12)
    .padding(.trailing, 14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(HColor.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 6)
  }
}
