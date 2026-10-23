import AVFoundation
import Foundation

nonisolated final class SortSound: @unchecked Sendable {
  static let shared = SortSound()

  enum Tone {
    static let sampleRate: Double = 44_100
    static let duration: Double = 0.12
    static let fundamental: Double = 880
    static let overtone: Double = 1_320
    static let overtoneLevel: Double = 0.45
    static let attack: Double = 0.004
    static let decay: Double = 0.032
    static let release: Double = 0.008
    static let gain: Double = 0.2
  }

  static let fileName = "sort-success"
  static let fileExtension = "caf"

  static let isSilenced: Bool = {
    let environment = ProcessInfo.processInfo.environment
    return environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
      || environment["XCTestConfigurationFilePath"] != nil
      || environment["XCTestSessionIdentifier"] != nil
  }()

  private let queue = DispatchQueue(label: "app.hasala.sortsound", qos: .userInteractive)
  private var engine: AVAudioEngine?
  private var player: AVAudioPlayerNode?
  private var buffer: AVAudioPCMBuffer?
  private var sessionReady = false
  private var failed = false

  private init() {}

  func prepare() {
    guard !Self.isSilenced else { return }
    queue.async { _ = self.ready() }
  }

  func play() {
    guard !Self.isSilenced else { return }
    queue.async {
      guard self.ready(), let player = self.player, let buffer = self.buffer else { return }
      player.scheduleBuffer(buffer, at: nil, options: .interrupts)
      if !player.isPlaying { player.play() }
    }
  }

  func rest() {
    guard !Self.isSilenced else { return }
    queue.async {
      self.player?.stop()
      self.engine?.pause()
    }
  }

  private func ready() -> Bool {
    guard !failed else { return false }
    if !sessionReady {
      do {
        try AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
        sessionReady = true
      } catch {
        failed = true
        return false
      }
    }
    if engine == nil {
      guard let buffer = Self.bundledBuffer() ?? Self.toneBuffer() else {
        failed = true
        return false
      }
      let engine = AVAudioEngine()
      let player = AVAudioPlayerNode()
      engine.attach(player)
      engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
      engine.prepare()
      self.engine = engine
      self.player = player
      self.buffer = buffer
    }
    guard let engine else { return false }
    if !engine.isRunning {
      do {
        try engine.start()
      } catch {
        return false
      }
    }
    return true
  }

  static func bundledBuffer(in bundle: Bundle = .main) -> AVAudioPCMBuffer? {
    guard let url = bundle.url(forResource: fileName, withExtension: fileExtension),
      let file = try? AVAudioFile(forReading: url),
      let buffer = AVAudioPCMBuffer(
        pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
    else { return nil }
    do {
      try file.read(into: buffer)
    } catch {
      return nil
    }
    return buffer
  }

  static func toneSamples() -> [Float] {
    let count = Int((Tone.sampleRate * Tone.duration).rounded())
    let releaseFrames = Double(Int(Tone.sampleRate * Tone.release))
    let peak = 1 + Tone.overtoneLevel
    return (0..<count).map { index in
      let t = Double(index) / Tone.sampleRate
      let attack = min(1, t / Tone.attack)
      let decay = exp(-t / Tone.decay)
      let remaining = Double(count - 1 - index)
      let release = min(1, remaining / releaseFrames)
      let wave =
        sin(2 * .pi * Tone.fundamental * t)
        + Tone.overtoneLevel * sin(2 * .pi * Tone.overtone * t)
      return Float(Tone.gain * attack * decay * release * wave / peak)
    }
  }

  static func toneBuffer() -> AVAudioPCMBuffer? {
    let samples = toneSamples()
    guard let format = AVAudioFormat(standardFormatWithSampleRate: Tone.sampleRate, channels: 1),
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
      let channel = buffer.floatChannelData?[0]
    else { return nil }
    for (index, sample) in samples.enumerated() { channel[index] = sample }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    return buffer
  }
}
