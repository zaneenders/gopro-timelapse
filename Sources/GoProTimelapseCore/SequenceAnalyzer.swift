import Foundation
import Libraw

public struct SequenceAnalysisSettings: Sendable {
  public var jobs: Int
  public var maximumWidth: Int
  public var denoise: Double
  public var temperature: Double
  public var correction: AutomaticCorrectionSettings

  public init(
    jobs: Int = 0,
    maximumWidth: Int = 640,
    denoise: Double = 0.7,
    temperature: Double = 5_200,
    correction: AutomaticCorrectionSettings = AutomaticCorrectionSettings()
  ) {
    self.jobs = jobs
    self.maximumWidth = maximumWidth
    self.denoise = denoise
    self.temperature = temperature
    self.correction = correction
  }
}

public enum SequenceAnalyzer {
  /// Converts each GPR to DNG and analyzes a fixed 16-bit LibRaw development.
  /// This is the same source domain used by ProRes rendering; JPEGs are not used.
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
            denoise: settings.denoise, temperature: settings.temperature)
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
        baseline: result.baseline, correction: result.correction, settings: settings.correction)
    )
  }

  private static func analyzeGPR(
    source: URL, frame: Int, maximumWidth: Int, denoise: Double, temperature: Double
  ) throws -> LuminanceSample {
    // Lock white balance so camera WB changes do not become luminance flicker.
    let image = try RAWDeveloper.developRGB16(
      source: source, grade: Grade(temperature: temperature),
      settings: .init(maximumWidth: maximumWidth, denoise: denoise))
    return luminance(
      width: image.width, height: image.height, rgb48LE: image.pixels, frame: frame)
  }

  private static func luminance(
    width: Int, height: Int, rgb48LE: Data, frame: Int
  ) -> LuminanceSample {
    guard width > 0, height > 0, rgb48LE.count >= width * height * 3 * 2 else {
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
    rgb48LE.withUnsafeBytes { bytes in
      let pixels = bytes.bindMemory(to: UInt8.self)
      func sample(_ byteOffset: Int) -> UInt16 {
        UInt16(pixels[byteOffset]) | (UInt16(pixels[byteOffset + 1]) << 8)
      }
      for y in Swift.stride(from: y0, to: min(y1, height), by: sampleStride) {
        for x in Swift.stride(from: x0, to: min(x1, width), by: sampleStride) {
          let offset = (y * width + x) * 3 * 2
          let r16 = sample(offset)
          let g16 = sample(offset + 2)
          let b16 = sample(offset + 4)
          if max(r16, max(g16, b16)) >= 64_250 { clipped += 1 }
          func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
          }
          let luminance =
            0.2126 * linear(Double(r16) / 65_535)
            + 0.7152 * linear(Double(g16) / 65_535)
            + 0.0722 * linear(Double(b16) / 65_535)
          values.append(log2(max(luminance, 1e-6)))
          count += 1
        }
      }
    }
    values.sort()
    let middle = values.count / 2
    let median =
      values.isEmpty
      ? 0
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
