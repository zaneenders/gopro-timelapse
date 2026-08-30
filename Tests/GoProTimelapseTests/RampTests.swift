import Testing

@testable import GoProTimelapse

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
