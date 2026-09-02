import Foundation
import Testing

@testable import GoProTimelapseUI

@Test @MainActor func pairedJPEGPreviewLoadsAndCaches() async throws {
  let sourceDirectory = URL(fileURLWithPath: "/Users/zane/Movies/26-09-01/tl", isDirectory: true)
  guard FileManager.default.fileExists(atPath: sourceDirectory.path) else { return }

  let state = TimelapseUIState(sourcePath: sourceDirectory.path)
  state.loadSource()
  for _ in 0..<200 {
    if !state.isLoading, state.preview != nil { break }
    try await Task.sleep(for: .milliseconds(25))
  }

  #expect(!state.frames.isEmpty)
  #expect(state.preview != nil)
  #expect(state.previewLabel == "JPEG proxy")
  if let preview = state.preview {
    #expect(preview.width <= 1280)
    #expect(preview.rgba8.count == preview.width * preview.height * 4)
  }
}
