import Foundation
import GoProTimelapseCore
import Libraw

struct RAWRenderer: Sendable {
  let width: Int
  let denoise: Double

  private func developer(source: URL, grade: Grade, temporaryDirectory _: URL) throws -> Libraw {
    let dng = try DNGCache.dng(for: source)
    let dev = Libraw()
    try dev.open(dng.path)
    dev.setGrade(grade.librawGrade)
    dev.setDenoise(denoise)
    dev.setMaxWidth(width)
    return dev
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
