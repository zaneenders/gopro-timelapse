import Foundation
import Libraw

public struct RAWDevelopmentSettings: Equatable, Sendable {
  public var maximumWidth: Int
  public var denoise: Double

  public init(maximumWidth: Int = 0, denoise: Double = 0.7) {
    self.maximumWidth = maximumWidth
    self.denoise = denoise
  }
}

/// Shared GPR development. Each call owns its LibRaw instance; callers choose
/// explicit preview, analysis, or export settings rather than implicit presets.
public enum RAWDeveloper {
  public static func developRGB16(
    source: URL, grade: Grade, settings: RAWDevelopmentSettings
  ) throws -> LibrawRGB16Image {
    try developer(source: source, grade: grade, settings: settings).developRGB16()
  }

  public static func developRGB(
    source: URL, grade: Grade, settings: RAWDevelopmentSettings
  ) throws -> LibrawRGBImage {
    try developer(source: source, grade: grade, settings: settings).developRGB()
  }

  private static func developer(
    source: URL, grade: Grade, settings: RAWDevelopmentSettings
  ) throws -> Libraw {
    let dng = try DNGCache.dng(for: source)
    let developer = Libraw()
    try developer.open(dng.path)
    developer.setGrade(grade.librawGrade)
    developer.setDenoise(settings.denoise)
    developer.setMaxWidth(settings.maximumWidth)
    return developer
  }
}
