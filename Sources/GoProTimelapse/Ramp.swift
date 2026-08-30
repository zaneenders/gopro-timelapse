import Foundation

struct Grade: Codable, Equatable, Sendable {
  var exposure: Double = 0
  var temperature: Double? = nil
  var tint: Double? = nil
  var contrast: Double = 1
  var saturation: Double = 1
  var vibrance: Double = 0
  var shadows: Double = 0
  var highlights: Double = 0
}

struct Keyframe: Codable, Equatable {
  var frame: Int
  var grade: Grade

  init(
    frame: Int, exposure: Double = 0, temperature: Double? = nil, tint: Double? = nil,
    contrast: Double = 1, saturation: Double = 1, vibrance: Double = 0,
    shadows: Double = 0, highlights: Double = 0
  ) {
    self.frame = frame
    self.grade = Grade(
      exposure: exposure, temperature: temperature, tint: tint,
      contrast: contrast, saturation: saturation, vibrance: vibrance,
      shadows: shadows, highlights: highlights)
  }

  enum CodingKeys: String, CodingKey {
    case frame, grade, exposure, temperature, tint, contrast, saturation, vibrance, shadows, highlights
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    frame = try c.decode(Int.self, forKey: .frame)
    if let nested = try c.decodeIfPresent(Grade.self, forKey: .grade) {
      grade = nested
    } else {
      grade = Grade(
        exposure: try c.decodeIfPresent(Double.self, forKey: .exposure) ?? 0,
        temperature: try c.decodeIfPresent(Double.self, forKey: .temperature),
        tint: try c.decodeIfPresent(Double.self, forKey: .tint),
        contrast: try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 1,
        saturation: try c.decodeIfPresent(Double.self, forKey: .saturation) ?? 1,
        vibrance: try c.decodeIfPresent(Double.self, forKey: .vibrance) ?? 0,
        shadows: try c.decodeIfPresent(Double.self, forKey: .shadows) ?? 0,
        highlights: try c.decodeIfPresent(Double.self, forKey: .highlights) ?? 0
      )
    }
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(frame, forKey: .frame)
    try c.encode(grade.exposure, forKey: .exposure)
    try c.encodeIfPresent(grade.temperature, forKey: .temperature)
    try c.encodeIfPresent(grade.tint, forKey: .tint)
    try c.encode(grade.contrast, forKey: .contrast)
    try c.encode(grade.saturation, forKey: .saturation)
    try c.encode(grade.vibrance, forKey: .vibrance)
    try c.encode(grade.shadows, forKey: .shadows)
    try c.encode(grade.highlights, forKey: .highlights)
  }
}

struct RampFile: Codable {
  var interpolation: String = "smooth"
  var keyframes: [Keyframe]
}

func interpolatedGrade(frame: Int, ramp: RampFile) -> Grade {
  let keys = ramp.keyframes.sorted { $0.frame < $1.frame }
  guard let first = keys.first else { return Grade() }
  guard frame > first.frame else { return first.grade }
  guard let last = keys.last, frame < last.frame else { return keys.last!.grade }
  let upperIndex = keys.firstIndex { $0.frame >= frame }!
  let a = keys[upperIndex - 1]
  let b = keys[upperIndex]
  var t = Double(frame - a.frame) / Double(b.frame - a.frame)
  if ramp.interpolation.lowercased() == "smooth" { t = t * t * (3 - 2 * t) }
  func mix(_ x: Double, _ y: Double) -> Double { x + (y - x) * t }
  func mixOptional(_ x: Double?, _ y: Double?) -> Double? {
    switch (x, y) {
    case (.some(let x), .some(let y)): return mix(x, y)
    case (.some(let x), nil): return x
    case (nil, .some(let y)): return y
    default: return nil
    }
  }
  return Grade(
    exposure: mix(a.grade.exposure, b.grade.exposure),
    temperature: mixOptional(a.grade.temperature, b.grade.temperature),
    tint: mixOptional(a.grade.tint, b.grade.tint),
    contrast: mix(a.grade.contrast, b.grade.contrast),
    saturation: mix(a.grade.saturation, b.grade.saturation),
    vibrance: mix(a.grade.vibrance, b.grade.vibrance),
    shadows: mix(a.grade.shadows, b.grade.shadows),
    highlights: mix(a.grade.highlights, b.grade.highlights))
}
