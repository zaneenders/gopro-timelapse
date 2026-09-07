import Foundation
import GoProTimelapseCore
import Libraw

struct RAWRenderer: Sendable {
  let width: Int
  let denoise: Double

  private func developer(source: URL, grade: Grade, temporaryDirectory _: URL) throws -> Libraw {
    let dng = try DNGCache.dng(for: source)
    do {
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
      return dev
    } catch {
      throw error
    }
  }

  func render(source: URL, destination: URL, grade: Grade, temporaryDirectory: URL) throws {
    let dev = try developer(source: source, grade: grade, temporaryDirectory: temporaryDirectory)
    try dev.developPNG(to: destination.path)
  }

  func renderRGB16(source: URL, grade: Grade, temporaryDirectory: URL) throws -> LibrawRGB16Image {
    let dev = try developer(source: source, grade: grade, temporaryDirectory: temporaryDirectory)
    return try dev.developRGB16()
  }
}
