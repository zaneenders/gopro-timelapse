import Foundation

public struct UIGrade: Equatable, Sendable {
  public var exposure: Double
  public var temperature: Double

  public init(exposure: Double = 0, temperature: Double = 5_200) {
    self.exposure = exposure
    self.temperature = temperature
  }
}

public struct LuminanceSample: Codable, Equatable, Sendable {
  public var frame: Int
  public var medianLogLuminance: Double
  public var clippedHighlightFraction: Double

  public init(frame: Int, medianLogLuminance: Double, clippedHighlightFraction: Double) {
    self.frame = frame
    self.medianLogLuminance = medianLogLuminance
    self.clippedHighlightFraction = clippedHighlightFraction
  }
}

public struct AutomaticCorrectionSettings: Equatable, Sendable {
  /// Fraction of the sequence used by the long-term trend fit.
  public var baselineWindowFraction: Double
  /// Fraction of the sequence used to smooth the generated residual correction.
  public var correctionSmoothingFraction: Double
  public var maximumCorrection: Double
  public var maximumDeltaPerFrame: Double
  public var robustIterations: Int
  public var clippedHighlightThreshold: Double

  public init(
    baselineWindowFraction: Double = 0.10,
    correctionSmoothingFraction: Double = 0.0025,
    maximumCorrection: Double = 0.5,
    maximumDeltaPerFrame: Double = 0.10,
    robustIterations: Int = 3,
    clippedHighlightThreshold: Double = 0.02
  ) {
    self.baselineWindowFraction = baselineWindowFraction
    self.correctionSmoothingFraction = correctionSmoothingFraction
    self.maximumCorrection = maximumCorrection
    self.maximumDeltaPerFrame = maximumDeltaPerFrame
    self.robustIterations = robustIterations
    self.clippedHighlightThreshold = clippedHighlightThreshold
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

  /// Fits a robust long-term scene trend and returns a bounded, dense per-frame
  /// residual correction. Window sizes are fractions of the sequence so the
  /// behavior scales with short and long captures.
  public static func automaticCorrection(
    samples: [LuminanceSample],
    settings: AutomaticCorrectionSettings = AutomaticCorrectionSettings()
  ) -> (baseline: [Double], correction: [Double]) {
    guard !samples.isEmpty else { return ([], []) }
    guard samples.count > 2 else {
      return (samples.map(\.medianLogLuminance), [Double](repeating: 0, count: samples.count))
    }

    let signal = samples.map(\.medianLogLuminance)
    let window = oddWindow(
      fraction: settings.baselineWindowFraction,
      count: signal.count,
      minimum: min(9, signal.count))
    // A robust regression alone can give an endpoint outlier full leverage: the
    // fitted line passes through frame 0 and then reports no residual there.
    // Hampel-clean the fit input first, while retaining the original signal as
    // the value that correction is calculated against.
    let cleanedSignal = hampelClean(signal, radius: max(2, min(12, window / 4)))
    let baseline = robustLOESS(cleanedSignal, window: window, iterations: settings.robustIterations)

    let limit = max(0, settings.maximumCorrection)
    var correction = zip(baseline, signal).map { target, measured in
      min(limit, max(-limit, target - measured))
    }

    // Never lift an already clipped frame. This is deliberately asymmetric:
    // lowering a clipped frame is safe, lifting it can amplify channel clipping.
    for index in correction.indices
    where samples[index].clippedHighlightFraction > settings.clippedHighlightThreshold
    {
      correction[index] = min(correction[index], 0)
    }

    let smoothingRadius = max(
      1, Int((Double(signal.count) * max(0, settings.correctionSmoothingFraction)).rounded()))
    correction = triangularSmooth(correction, radius: min(8, smoothingRadius))
    correction = limitSlope(correction, maximumDelta: max(0, settings.maximumDeltaPerFrame))

    // Deflicker must not alter the sequence's overall creative exposure. Use a
    // robust center so one bad endpoint cannot shift every frame, including 0.
    let center = median(correction)
    correction = correction.map { min(limit, max(-limit, $0 - center)) }
    return (baseline, correction)
  }

  /// Compatibility overload for callers that specify an absolute frame window.
  public static func automaticCorrection(
    samples: [LuminanceSample],
    window: Int,
    maximumCorrection: Double = 0.5,
    maximumDelta: Double = 0.10
  ) -> (baseline: [Double], correction: [Double]) {
    let fraction = samples.isEmpty ? 0.10 : Double(max(3, window)) / Double(samples.count)
    return automaticCorrection(
      samples: samples,
      settings: AutomaticCorrectionSettings(
        baselineWindowFraction: fraction,
        maximumCorrection: maximumCorrection,
        maximumDeltaPerFrame: maximumDelta))
  }

  public static func luminance(
    width: Int,
    height: Int,
    rgba8: Data,
    frame: Int
  ) -> LuminanceSample {
    guard width > 0, height > 0, rgba8.count >= width * height * 4 else {
      return LuminanceSample(frame: frame, medianLogLuminance: 0, clippedHighlightFraction: 0)
    }
    let x0 = Int(Double(width) * 0.15)
    let x1 = max(x0 + 1, Int(Double(width) * 0.85))
    let y0 = Int(Double(height) * 0.15)
    let y1 = max(y0 + 1, Int(Double(height) * 0.85))
    let sampleStride = max(1, max(width, height) / 320)
    var values: [Double] = []
    values.reserveCapacity(((x1 - x0) / sampleStride + 1) * ((y1 - y0) / sampleStride + 1))
    var clipped = 0
    var count = 0
    rgba8.withUnsafeBytes { bytes in
      let pixels = bytes.bindMemory(to: UInt8.self)
      for y in Swift.stride(from: y0, to: min(y1, height), by: sampleStride) {
        for x in Swift.stride(from: x0, to: min(x1, width), by: sampleStride) {
          let offset = (y * width + x) * 4
          let r8 = pixels[offset]
          let g8 = pixels[offset + 1]
          let b8 = pixels[offset + 2]
          if max(r8, max(g8, b8)) >= 250 { clipped += 1 }
          let r = linear(Double(r8) / 255)
          let g = linear(Double(g8) / 255)
          let b = linear(Double(b8) / 255)
          let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
          values.append(log2(max(luminance, 1e-6)))
          count += 1
        }
      }
    }
    return LuminanceSample(
      frame: frame,
      medianLogLuminance: median(values),
      clippedHighlightFraction: count == 0 ? 0 : Double(clipped) / Double(count))
  }

  private static func hampelClean(_ values: [Double], radius: Int) -> [Double] {
    guard values.count > 2 else { return values }
    return values.indices.map { index in
      let lower = max(0, index - radius)
      let upper = min(values.count - 1, index + radius)
      let neighborhood = Array(values[lower...upper])
      let center = median(neighborhood)
      let mad = median(neighborhood.map { abs($0 - center) })
      let threshold = max(0.02, 3 * 1.4826 * mad)
      return abs(values[index] - center) > threshold ? center : values[index]
    }
  }

  private static func robustLOESS(_ values: [Double], window: Int, iterations: Int) -> [Double] {
    let radius = max(1, window / 2)
    var robustWeights = [Double](repeating: 1, count: values.count)
    var fitted = values
    for iteration in 0...max(0, iterations) {
      fitted = values.indices.map { index in
        let lower = max(0, index - radius)
        let upper = min(values.count - 1, index + radius)
        var weightSum = 0.0
        var xSum = 0.0
        var ySum = 0.0
        for sample in lower...upper {
          let distance = Double(abs(sample - index)) / Double(radius + 1)
          let tricube = pow(max(0, 1 - pow(distance, 3)), 3)
          let weight = tricube * robustWeights[sample]
          weightSum += weight
          xSum += weight * Double(sample - index)
          ySum += weight * values[sample]
        }
        guard weightSum > 0 else { return values[index] }
        let xMean = xSum / weightSum
        let yMean = ySum / weightSum
        var numerator = 0.0
        var denominator = 0.0
        for sample in lower...upper {
          let x = Double(sample - index)
          let distance = Double(abs(sample - index)) / Double(radius + 1)
          let tricube = pow(max(0, 1 - pow(distance, 3)), 3)
          let weight = tricube * robustWeights[sample]
          numerator += weight * (x - xMean) * (values[sample] - yMean)
          denominator += weight * (x - xMean) * (x - xMean)
        }
        let slope = denominator > 1e-12 ? numerator / denominator : 0
        return yMean - slope * xMean
      }
      guard iteration < iterations else { break }
      let residuals = zip(values, fitted).map { abs($0 - $1) }
      let scale = max(1e-9, median(residuals) * 6)
      robustWeights = residuals.map { residual in
        let u = min(1, residual / scale)
        let weight = 1 - u * u
        return weight * weight
      }
    }
    return fitted
  }

  private static func oddWindow(fraction: Double, count: Int, minimum: Int) -> Int {
    var value = max(minimum, Int((Double(count) * min(1, max(0.001, fraction))).rounded()))
    value = min(count, value)
    if value.isMultiple(of: 2) { value += value < count ? 1 : -1 }
    return max(3, value)
  }

  private static func limitSlope(_ values: [Double], maximumDelta: Double) -> [Double] {
    guard maximumDelta > 0, values.count > 1 else { return values }
    var result = values
    for index in result.indices.dropFirst() {
      result[index] = min(
        result[index - 1] + maximumDelta,
        max(result[index - 1] - maximumDelta, result[index]))
    }
    for index in result.indices.dropLast().reversed() {
      result[index] = min(
        result[index + 1] + maximumDelta,
        max(result[index + 1] - maximumDelta, result[index]))
    }
    return result
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
