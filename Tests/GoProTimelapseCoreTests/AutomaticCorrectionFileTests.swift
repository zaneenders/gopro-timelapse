import Foundation
import Testing

@testable import GoProTimelapseCore

@Test func automaticCorrectionFileRoundTripsAndValidatesFrameCount() throws {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(
    "correction-\(UUID().uuidString).json")
  defer { try? FileManager.default.removeItem(at: url) }
  let value = AutomaticCorrectionFile(
    baseline: [-2, -1.9, -1.8], correction: [0.1, -0.1, 0])
  try value.write(to: url)

  let loaded = try AutomaticCorrectionFile.load(from: url, expectedFrameCount: 3)
  #expect(loaded == value)
  #expect(throws: AutomaticCorrectionFileError.self) {
    try AutomaticCorrectionFile.load(from: url, expectedFrameCount: 2)
  }
}
