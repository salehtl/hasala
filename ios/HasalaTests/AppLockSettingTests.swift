import Testing

@testable import Hasala

@MainActor
@Suite("App lock setting")
struct AppLockSettingTests {
  final class Pref {
    var on: Bool
    init(_ on: Bool) { self.on = on }
  }

  let context = AppLockControllerTests.FakeLAContext()

  func make(on: Bool) -> (AppLockSettingModel, Pref, AppLockController) {
    let pref = Pref(on)
    let lock = AppLockController(makeContext: { [context] in context }, isEnabled: { pref.on })
    let model = AppLockSettingModel(lock: lock, read: { pref.on }, write: { pref.on = $0 })
    return (model, pref, lock)
  }

  @Test func turningOnChecksFirstAndThenSaves() async {
    let (model, pref, _) = make(on: false)
    context.checks = [.passed]
    await model.setOn(true)
    #expect(pref.on)
    #expect(context.reasons == ["Turn on Face ID lock for Hasala."])
    #expect(!model.failed)
  }

  @Test func aCancelledCheckChangesNothingAndSaysNothing() async {
    let (model, pref, _) = make(on: false)
    context.checks = [.cancelled]
    await model.setOn(true)
    #expect(!pref.on)
    #expect(!model.failed)
  }

  @Test func aFailedCheckKeepsTheSettingAndSaysSo() async {
    let (model, pref, _) = make(on: false)
    context.checks = [.failed]
    await model.setOn(true)
    #expect(!pref.on)
    #expect(model.failed)
    context.checks = [.passed]
    await model.setOn(true)
    #expect(pref.on)
    #expect(!model.failed)
  }

  @Test func turningOffChecksFirstToo() async {
    let (model, pref, _) = make(on: true)
    context.checks = [.failed]
    await model.setOn(false)
    #expect(pref.on)
    context.checks = [.passed]
    await model.setOn(false)
    #expect(!pref.on)
    #expect(context.reasons.last == "Turn off Face ID lock for Hasala.")
  }

  @Test func withoutAPasscodeItCannotTurnOnButCanTurnOff() async {
    context.available = false
    let (off, offPref, _) = make(on: false)
    await off.setOn(true)
    #expect(!offPref.on)
    #expect(context.reasons.isEmpty)
    #expect(!off.setting.canTurnOn)
    #expect(off.setting.offersSettings)

    let (on, onPref, _) = make(on: true)
    await on.setOn(false)
    #expect(!onPref.on)
    #expect(context.reasons.isEmpty)
  }

  @Test func aPasscodeRemovedMeanwhileDoesNotTurnItOn() async {
    let (model, pref, lock) = make(on: false)
    context.available = false
    context.checks = [.unavailable]
    await model.setOn(true)
    #expect(!pref.on)
    #expect(!lock.isAvailable)
    #expect(!model.setting.canTurnOn)
  }

  @Test func settingTheSameValueDoesNotAsk() async {
    let (model, _, _) = make(on: true)
    await model.setOn(true)
    #expect(context.reasons.isEmpty)
  }

  @Test func theNoteExplainsWhyBiometryIsNotUsed() {
    let ready = AppLockSetting(biometry: .faceID, isAvailable: true, issue: nil)
    #expect(ready.canTurnOn && !ready.offersSettings)
    #expect(ready.note.contains("Face ID"))

    let notEnrolled = AppLockSetting(biometry: .faceID, isAvailable: true, issue: .notEnrolled)
    #expect(notEnrolled.canTurnOn && notEnrolled.offersSettings)
    #expect(notEnrolled.note.contains("isn't set up"))
    #expect(notEnrolled.note.contains("passcode"))

    let denied = AppLockSetting(biometry: .faceID, isAvailable: true, issue: .denied)
    #expect(denied.canTurnOn && denied.offersSettings)
    #expect(denied.note.contains("off for Hasala"))

    let locked = AppLockSetting(biometry: .touchID, isAvailable: true, issue: .lockedOut)
    #expect(locked.canTurnOn && !locked.offersSettings)
    #expect(locked.note.contains("Touch ID"))

    let noPasscode = AppLockSetting(biometry: .faceID, isAvailable: false, issue: nil)
    #expect(!noPasscode.canTurnOn && noPasscode.offersSettings)
    #expect(noPasscode.note.contains("passcode"))
  }

  @Test func theNamesFollowTheHardware() {
    #expect(AppLockSetting(biometry: .touchID, isAvailable: true, issue: nil).title == "Touch ID lock")
    #expect(AppLockSetting(biometry: .opticID, isAvailable: true, issue: nil).title == "Optic ID lock")
    #expect(AppLockSetting(biometry: .none, isAvailable: true, issue: nil).title == "Passcode lock")
    #expect(AppLockSetting(biometry: .touchID, isAvailable: true, issue: .notEnrolled).note.contains("Touch ID"))
    #expect(AppLockSetting(biometry: .none, isAvailable: true, issue: nil).note.contains("passcode"))
  }

  @Test func theControllerReadsTheIssue() {
    context.biometryIssue = .notEnrolled
    let (_, _, lock) = make(on: false)
    #expect(lock.biometryIssue == .notEnrolled)
    context.biometryIssue = nil
    lock.refreshAvailability()
    #expect(lock.biometryIssue == nil)
  }
}
