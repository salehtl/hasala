import AVFoundation
import Testing

@testable import Hasala

@Suite("Sort sound tone")
struct SortSoundTests {
  @Test func theToneHasItsLengthIsAudibleAndNeverClips() throws {
    let buffer = try #require(SortSound.toneBuffer())
    let expected = Int((SortSound.Tone.sampleRate * SortSound.Tone.duration).rounded())
    #expect(Int(buffer.frameLength) == expected)
    #expect(buffer.format.channelCount == 1)
    #expect(buffer.format.sampleRate == SortSound.Tone.sampleRate)
    let channel = try #require(buffer.floatChannelData?[0])
    let samples = (0..<Int(buffer.frameLength)).map { channel[$0] }
    let peak = samples.map(abs).max() ?? 0
    #expect(peak > 0.05)
    #expect(peak <= Float(SortSound.Tone.gain) + 0.0001)
    #expect(samples.allSatisfy { $0.isFinite && abs($0) <= 1 })
  }

  @Test func theToneStartsAndEndsAtSilence() {
    let samples = SortSound.toneSamples()
    #expect(samples.first == 0)
    #expect(samples.last == 0)
  }

  @Test func withNoBundledFileTheToneIsUsed() {
    #expect(SortSound.bundledBuffer(in: Bundle(for: BundleToken.self)) == nil)
  }
}

private final class BundleToken {}
