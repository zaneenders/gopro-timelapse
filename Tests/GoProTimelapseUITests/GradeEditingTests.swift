import Foundation
import GoProTimelapseCore
import Testing

@testable import GoProTimelapseUI

@Test @MainActor func exposureEditPreservesWhiteBalanceAndOtherControls() {
  for temperature: Double? in [nil, 4_300] {
    let state = TimelapseUIState()
    state.frames = [URL(fileURLWithPath: "/tmp/grade-edit.gpr")]
    let original = Grade(
      temperature: temperature, tint: 12, contrast: 1.2,
      saturation: 0.8, vibrance: 0.3, shadows: 0.2, highlights: 0.7)
    state.gradeKeyframes = [0: original]
    state.temperature = temperature ?? 5_200

    state.adjustExposure(by: 0.25)

    #expect(state.gradeKeyframes[0] == original.addingExposure(0.25))
  }
}

@Test @MainActor func unchangedKeyframeInsertionPreservesAsShotGrade() {
  let state = TimelapseUIState()
  state.frames = (0..<3).map { URL(fileURLWithPath: "/tmp/grade-edit-\($0).gpr") }
  let original = Grade(exposure: 1, tint: 12, saturation: 0.8)
  state.gradeKeyframes = [0: original, 2: original]
  state.selectedFrame = 1
  state.exposure = original.exposure
  state.temperature = 5_200

  state.setCurrentKeyframe()

  #expect(state.gradeKeyframes[1] == original)
}

@Test @MainActor func temperatureEditExplicitlyReplacesAsShotWhiteBalance() {
  let state = TimelapseUIState()
  state.frames = [URL(fileURLWithPath: "/tmp/grade-edit.gpr")]
  let original = Grade(exposure: 1, tint: 12, saturation: 0.8)
  state.gradeKeyframes = [0: original]
  state.exposure = original.exposure

  state.adjustTemperature(by: 100)

  var expected = original
  expected.temperature = 5_300
  #expect(state.gradeKeyframes[0] == expected)
}

@Test @MainActor func firstExposureEditKeepsDaylightDefault() {
  let state = TimelapseUIState()
  state.frames = [URL(fileURLWithPath: "/tmp/grade-edit.gpr")]

  state.adjustExposure(by: 0.25)

  #expect(state.gradeKeyframes[0] == Grade(exposure: 0.25, temperature: 5_200))
}
