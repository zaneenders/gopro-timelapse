import Foundation
import GprTools
import Libraw

struct RAWRenderer: Sendable {
  let width: Int
  let denoise: Double

  private func developer(source: URL, grade: Grade, temporaryDirectory: URL) throws -> (Libraw, URL) {
    let dng = temporaryDirectory.appendingPathComponent(
      source.deletingPathExtension().lastPathComponent + ".dng")
    do {
      try GprTools.convert(gprFile: source.path, toDNG: dng.path)

      let dev = Libraw()
      try dev.open(dng.path)
      dev.setGrade(
        .init(
          exposure: grade.exposure,
          temperature: grade.temperature ?? 0,
          tint: grade.tint ?? 0,
          contrast: grade.contrast,
          saturation: grade.saturation,
          vibrance: grade.vibrance,
          shadows: grade.shadows,
          highlights: grade.highlights
        ))
      dev.setDenoise(denoise)
      dev.setMaxWidth(width)
      return (dev, dng)
    } catch {
      try? FileManager.default.removeItem(at: dng)
      throw error
    }
  }

  func render(source: URL, destination: URL, grade: Grade, temporaryDirectory: URL) throws {
    let (dev, dng) = try developer(source: source, grade: grade, temporaryDirectory: temporaryDirectory)
    defer { try? FileManager.default.removeItem(at: dng) }
    try dev.developPNG(to: destination.path)
  }

  func renderRGB(source: URL, grade: Grade, temporaryDirectory: URL) throws -> LibrawRGBImage {
    let (dev, dng) = try developer(source: source, grade: grade, temporaryDirectory: temporaryDirectory)
    defer { try? FileManager.default.removeItem(at: dng) }
    return try dev.developRGB()
  }
}
