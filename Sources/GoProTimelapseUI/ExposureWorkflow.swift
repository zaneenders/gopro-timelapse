import Chroma
import Foundation

public struct UIGrade: Equatable, Sendable {
  public var exposure: Double
  public var temperature: Double

  public init(exposure: Double = 0, temperature: Double = 5_200) {
    self.exposure = exposure
    self.temperature = temperature
  }
}

public struct LuminanceSample: Equatable, Sendable {
  public var frame: Int
  public var medianLogLuminance: Double
  public var clippedHighlightFraction: Double

  public init(frame: Int, medianLogLuminance: Double, clippedHighlightFraction: Double) {
    self.frame = frame
    self.medianLogLuminance = medianLogLuminance
    self.clippedHighlightFraction = clippedHighlightFraction
  }
}

public enum ExposureWorkflow {
  public static func grade(
    at frame: Int,
    keyframes: [Int: UIGrade],
    frameCount: Int
  ) -> UIGrade {
    guard !keyframes.isEmpty else { return UIGrade() }
    let positions = keyframes.keys.sorted()
    guard let first = positions.first, let last = positions.last else { return UIGrade() }
    if frame <= first { return keyframes[first]! }
    if frame >= last { return keyframes[last]! }
    let upper = positions.firstIndex(where: { $0 >= frame })!
    let lowerFrame = positions[upper - 1]
    let upperFrame = positions[upper]
    let a = keyframes[lowerFrame]!
    let b = keyframes[upperFrame]!
    var t = Double(frame - lowerFrame) / Double(upperFrame - lowerFrame)
    t = t * t * (3 - 2 * t)
    return UIGrade(
      exposure: a.exposure + (b.exposure - a.exposure) * t,
      temperature: a.temperature + (b.temperature - a.temperature) * t)
  }

  /// Produces a robust long-term target and a bounded residual correction in stops.
  /// The broad median preserves sunrise/sunset movement while rejecting isolated
  /// flicker and camera-setting jumps. A triangular smoothing pass prevents the
  /// generated correction itself from pumping.
  public static func automaticCorrection(
    samples: [LuminanceSample],
    window: Int,
    maximumCorrection: Double = 0.75,
    maximumDelta: Double = 0.15
  ) -> (baseline: [Double], correction: [Double]) {
    guard !samples.isEmpty else { return ([], []) }
    let signal = samples.map(\.medianLogLuminance)
    let radius = max(2, min(max(2, window / 2), max(2, signal.count / 3)))
    var baseline = [Double](repeating: 0, count: signal.count)
    for index in signal.indices {
      let lower = max(0, index - radius)
      let upper = min(signal.count - 1, index + radius)
      baseline[index] = median(Array(signal[lower...upper]))
    }
    baseline = triangularSmooth(baseline, radius: max(1, radius / 3))

    var correction = zip(baseline, signal).map { target, measured in
      min(maximumCorrection, max(-maximumCorrection, target - measured))
    }
    // Highlight protection: avoid aggressively lifting already clipped frames.
    for index in correction.indices where samples[index].clippedHighlightFraction > 0.02 {
      correction[index] = min(correction[index], 0)
    }
    correction = triangularSmooth(correction, radius: 1)
    for index in correction.indices.dropFirst() {
      correction[index] = min(
        correction[index - 1] + maximumDelta,
        max(correction[index - 1] - maximumDelta, correction[index]))
    }
    for index in correction.indices.dropLast().reversed() {
      correction[index] = min(
        correction[index + 1] + maximumDelta,
        max(correction[index + 1] - maximumDelta, correction[index]))
    }
    let mean = correction.reduce(0, +) / Double(correction.count)
    correction = correction.map { min(maximumCorrection, max(-maximumCorrection, $0 - mean)) }
    return (baseline, correction)
  }

  public static func luminance(of image: ImageResource, frame: Int) -> LuminanceSample {
    let width = image.width
    let height = image.height
    let x0 = Int(Double(width) * 0.15)
    let x1 = max(x0 + 1, Int(Double(width) * 0.85))
    let y0 = Int(Double(height) * 0.15)
    let y1 = max(y0 + 1, Int(Double(height) * 0.85))
    let stride = max(1, max(width, height) / 320)
    var values: [Double] = []
    values.reserveCapacity(((x1 - x0) / stride + 1) * ((y1 - y0) / stride + 1))
    var clipped = 0
    var count = 0
    image.rgba8.withUnsafeBytes { bytes in
      let pixels = bytes.bindMemory(to: UInt8.self)
      for y in Swift.stride(from: y0, to: min(y1, height), by: stride) {
        for x in Swift.stride(from: x0, to: min(x1, width), by: stride) {
          let offset = (y * width + x) * 4
          let r8 = pixels[offset]
          let g8 = pixels[offset + 1]
          let b8 = pixels[offset + 2]
          if max(r8, max(g8, b8)) >= 250 { clipped += 1 }
          let r = linear(Double(r8) / 255)
          let g = linear(Double(g8) / 255)
          let b = linear(Double(b8) / 255)
          let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
          values.append(log2(max(y, 1e-6)))
          count += 1
        }
      }
    }
    return LuminanceSample(
      frame: frame,
      medianLogLuminance: median(values),
      clippedHighlightFraction: count == 0 ? 0 : Double(clipped) / Double(count))
  }

  private static func linear(_ value: Double) -> Double {
    value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
  }

  private static func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    return sorted.count.isMultiple(of: 2)
      ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
  }

  private static func triangularSmooth(_ values: [Double], radius: Int) -> [Double] {
    guard radius > 0, values.count > 2 else { return values }
    return values.indices.map { index in
      var weighted = 0.0
      var total = 0.0
      for offset in -radius...radius {
        let sample = min(values.count - 1, max(0, index + offset))
        let weight = Double(radius + 1 - abs(offset))
        weighted += values[sample] * weight
        total += weight
      }
      return weighted / total
    }
  }
}
