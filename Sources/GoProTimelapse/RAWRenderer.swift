import Foundation
import GoProTimelapseCore
import Libraw

struct RAWRenderer: Sendable {
  let width: Int
  let denoise: Double

  func render(source: URL, destination: URL, grade: Grade) throws {
    let image = try renderRGB16(
      source: source, grade: grade)
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

  func renderRGB16(source: URL, grade: Grade) throws -> LibrawRGB16Image {
    try RAWDeveloper.developRGB16(
      source: source, grade: grade,
      settings: .init(maximumWidth: width, denoise: denoise))
  }
}
