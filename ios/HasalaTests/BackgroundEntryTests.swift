import Testing
import UIKit

@testable import Hasala

@MainActor
@Suite("Background launches start the live graph themselves")
struct BackgroundEntryTests {
  final class Log {
    var events: [String] = []
  }

  func entry(_ log: Log, runtime: Int?) -> BackgroundEntry<Int> {
    BackgroundEntry(
      start: { log.events.append("start") },
      opened: {
        log.events.append("opened")
        return runtime
      })
  }

  @Test func onlyAForegroundLaunchStartsTheGraphAtLaunch() {
    #expect(!AppDelegate.startsAtLaunch(.background))
    #expect(AppDelegate.startsAtLaunch(.active) && AppDelegate.startsAtLaunch(.inactive))
  }

  @Test func aSilentPushStartsTheGraphBeforeItWaitsForTheAccount() async {
    let log = Log()
    let result = await AppDelegate.silentPush(entry(log, runtime: 7)) { rt, budget in
      log.events.append("run \(rt)")
      #expect(budget > .zero && budget <= AppDelegate.silentPushBudget)
      return .newData
    }
    #expect(result == .newData)
    #expect(log.events == ["start", "opened", "run 7"])
  }

  @Test func aSilentPushWithNoOpenAccountReportsNoData() async {
    let log = Log()
    let result = await AppDelegate.silentPush(entry(log, runtime: nil)) { _, _ in
      log.events.append("run")
      return .newData
    }
    #expect(result == .noData && log.events == ["start", "opened"])
    let none: BackgroundEntry<Int>? = nil
    #expect(await AppDelegate.silentPush(none) { _, _ in .newData } == .noData)
  }

  @Test func aBackgroundTaskStartsTheGraphBeforeItRuns() async {
    let log = Log()
    let more = await BackgroundEntry.task(entry(log, runtime: 3)) { rt in
      log.events.append("work \(rt)")
      return true
    }
    #expect(more && log.events == ["start", "opened", "work 3"])
    let idle = Log()
    #expect(!(await BackgroundEntry.task(entry(idle, runtime: nil)) { _ in true }))
    #expect(idle.events == ["start", "opened"])
  }

  @Test func theLiveEntryIsNilInATestProcessWithNoGraph() {
    if AppGraph.boot == nil { #expect(BackgroundEntry.live() == nil) }
  }
}
