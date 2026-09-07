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
    let image = try renderRGB16(
      source: source, grade: grade, temporaryDirectory: temporaryDirectory)
    try Self.writePPM16(image, to: destination)
  }

  /// P6 PPM stores 16-bit samples in network (big-endian) byte order.
  /// Keep all sample bits; PNG development in the LibRaw bridge is only 8-bit.
  static func writePPM16(_ image: LibrawRGB16Image, to destination: URL) throws {
    guard image.width > 0, image.height > 0,
      image.pixels.count.isMultiple(of: 6),
      image.pixels.count / 6 / image.width == image.height,
      image.pixels.count / 6 % image.width == 0
    else { throw CLIError.message("Invalid RGB16 frame dimensions or byte count") }

    var pixels = image.pixels
    pixels.withUnsafeMutableBytes { bytes in
      let samples = bytes.bindMemory(to: UInt8.self)
      for offset in stride(from: 0, to: samples.count, by: 2) {
        let low = samples[offset]
        samples[offset] = samples[offset + 1]
        samples[offset + 1] = low
      }
    }
    var data = Data("P6\n\(image.width) \(image.height)\n65535\n".utf8)
    data.append(pixels)
    try data.write(to: destination, options: .atomic)
  }

  func renderRGB16(source: URL, grade: Grade, temporaryDirectory: URL) throws -> LibrawRGB16Image {
    let dev = try developer(source: source, grade: grade, temporaryDirectory: temporaryDirectory)
    return try dev.developRGB16()
  }
}
