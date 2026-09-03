import Testing

@testable import GoProTimelapseUI

@Test func creativeGradesInterpolateSmoothly() {
  let keys = [
    0: UIGrade(exposure: 0, temperature: 4_000),
    100: UIGrade(exposure: 2, temperature: 6_000),
  ]
  let middle = ExposureWorkflow.grade(at: 50, keyframes: keys, frameCount: 101)
  #expect(abs(middle.exposure - 1) < 0.0001)
  #expect(abs(middle.temperature - 5_000) < 0.0001)
}

@Test func automaticCorrectionReducesIsolatedFlickerWithoutFlatteningTrend() {
  var samples: [LuminanceSample] = []
  for frame in 0..<120 {
    let trend = -4.0 + Double(frame) / 60
    let flicker = frame.isMultiple(of: 11) ? 0.35 : frame.isMultiple(of: 17) ? -0.25 : 0
    samples.append(
      LuminanceSample(
        frame: frame, medianLogLuminance: trend + flicker,
        clippedHighlightFraction: 0))
  }
  let result = ExposureWorkflow.automaticCorrection(samples: samples, window: 21)
  #expect(result.correction.count == samples.count)
  #expect(result.correction.map(abs).max()! <= 0.75)
  let originalResidual = samples.indices.map {
    samples[$0].medianLogLuminance - result.baseline[$0]
  }
  let correctedResidual = samples.indices.map {
    samples[$0].medianLogLuminance + result.correction[$0] - result.baseline[$0]
  }
  let originalEnergy = originalResidual.reduce(0) { $0 + $1 * $1 }
  let correctedEnergy = correctedResidual.reduce(0) { $0 + $1 * $1 }
  #expect(correctedEnergy < originalEnergy)
}
