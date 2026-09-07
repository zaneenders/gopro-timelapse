import Foundation

public struct Grade: Codable, Hashable, Sendable {
  public var exposure: Double = 0
  public var temperature: Double? = nil
  public var tint: Double? = nil
  public var contrast: Double = 1
  public var saturation: Double = 1
  public var vibrance: Double = 0
  public var shadows: Double = 0
  public var highlights: Double = 0
  public init(
    exposure: Double = 0,
    temperature: Double? = nil,
    tint: Double? = nil,
    contrast: Double = 1,
    saturation: Double = 1,
    vibrance: Double = 0,
    shadows: Double = 0,
    highlights: Double = 0
  ) {
    self.exposure = exposure
    self.temperature = temperature
    self.tint = tint
    self.contrast = contrast
    self.saturation = saturation
    self.vibrance = vibrance
    self.shadows = shadows
    self.highlights = highlights
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    exposure = try c.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
    temperature = try c.decodeIfPresent(Double.self, forKey: .temperature)
    tint = try c.decodeIfPresent(Double.self, forKey: .tint)
    contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 1
    saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? 1
    vibrance = try c.decodeIfPresent(Double.self, forKey: .vibrance) ?? 0
    shadows = try c.decodeIfPresent(Double.self, forKey: .shadows) ?? 0
    highlights = try c.decodeIfPresent(Double.self, forKey: .highlights) ?? 0
  }

  /// Adds deflicker without changing the creative color grade.
  public func addingExposure(_ correction: Double) -> Grade {
    var result = self
    result.exposure += correction
    return result
  }
}

public struct Keyframe: Codable, Equatable, Sendable {
  public var frame: Int
  public var grade: Grade

  public init(
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

  public init(frame: Int, grade: Grade) {
    self.frame = frame
    self.grade = grade
  }

  enum CodingKeys: String, CodingKey {
    case frame, grade, exposure, temperature, tint, contrast, saturation, vibrance, shadows, highlights
  }

  public init(from decoder: Decoder) throws {
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

  public func encode(to encoder: Encoder) throws {
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

public struct RampFile: Codable, Equatable, Sendable {
  public var interpolation: String = "smooth"
  public var keyframes: [Keyframe]

  public init(interpolation: String = "smooth", keyframes: [Keyframe]) {
    self.interpolation = interpolation
    self.keyframes = keyframes
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    interpolation = try c.decodeIfPresent(String.self, forKey: .interpolation) ?? "smooth"
    keyframes = try c.decode([Keyframe].self, forKey: .keyframes)
  }

  public func grade(at frame: Int) -> Grade {
    interpolatedGrade(frame: frame, ramp: self)
  }
}

public func interpolatedGrade(frame: Int, ramp: RampFile) -> Grade {
  // Resolve duplicates deterministically: the last entry in the file wins.
  var byFrame: [Int: Grade] = [:]
  for key in ramp.keyframes { byFrame[key.frame] = key.grade }
  let keys = byFrame.map { Keyframe(frame: $0.key, grade: $0.value) }
    .sorted { $0.frame < $1.frame }
  // Exact anchors retain nil white balance, rather than borrowing a neighbor's.
  if let exact = byFrame[frame] { return exact }
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
