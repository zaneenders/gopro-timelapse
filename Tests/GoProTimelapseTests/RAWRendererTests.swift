import Foundation
import Libraw
import Testing

@testable import GoProTimelapse

@Test func retainedFramesPreserve16BitSamples() throws {
  let destination = FileManager.default.temporaryDirectory
    .appendingPathComponent("frame-\(UUID().uuidString).ppm")
  defer { try? FileManager.default.removeItem(at: destination) }
  // Include low-order bits that would be discarded by an 8-bit intermediate.
  let pixels = Data([0x01, 0x00, 0x34, 0x12, 0xff, 0xff, 0x00, 0x00, 0xff, 0x00, 0x01, 0x80])
  let image = LibrawRGB16Image(width: 2, height: 1, pixels: pixels)
  try RAWRenderer.writePPM16(image, to: destination)

  var expected = Data("P6\n2 1\n65535\n".utf8)
  expected.append(contentsOf: [0x00, 0x01, 0x12, 0x34, 0xff, 0xff, 0x00, 0x00, 0x00, 0xff, 0x80, 0x01])
  #expect(try Data(contentsOf: destination) == expected)
  #expect(image.pixels == pixels)
}

@Test func retainedFramesRejectInvalidDimensionsAndBuffers() {
  let destination = FileManager.default.temporaryDirectory
    .appendingPathComponent("invalid-frame-\(UUID().uuidString).ppm")
  defer { try? FileManager.default.removeItem(at: destination) }
  for image in [
    LibrawRGB16Image(width: 0, height: 1, pixels: Data()),
    LibrawRGB16Image(width: 1, height: 1, pixels: Data(repeating: 0, count: 5)),
    LibrawRGB16Image(width: 2, height: 1, pixels: Data(repeating: 0, count: 6)),
  ] {
    #expect(throws: Error.self) { try RAWRenderer.writePPM16(image, to: destination) }
  }
  #expect(!FileManager.default.fileExists(atPath: destination.path))
}
