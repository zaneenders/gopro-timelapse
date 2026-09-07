import Foundation

public struct AutomaticCorrectionFile: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var frameCount: Int
  public var baseline: [Double]
  public var correction: [Double]
  public var settings: Settings

  public struct Settings: Codable, Equatable, Sendable {
    public var baselineWindowFraction: Double
    public var correctionSmoothingFraction: Double
    public var maximumCorrection: Double
    public var maximumDeltaPerFrame: Double

    public init(_ settings: AutomaticCorrectionSettings) {
      baselineWindowFraction = settings.baselineWindowFraction
      correctionSmoothingFraction = settings.correctionSmoothingFraction
      maximumCorrection = settings.maximumCorrection
      maximumDeltaPerFrame = settings.maximumDeltaPerFrame
    }
  }

  public init(
    baseline: [Double],
    correction: [Double],
    settings: AutomaticCorrectionSettings = AutomaticCorrectionSettings()
  ) {
    schemaVersion = 1
    frameCount = correction.count
    self.baseline = baseline
    self.correction = correction
    self.settings = Settings(settings)
  }

  public static func load(from url: URL, expectedFrameCount: Int) throws -> Self {
    let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    guard value.schemaVersion == 1 else {
      throw AutomaticCorrectionFileError.unsupportedSchema(value.schemaVersion)
    }
    guard value.frameCount == expectedFrameCount,
      value.correction.count == expectedFrameCount,
      value.baseline.count == expectedFrameCount
    else {
      throw AutomaticCorrectionFileError.frameCount(
        expected: expectedFrameCount, actual: value.correction.count)
    }
    guard value.correction.allSatisfy(\.isFinite), value.baseline.allSatisfy(\.isFinite) else {
      throw AutomaticCorrectionFileError.nonFiniteValue
    }
    return value
  }

  public func write(to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(self).write(to: url, options: .atomic)
  }
}

public enum AutomaticCorrectionFileError: Error, CustomStringConvertible {
  case unsupportedSchema(Int)
  case frameCount(expected: Int, actual: Int)
  case nonFiniteValue

  public var description: String {
    switch self {
    case .unsupportedSchema(let version):
      "Unsupported automatic-correction schema version: \(version)"
    case .frameCount(let expected, let actual):
      "Automatic correction has \(actual) frames; sequence has \(expected)"
    case .nonFiniteValue:
      "Automatic correction contains a non-finite value"
    }
  }
}
