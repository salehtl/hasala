import HasalaDesign
import LocalAuthentication
import SwiftUI
import Testing

@testable import Hasala

@MainActor
@Suite("App lock")
struct AppLockControllerTests {
  final class FakeLAContext: LockContext {
    var available = true
    var biometry: LockBiometry = .faceID
    var checks: [LockCheck] = []
    var reasons: [String] = []

    func canEvaluate() -> Bool { available }

    func evaluate(reason: String) async -> LockCheck {
      reasons.append(reason)
      return checks.isEmpty ? .passed : checks.removeFirst()
    }
  }

  final class Clock {
    let start = ContinuousClock.now
    var elapsed: Duration = .zero
    var now: ContinuousClock.Instant { start.advanced(by: elapsed) }
  }

  final class Pref {
    var on: Bool
    init(_ on: Bool) { self.on = on }
  }

  let context = FakeLAContext()
  let clock = Clock()

  func controller(enabled: Bool) -> (AppLockController, Pref) {
    let pref = Pref(enabled)
    let lock = AppLockController(
      makeContext: { [context] in context }, isEnabled: { pref.on }, now: { [clock] in clock.now })
    return (lock, pref)
  }

  func background(_ lock: AppLockController, for elapsed: Duration) {
    lock.scenePhaseChanged(.inactive)
    lock.scenePhaseChanged(.background)
    clock.elapsed += elapsed
    lock.scenePhaseChanged(.inactive)
  }

  @Test func aColdLaunchLocksWhenTheLockIsOn() async {
    context.checks = [.cancelled]
    let (lock, _) = controller(enabled: true)
    #expect(lock.isLocked)
    #expect(lock.showsShield)
    await lock.unlock()
    #expect(lock.isLocked)
    #expect(!lock.failed)
    await lock.unlock()
    #expect(!lock.isLocked)
    #expect(context.reasons.count == 2)
  }

  @Test func aColdLaunchStaysOpenWhenTheLockIsOff() {
    let (lock, _) = controller(enabled: false)
    #expect(!lock.isLocked)
    #expect(!lock.showsShield)
  }

  @Test func theGraceDecidesWhenToLockAgain() async {
    let (lock, _) = controller(enabled: true)
    await lock.unlock()
    #expect(!lock.isLocked)

    background(lock, for: AppLockController.grace - .seconds(1))
    #expect(lock.isCovered)
    lock.scenePhaseChanged(.active)
    #expect(!lock.isLocked)
    #expect(!lock.showsShield)

    background(lock, for: AppLockController.grace)
    context.checks = [.cancelled]
    lock.scenePhaseChanged(.active)
    #expect(lock.isLocked)
    #expect(!lock.isCovered)
    #expect(lock.showsShield)
  }

  @Test func theLockPromptsOnceWhenTheAppComesBack() async throws {
    let (lock, _) = controller(enabled: true)
    context.checks = [.cancelled]
    lock.scenePhaseChanged(.active)
    try await Task.sleep(for: .milliseconds(50))
    #expect(context.reasons.count == 1)
    #expect(lock.isLocked)

    lock.scenePhaseChanged(.inactive)
    lock.scenePhaseChanged(.active)
    try await Task.sleep(for: .milliseconds(50))
    #expect(context.reasons.count == 1)

    background(lock, for: .seconds(1))
    lock.scenePhaseChanged(.active)
    try await Task.sleep(for: .milliseconds(50))
    #expect(context.reasons.count == 2)
    #expect(!lock.isLocked)
  }

  @Test func turningTheLockOffStopsTheNextLock() async {
    let (lock, pref) = controller(enabled: true)
    await lock.unlock()
    pref.on = false
    background(lock, for: .seconds(600))
    lock.scenePhaseChanged(.active)
    #expect(!lock.isLocked)
  }

  @Test func aFailedCheckSaysSoAndStaysLocked() async {
    context.checks = [.failed]
    let (lock, _) = controller(enabled: true)
    await lock.unlock()
    #expect(lock.isLocked)
    #expect(lock.failed)
    await lock.unlock()
    #expect(!lock.isLocked)
    #expect(!lock.failed)
  }

  @Test func withoutAPasscodeTheLockCannotHold() async {
    context.available = false
    let (lock, _) = controller(enabled: true)
    #expect(!lock.isLocked)
    #expect(!lock.isAvailable)

    context.available = true
    let (held, _) = controller(enabled: true)
    context.available = false
    context.checks = [.unavailable]
    await held.unlock()
    #expect(!held.isLocked)
  }

  @Test func changingTheSettingAsksFirst() async {
    let (lock, _) = controller(enabled: false)
    context.checks = [.cancelled, .passed]
    #expect(await lock.confirmChange(to: true) == false)
    #expect(await lock.confirmChange(to: true))
    #expect(context.reasons == ["Turn on Face ID lock for Hasala.", "Turn on Face ID lock for Hasala."])
  }

  @Test func theWordsFollowTheBiometry() {
    #expect(LockBiometry(.faceID).unlockTitle == "Unlock with Face ID")
    #expect(LockBiometry(.touchID).lockTitle == "Touch ID lock")
    #expect(LockBiometry(.none).unlockTitle == "Unlock with passcode")
    #expect(LockBiometry(.faceID).icon == .faceID)
    #expect(LockBiometry(.touchID).icon == .lock)
  }

  @Test func systemErrorsMapToChecks() {
    #expect(LockCheck(LAError(.userCancel)) == .cancelled)
    #expect(LockCheck(LAError(.systemCancel)) == .cancelled)
    #expect(LockCheck(LAError(.passcodeNotSet)) == .unavailable)
    #expect(LockCheck(LAError(.authenticationFailed)) == .failed)
    #expect(LockCheck(nil) == .failed)
  }
}
