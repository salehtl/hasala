import CoreCategorize
import Foundation
import Testing

@testable import Hasala

@Suite("Model suggestion stage")
struct ModelSuggestionStageTests {
  struct Fake: CategoryModel {
    let modelTag: String
    let state: ModelAvailability
    func availability() -> ModelAvailability { state }
    func suggest(subject: String, allowed: [AllowedCategory]) async -> ModelAnswer { .unknown }
  }

  let apple = Fake(modelTag: "apple-fm/27.1", state: .available)

  @Test func clefRunsFirstWhenTheSwitchIsOn() {
    let stages = ModelSuggestionStage.stages(
      onDevice: apple, cloud: Fake(modelTag: "cf-clef/1", state: .available), onDeviceAlone: false)
    #expect(stages.map(\.model.modelTag) == ["cf-clef/1", "apple-fm/27.1"])
    #expect(stages[0].accepts("مطعم الياسمين الشعبي"))
    #expect(!stages[1].accepts("مطعم الياسمين الشعبي"))
  }

  @Test func noModelRunsInReleaseWhenTheSwitchIsOff() {
    let off = Fake(modelTag: "cf-clef/1", state: .notEnabled)
    #expect(ModelSuggestionStage.stages(onDevice: apple, cloud: off, onDeviceAlone: false).isEmpty)
    #expect(ModelSuggestionStage.stages(onDevice: apple, cloud: nil, onDeviceAlone: false).isEmpty)
  }

  @Test func debugRunsTheOnDeviceModelAloneWhenTheSwitchIsOff() {
    let off = Fake(modelTag: "cf-clef/1", state: .notEnabled)
    #expect(ModelSuggestionStage.stages(onDevice: apple, cloud: off, onDeviceAlone: true).map(\.model.modelTag) == ["apple-fm/27.1"])
    #expect(ModelSuggestionStage.stages(onDevice: apple, cloud: nil, onDeviceAlone: true).map(\.model.modelTag) == ["apple-fm/27.1"])
  }

  @Test func onlyForegroundTriggersRunTheSweep() {
    let runs = WorkCoordinator.Trigger.allCases.filter(ModelSuggestionStage.runs)
    #expect(Set(runs) == [.launch, .foreground, .refresh])
  }
}
