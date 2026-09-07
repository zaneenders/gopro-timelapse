import Foundation
import GprTools
import Libraw

public struct SequenceAnalysisSettings: Sendable {
  public var jobs: Int
  public var maximumWidth: Int
  public var denoise: Double
  public var correction: AutomaticCorrectionSettings

  public init(
    jobs: Int = 0,
    maximumWidth: Int = 640,
    denoise: Double = 0.4,
    correction: AutomaticCorrectionSettings = AutomaticCorrectionSettings()
  ) {
    self.jobs = jobs
    self.maximumWidth = maximumWidth
    self.denoise = denoise
    self.correction = correction
  }
}

public enum SequenceAnalyzer {
  /// Analyzes GPR files with a fixed RAW development path. This is the same
  /// source domain used by final RAW rendering; paired camera JPEGs are not used.
  public static func analyzeGPR(
    sources: [URL],
    settings: SequenceAnalysisSettings = SequenceAnalysisSettings(),
    progress: @escaping @Sendable (_ completed: Int, _ total: Int) -> Void = { _, _ in }
  ) async throws -> (samples: [LuminanceSample], correction: AutomaticCorrectionFile) {
    guard !sources.isEmpty else { throw SequenceAnalysisError.emptySequence }
    let workerCount = min(
      sources.count,
      settings.jobs > 0 ? settings.jobs : max(1, ProcessInfo.processInfo.activeProcessorCount))
    let state = AnalysisState(total: sources.count)

    try await withThrowingTaskGroup(of: Void.self) { group in
      var next = 0
      func enqueue(_ index: Int) {
        group.addTask {
          try Task.checkCancellation()
          let sample = try analyzeGPR(
            source: sources[index], frame: index, maximumWidth: settings.maximumWidth,
            denoise: settings.denoise)
          let completed = await state.store(sample)
          progress(completed, sources.count)
        }
      }
      while next < workerCount {
        enqueue(next)
        next += 1
      }
      while try await group.next() != nil {
        if next < sources.count {
          enqueue(next)
          next += 1
        }
      }
    }

    let samples = await state.orderedSamples()
    guard samples.count == sources.count else { throw SequenceAnalysisError.incompleteSequence }
    let result = ExposureWorkflow.automaticCorrection(
      samples: samples, settings: settings.correction)
    return (
      samples,
      AutomaticCorrectionFile(
        baseline: result.baseline, correction: result.correction, settings: settings.correction))
  }

  private static func analyzeGPR(
    source: URL, frame: Int, maximumWidth: Int, denoise: Double
  ) throws -> LuminanceSample {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
      "gopro-analysis-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let dng = temporary.appendingPathComponent("frame.dng")
    try GprTools.convert(gprFile: source.path, toDNG: dng.path)
    let developer = Libraw()
    try developer.open(dng.path)
    // Fixed development settings across the entire sequence. Temperature zero
    // currently asks LibRaw for camera WB; a fixed multiplier API is future work.
    developer.setGrade(LibrawGrade())
    developer.setDenoise(denoise)
    developer.setMaxWidth(maximumWidth)
    let image = try developer.developRGB()
    return luminance(
      width: image.width, height: image.height, rgb24: image.pixels, frame: frame)
  }

  private static func luminance(
    width: Int, height: Int, rgb24: Data, frame: Int
  ) -> LuminanceSample {
    guard width > 0, height > 0, rgb24.count >= width * height * 3 else {
      return LuminanceSample(frame: frame, medianLogLuminance: 0, clippedHighlightFraction: 0)
    }
    let x0 = Int(Double(width) * 0.15)
    let x1 = max(x0 + 1, Int(Double(width) * 0.85))
    let y0 = Int(Double(height) * 0.15)
    let y1 = max(y0 + 1, Int(Double(height) * 0.85))
    let sampleStride = max(1, max(width, height) / 320)
    var values: [Double] = []
    var clipped = 0
    var count = 0
    rgb24.withUnsafeBytes { bytes in
      let pixels = bytes.bindMemory(to: UInt8.self)
      for y in Swift.stride(from: y0, to: min(y1, height), by: sampleStride) {
        for x in Swift.stride(from: x0, to: min(x1, width), by: sampleStride) {
          let offset = (y * width + x) * 3
          let r8 = pixels[offset]
          let g8 = pixels[offset + 1]
          let b8 = pixels[offset + 2]
          if max(r8, max(g8, b8)) >= 250 { clipped += 1 }
          func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
          }
          let luminance =
            0.2126 * linear(Double(r8) / 255)
            + 0.7152 * linear(Double(g8) / 255)
            + 0.0722 * linear(Double(b8) / 255)
          values.append(log2(max(luminance, 1e-6)))
          count += 1
        }
      }
    }
    values.sort()
    let middle = values.count / 2
    let median = values.isEmpty ? 0
      : values.count.isMultiple(of: 2)
      ? (values[middle - 1] + values[middle]) / 2 : values[middle]
    return LuminanceSample(
      frame: frame, medianLogLuminance: median,
      clippedHighlightFraction: count == 0 ? 0 : Double(clipped) / Double(count))
  }
}

private actor AnalysisState {
  private var samples: [LuminanceSample?]
  private var completed = 0

  init(total: Int) {
    samples = [LuminanceSample?](repeating: nil, count: total)
  }

  func store(_ sample: LuminanceSample) -> Int {
    samples[sample.frame] = sample
    completed += 1
    return completed
  }

  func orderedSamples() -> [LuminanceSample] { samples.compactMap { $0 } }
}

public enum SequenceAnalysisError: Error, CustomStringConvertible {
  case emptySequence
  case incompleteSequence

  public var description: String {
    switch self {
    case .emptySequence: "No frames to analyze"
    case .incompleteSequence: "Analysis did not produce one sample per frame"
    }
  }
}
