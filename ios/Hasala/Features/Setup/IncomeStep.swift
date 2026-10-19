import HasalaDesign
import HasalaModels
import SwiftUI

/// Setup · 3 of 4 · Monthly income (Paper 56S-0): the salary on the app's own keypad
/// (page 11, docked: no system keyboard, never sliding in or out), the payday day strip,
/// the scan's pill above Continue, and Skip. What was typed and chosen stays for the life of
/// the process: Back and Forward show it again.
///
/// Nothing on the keypad animates beyond a key's highlight and a light tick; a hardware
/// keyboard types into the figure.
struct IncomeStep: View {
  @Bindable var model: SetupModel
  @FocusState private var figureFocused: Bool

  var body: some View {
    SetupScreen(
      title: "What lands in your account each month?",
      subtitle: "After tax. You can change it any time.",
      steps: model.steps(3),
      back: .system,
      trailing: ("Skip", model.skipIncome),
      layout: .fill
    ) {
      amountArea
    } dock: {
      VStack(spacing: 0) {
        // Paper "Action": the button right under the amount area, 16 above the keypad.
        BusyButton(title: "Continue", busy: false, enabled: model.incomeMinor != nil,
                   identifier: "income.continue", action: model.continueWithIncome)
          .padding(.horizontal, HSpacing.insetPage)
          .padding(.bottom, 16)
        AmountKeypad(entry: $model.incomeEntry, layout: .docked)
      }
    }
    .onAppear { figureFocused = true }
  }

  /// The figure and the payday strip, centred in the space between the question and the
  /// dock (Paper "Amount entry": gap 16, 28 under), with the scan's pill 8 above Continue.
  private var amountArea: some View {
    VStack(spacing: 16) {
      AmountFigure(entry: model.incomeEntry, layout: .docked)
        .padding(.horizontal, HSpacing.insetPage)
        .accessibilityIdentifier("income.figure")
        .focusable()
        .focused($figureFocused)
        .focusEffectDisabled()
        .onKeyPress(phases: .down, action: typed)
      PaydayPicker(choice: $model.paydayChoice, next: model.nextPayday)
        .padding(.top, 8)
      SetupFailureBanner(failure: model.failure)
        .padding(.horizontal, HSpacing.insetPage)
    }
    // Room for the pill under the strip, without moving the block off Paper's centre.
    .padding(.vertical, 22)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(.bottom, 28)
    .overlay(alignment: .bottom) {
      ScanPill(scan: model.scan, running: model.scanRunning)
        .padding(.bottom, 8)
    }
  }

  /// A hardware keyboard: digits and Delete type into the figure, as the keys do (the
  /// decimal point is ignored here: whole dirhams). Return continues.
  private func typed(_ press: KeyPress) -> KeyPress.Result {
    var entry = model.incomeEntry
    switch press.key {
    case .delete, .deleteForward:
      entry.type(.delete)
    case .return:
      model.continueWithIncome()
      return .handled
    default:
      guard let d = press.characters.first?.wholeNumberValue, press.characters.count == 1,
        press.characters.first?.isASCII == true
      else { return .ignored }
      entry.type(.digit(d))
    }
    model.incomeEntry = entry
    return .handled
  }
}
