import Foundation
import Testing

@testable import GoProTimelapseCore

private func samples(_ values: [Double], clipped: Set<Int> = []) -> [LuminanceSample] {
  values.enumerated().map {
    LuminanceSample(
      frame: $0.offset,
      medianLogLuminance: $0.element,
      clippedHighlightFraction: clipped.contains($0.offset) ? 0.1 : 0)
  }
}

@Test func everyFrameIncludingFirstReceivesACorrection() {
  let values = [0.40] + [Double](repeating: 0, count: 99)
  let result = ExposureWorkflow.automaticCorrection(
    samples: samples(values),
    settings: AutomaticCorrectionSettings(
      baselineWindowFraction: 0.2,
      correctionSmoothingFraction: 0,
      maximumCorrection: 0.5,
      maximumDeltaPerFrame: 0.5))

  #expect(result.correction.count == values.count)
  #expect(result.correction[0] < -0.1)
}

@Test func percentageWindowPreservesSmoothSequenceTrend() {
  let values = (0..<300).map { -4.0 + Double($0) * 3.0 / 299.0 }
  let result = ExposureWorkflow.automaticCorrection(
    samples: samples(values),
    settings: AutomaticCorrectionSettings(baselineWindowFraction: 0.1))

  #expect(result.correction.map(abs).max()! < 0.03)
}

@Test func robustFitRejectsIsolatedFlickerAndReducesResidualEnergy() {
  var values = (0..<240).map { -3.0 + Double($0) / 180.0 }
  for frame in stride(from: 7, to: values.count, by: 23) { values[frame] += 0.35 }
  for frame in stride(from: 13, to: values.count, by: 31) { values[frame] -= 0.25 }
  let result = ExposureWorkflow.automaticCorrection(
    samples: samples(values),
    settings: AutomaticCorrectionSettings(
      baselineWindowFraction: 0.1,
      correctionSmoothingFraction: 0))
  let before = zip(values, result.baseline).reduce(0) { $0 + pow($1.0 - $1.1, 2) }
  let after = zip(zip(values, result.correction), result.baseline).reduce(0) {
    $0 + pow($1.0.0 + $1.0.1 - $1.1, 2)
  }

  #expect(after < before)
}

@Test func highlightProtectionNeverBrightensClippedFrame() {
  let values = [Double](repeating: -2, count: 30).enumerated().map {
    $0.offset == 15 ? -2.4 : $0.element
  }
  let result = ExposureWorkflow.automaticCorrection(
    samples: samples(values, clipped: [15]),
    settings: AutomaticCorrectionSettings(correctionSmoothingFraction: 0))

  #expect(result.correction[15] <= 0)
}

@Test func luminanceIncludesPixelZeroAndFrameZero() {
  let rgba = Data([128, 128, 128, 255])
  let result = ExposureWorkflow.luminance(width: 1, height: 1, rgba8: rgba, frame: 0)

  #expect(result.frame == 0)
  #expect(result.medianLogLuminance < 0)
  #expect(result.clippedHighlightFraction == 0)
}
