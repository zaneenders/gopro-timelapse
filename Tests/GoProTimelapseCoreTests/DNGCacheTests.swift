import Foundation
import Testing

@testable import GoProTimelapseCore

@Test func dngCacheRejectsMissingSource() {
  let source = FileManager.default.temporaryDirectory
    .appendingPathComponent("missing-\(UUID().uuidString).gpr")
  #expect(throws: Error.self) {
    try DNGCache.dng(for: source)
  }
}

@Test func dngCacheRecoversCompletedDNGAfterRestart() throws {
  let fileManager = FileManager.default
  let directory = fileManager.temporaryDirectory.appendingPathComponent(
    "dng-cache-restart-\(UUID().uuidString)", isDirectory: true)
  try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? fileManager.removeItem(at: directory) }

  let source = directory.appendingPathComponent("frame.gpr")
  try Data("source".utf8).write(to: source)
  let sourceDate = Date(timeIntervalSince1970: 1_700_000_000)
  try fileManager.setAttributes([.modificationDate: sourceDate], ofItemAtPath: source.path)

  let cacheDirectory = directory.appendingPathComponent(".gopro-timelapse/dng")
  try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
  let completedDNG = cacheDirectory.appendingPathComponent("frame.dng")
  let expectedData = Data("completed dng".utf8)
  try expectedData.write(to: completedDNG)
  try fileManager.setAttributes(
    [.modificationDate: sourceDate.addingTimeInterval(1)], ofItemAtPath: completedDNG.path)

  let result = try DNGCache.dng(for: source)

  #expect(result == completedDNG)
  #expect(try Data(contentsOf: result) == expectedData)
  #expect(fileManager.fileExists(atPath: cacheDirectory.appendingPathComponent("frame.dng.json").path))
}
