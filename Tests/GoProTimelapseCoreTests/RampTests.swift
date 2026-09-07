import Foundation
import GoProTimelapseCore
import Testing

@Test func linearRamp() {
  let ramp = RampFile(
    interpolation: "linear",
    keyframes: [
      Keyframe(frame: 0, exposure: 0, temperature: 4000),
      Keyframe(frame: 100, exposure: 2, temperature: 6000),
    ])
  let middle = interpolatedGrade(frame: 50, ramp: ramp)
  #expect(middle.exposure == 1)
  #expect(middle.temperature == 5000)
}

@Test func rampClampsOutsideKeyframes() {
  let ramp = RampFile(keyframes: [Keyframe(frame: 10, exposure: 1), Keyframe(frame: 20, exposure: 2)])
  #expect(interpolatedGrade(frame: 0, ramp: ramp).exposure == 1)
  #expect(interpolatedGrade(frame: 30, ramp: ramp).exposure == 2)
}

@Test func emptySingleAndDuplicateRamps() {
  #expect(RampFile(keyframes: []).grade(at: 10) == Grade())
  let grade = Grade(exposure: 2, tint: 10, saturation: 0.8)
  let single = RampFile(keyframes: [Keyframe(frame: 10, grade: grade)])
  for frame in [-10, 10, 100] { #expect(single.grade(at: frame) == grade) }
  let duplicate = RampFile(keyframes: [
    Keyframe(frame: 20, exposure: 4), Keyframe(frame: 10, exposure: 1),
    Keyframe(frame: 10, grade: grade),
  ])
  #expect(duplicate.grade(at: 10) == grade)
  #expect(duplicate.grade(at: 0) == grade)
}

@Test func allControlsInterpolateAndMapToLibraw() {
  let a = Grade(
    exposure: 0, temperature: 4000, tint: -10, contrast: 1,
    saturation: 0.8, vibrance: 0, shadows: -0.2, highlights: 0)
  let b = Grade(
    exposure: 2, temperature: 6000, tint: 10, contrast: 1.2,
    saturation: 1.2, vibrance: 0.4, shadows: 0.2, highlights: 0.8)
  for mode in ["linear", "smooth"] {
    let ramp = RampFile(
      interpolation: mode,
      keyframes: [
        Keyframe(frame: 0, grade: a), Keyframe(frame: 100, grade: b),
      ])
    let middle = ramp.grade(at: 50)
    #expect(
      middle
        == Grade(
          exposure: 1, temperature: 5000, tint: 0, contrast: 1.1,
          saturation: 1, vibrance: 0.2, shadows: 0, highlights: 0.4))
    let raw = middle.librawGrade
    #expect(raw.exposure == middle.exposure)
    #expect(raw.temperature == middle.temperature)
    #expect(raw.tint == middle.tint)
    #expect(raw.contrast == middle.contrast)
    #expect(raw.saturation == middle.saturation)
    #expect(raw.vibrance == middle.vibrance)
    #expect(raw.shadows == middle.shadows)
    #expect(raw.highlights == middle.highlights)
    #expect(ramp.grade(at: 0) == a)
    #expect(ramp.grade(at: 100) == b)
  }
}

@Test func optionalWhiteBalanceAndExactAnchors() {
  let ramp = RampFile(keyframes: [
    Keyframe(frame: 0, temperature: 4000),
    Keyframe(frame: 10), Keyframe(frame: 20, temperature: 6000),
  ])
  #expect(ramp.grade(at: 5).temperature == 4000)
  #expect(ramp.grade(at: 10).temperature == nil)
  #expect(ramp.grade(at: 15).temperature == 6000)
  #expect(Grade().librawGrade.temperature == 0)
  #expect(Grade().librawGrade.tint == 0)
}

@Test func rampJSONCompatibility() throws {
  let flat = Data(#"{"keyframes":[{"frame":0,"exposure":2,"temperature":4200}]}"#.utf8)
  let nested = Data(#"{"keyframes":[{"frame":0,"grade":{"exposure":2,"temperature":4200}}]}"#.utf8)
  let decoder = JSONDecoder()
  let ramp = try decoder.decode(RampFile.self, from: flat)
  #expect(ramp.interpolation == "smooth")
  #expect(try decoder.decode(RampFile.self, from: nested) == ramp)
  let complete = RampFile(
    interpolation: "linear",
    keyframes: [
      Keyframe(
        frame: 42, exposure: 1, temperature: 4300, tint: 12, contrast: 1.2,
        saturation: 0.9, vibrance: 0.3, shadows: -0.2, highlights: 0.7)
    ])
  let data = try JSONEncoder().encode(complete)
  #expect(try decoder.decode(RampFile.self, from: data) == complete)
  let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  let keys = try #require(json["keyframes"] as? [[String: Any]])
  #expect(keys[0]["grade"] == nil)
  #expect(keys[0]["tint"] as? Double == 12)
}

@Test func gradeIdentityIncludesEveryControlAndCorrectionPreservesColor() {
  let base = Grade()
  let paths: [WritableKeyPath<Grade, Double>] = [
    \.exposure, \.contrast, \.saturation, \.vibrance, \.shadows, \.highlights,
  ]
  for path in paths {
    var changed = base
    changed[keyPath: path] += 0.001
    #expect(changed.previewIdentity != base.previewIdentity)
  }
  #expect(Grade(temperature: 0).previewIdentity != base.previewIdentity)
  #expect(Grade(tint: 0).previewIdentity != base.previewIdentity)
  let creative = Grade(
    exposure: 1, temperature: 4200, tint: 10, contrast: 1.2,
    saturation: 0.8, vibrance: 0.4, shadows: 0.2, highlights: 0.7)
  var expected = creative
  expected.exposure = 1.5
  #expect(creative.addingExposure(0.5) == expected)
}

@Test func uiAdapterUsesSameCompleteRamp() {
  let keys = [
    0: Grade(exposure: 1, temperature: 4000, tint: -10, vibrance: 0.2),
    100: Grade(exposure: 3, temperature: 6000, tint: 10, vibrance: 0.6),
  ]
  let ramp = RampFile(keyframes: keys.map { Keyframe(frame: $0.key, grade: $0.value) })
  for frame in -1...101 {
    #expect(ExposureWorkflow.grade(at: frame, keyframes: keys, frameCount: 101) == ramp.grade(at: frame))
  }
  #expect(ExposureWorkflow.grade(at: 0, keyframes: [:], frameCount: 1).temperature == 5200)
}

@Test func insertingUnchangedLinearAnchorPreservesRamp() {
  let original = RampFile(
    interpolation: "linear",
    keyframes: [
      Keyframe(frame: 0, exposure: 0, temperature: 4000, tint: 0, vibrance: 0),
      Keyframe(frame: 100, exposure: 4, temperature: 6000, tint: 20, vibrance: 1),
    ])
  var edited = original
  edited.keyframes.append(Keyframe(frame: 50, grade: original.grade(at: 50)))
  for frame in 0...100 {
    let a = original.grade(at: frame)
    let b = edited.grade(at: frame)
    #expect(abs(a.exposure - b.exposure) < 1e-12)
    #expect(abs(a.vibrance - b.vibrance) < 1e-12)
    #expect(abs(a.temperature! - b.temperature!) < 1e-9)
  }
}
