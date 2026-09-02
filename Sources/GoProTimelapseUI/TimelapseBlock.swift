import Chroma
import Foundation
import GprTools
import Libraw

@MainActor
public final class TimelapseUIState {
  public var sourcePath: String
  public var frames: [URL] = []
  public var selectedFrame = 0
  public var preview: ImageResource?
  public var status = "Choose a folder containing GPR or rendered photo frames."
  public var isLoading = false
  public let frameListController = ScrollViewController()

  private var loadGeneration: UInt64 = 0
  private var previewTask: Task<Void, Never>?

  public init(sourcePath: String = FileManager.default.currentDirectoryPath) {
    self.sourcePath = sourcePath
  }

  deinit {
    previewTask?.cancel()
  }

  public var selectedURL: URL? {
    frames.indices.contains(selectedFrame) ? frames[selectedFrame] : nil
  }

  public func loadSource() {
    let directory = URL(fileURLWithPath: sourcePath).standardizedFileURL
    loadGeneration &+= 1
    let generation = loadGeneration
    previewTask?.cancel()
    isLoading = true
    frames = []
    selectedFrame = 0
    preview = nil
    status = "Scanning \(directory.path)…"

    Task { [weak self] in
      let result = await Task.detached(priority: .userInitiated) {
        Self.scan(directory: directory)
      }.value
      guard !Task.isCancelled else { return }
      await MainActor.run {
        guard let self, self.loadGeneration == generation else { return }
        switch result {
        case .success(let frames, let isRAW):
          self.frames = frames
          self.selectedFrame = 0
          self.preview = nil
          if frames.isEmpty {
            self.isLoading = false
            self.status = "No GPR, JPEG, PNG, or TIFF frames found."
          } else {
            self.status = "Found \(frames.count) \(isRAW ? "GPR RAW" : "rendered") frames."
            self.startPreview(for: 0)
          }
        case .failure(let message):
          self.frames = []
          self.preview = nil
          self.isLoading = false
          self.status = message
        }
      }
    }
  }

  public func selectFrame(_ index: Int) {
    guard frames.indices.contains(index), index != selectedFrame else { return }
    selectedFrame = index

    // Selection is immediate, but LibRaw/GPR conversion is not cooperatively
    // cancellable. Keep one conversion in flight and load the latest selection
    // as soon as it finishes instead of starting an unbounded queue of work.
    if isLoading {
      status = "Waiting to preview \(frames[index].lastPathComponent)…"
    } else {
      startPreview(for: index)
    }
  }

  private func startPreview(for index: Int) {
    guard frames.indices.contains(index) else { return }
    previewTask?.cancel()
    loadGeneration &+= 1
    let generation = loadGeneration
    let source = frames[index]
    isLoading = true
    status = "Loading \(source.lastPathComponent)…"

    previewTask = Task { [weak self] in
      let result = await Task.detached(priority: .userInitiated) {
        do {
          return PreviewResult.success(try Self.renderPreview(source: source))
        } catch {
          return PreviewResult.failure(String(describing: error))
        }
      }.value
      guard !Task.isCancelled else { return }
      await MainActor.run {
        guard let self, self.loadGeneration == generation else { return }
        self.isLoading = false
        if self.selectedFrame != index {
          self.startPreview(for: self.selectedFrame)
          return
        }
        switch result {
        case .success(let image):
          self.preview = image
          self.status = "Frame \(index + 1) of \(self.frames.count) — \(source.lastPathComponent)"
        case .failure(let message):
          self.preview = nil
          self.status = "Preview failed for \(source.lastPathComponent): \(message)"
        }
      }
    }
  }

  nonisolated private static func scan(directory: URL) -> ScanResult {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      return .failure("Folder does not exist: \(directory.path)")
    }
    do {
      let contents = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles])
      let gprs = sortedFrames(contents, extensions: ["gpr"])
      let rendered = sortedFrames(
        contents, extensions: ["jpg", "jpeg", "png", "tif", "tiff"])
      return .success(frames: gprs.isEmpty ? rendered : gprs, isRAW: !gprs.isEmpty)
    } catch {
      return .failure("Unable to scan folder: \(error)")
    }
  }

  nonisolated private static func sortedFrames(_ urls: [URL], extensions: Set<String>) -> [URL] {
    urls
      .filter { extensions.contains($0.pathExtension.lowercased()) }
      .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
  }

  nonisolated private static func renderPreview(source: URL) throws -> ImageResource {
    guard source.pathExtension.lowercased() == "gpr" else {
      throw PreviewError.renderedImageDecodingUnavailable
    }

    let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "gopro-timelapse-preview-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let dng = temporaryDirectory.appendingPathComponent("preview.dng")
    try GprTools.convert(gprFile: source.path, toDNG: dng.path)
    let developer = Libraw()
    try developer.open(dng.path)
    developer.setDenoise(0.4)
    developer.setMaxWidth(1280)
    let rgb = try developer.developRGB()

    let pixelCount = rgb.width * rgb.height
    guard rgb.pixels.count == pixelCount * 3 else { throw PreviewError.invalidRGBData }
    var rgba = Data(count: pixelCount * 4)
    rgba.withUnsafeMutableBytes { destination in
      rgb.pixels.withUnsafeBytes { source in
        guard
          let output = destination.bindMemory(to: UInt8.self).baseAddress,
          let input = source.bindMemory(to: UInt8.self).baseAddress
        else { return }
        for pixel in 0..<pixelCount {
          output[pixel * 4] = input[pixel * 3]
          output[pixel * 4 + 1] = input[pixel * 3 + 1]
          output[pixel * 4 + 2] = input[pixel * 3 + 2]
          output[pixel * 4 + 3] = 255
        }
      }
    }
    return try ImageResource(
      id: ImageID(source.path),
      width: rgb.width,
      height: rgb.height,
      rgba8: rgba)
  }
}

private enum ScanResult: Sendable {
  case success(frames: [URL], isRAW: Bool)
  case failure(String)
}

private enum PreviewResult: Sendable {
  case success(ImageResource)
  case failure(String)
}

private enum PreviewError: Error, CustomStringConvertible {
  case invalidRGBData
  case renderedImageDecodingUnavailable

  var description: String {
    switch self {
    case .invalidRGBData:
      "LibRaw returned an unexpected RGB buffer."
    case .renderedImageDecodingUnavailable:
      "Rendered-photo preview decoding is not implemented yet; GPR preview works."
    }
  }
}

@MainActor
public struct TimelapseBlock: Block {
  public let state: TimelapseUIState

  public init(state: TimelapseUIState) {
    self.state = state
  }

  public var body: some Block {
    ThemeReader { theme in
      VStack(spacing: 0) {
        header(theme: theme)
        HStack(spacing: 0) {
          sidebar(theme: theme)
            .sizing(x: .fixed(260), y: .grow)
            .background(theme.surface)
          previewPane(theme: theme)
            .sizing(x: .grow, y: .grow)
            .background(theme.background)
        }
        .sizing(x: .grow, y: .grow)
        footer(theme: theme)
      }
      .background(theme.background)
    }
  }

  private func header(theme: ChromaTheme) -> some Block {
    HStack(spacing: 10) {
      Text("GOPRO TIMELAPSE")
        .fontScale(0.8)
        .foregroundColor(theme.accent)
      TextField(
        "Source folder",
        id: WidgetID("source.path"),
        fontScale: 0.65,
        text: { state.sourcePath },
        onChange: { state.sourcePath = $0 },
        onSubmit: { _ in state.loadSource() })
        .sizing(x: .grow)
      Button("Load", id: WidgetID("source.load"), fontScale: 0.65) {
        state.loadSource()
      }
    }
    .padding(12)
    .background(theme.elevatedSurface)
    .border(theme.border)
  }

  private func sidebar(theme: ChromaTheme) -> some Block {
    VStack(spacing: 8) {
      HStack {
        Text("FRAMES")
          .fontScale(0.6)
          .foregroundColor(theme.secondaryForeground)
        Spacer()
        Text("\(state.frames.count)")
          .fontScale(0.6)
          .foregroundColor(theme.secondaryForeground)
      }
      if state.frames.isEmpty {
        Text("Load a source folder to begin.")
          .fontScale(0.6)
          .foregroundColor(theme.secondaryForeground)
      } else {
        LazyVStack(
          id: WidgetID("frames.list"),
          spacing: 4,
          controller: state.frameListController,
          rows: state.frames.enumerated().map { index, frame in
            LazyVStack.Row(
              id: WidgetID("frame.\(index)"),
              content: frameRow(index: index, frame: frame, theme: theme))
          })
          .sizing(x: .grow, y: .grow)
      }
    }
    .padding(10)
  }

  private func frameRow(index: Int, frame: URL, theme: ChromaTheme) -> some Block {
    let selected = index == state.selectedFrame
    return Interactive(id: WidgetID("frame.select.\(index)")) {
      state.selectFrame(index)
    } content: { phase in
      HStack(spacing: 8) {
        Text(String(format: "%05d", index + 1))
          .fontScale(0.58)
          .foregroundColor(selected ? theme.accent : theme.secondaryForeground)
        Text(frame.lastPathComponent)
          .fontScale(0.58)
          .foregroundColor(theme.foreground)
      }
      .padding(8)
      .sizing(x: .grow)
      .roundedBackground(
        selected
          ? Color(r: theme.accent.r, g: theme.accent.g, b: theme.accent.b, a: 0.18)
          : phase == .hovered ? theme.elevatedSurface : theme.surface,
        radius: 5)
      .roundedBorder(selected ? theme.accent : theme.border, radius: 5)
    }
  }

  private func previewPane(theme: ChromaTheme) -> some Block {
    VStack(spacing: 12) {
      HStack {
        Text(state.selectedURL?.lastPathComponent ?? "PREVIEW")
          .fontScale(0.65)
          .foregroundColor(theme.foreground)
        Spacer()
        if state.isLoading {
          Text("Loading…")
            .fontScale(0.6)
            .foregroundColor(theme.warning)
        }
      }
      if let preview = state.preview {
        Image(preview, scaling: .contain)
          .sizing(x: .grow, y: .grow)
          .clipped()
          .background(Color.black)
      } else {
        ZStack {
          Color.black
          Text(state.frames.isEmpty ? "No frame selected" : "Preview unavailable")
            .fontScale(0.7)
            .foregroundColor(theme.secondaryForeground)
        }
        .sizing(x: .grow, y: .grow)
        .clipped()
      }
      HStack(spacing: 8) {
        Button("Analyze", id: WidgetID("action.analyze"), fontScale: 0.62) {
          state.status = "Analysis is the next UI milestone."
        }
        Button("Auto Correct", id: WidgetID("action.correct"), fontScale: 0.62) {
          state.status = "Automatic correction is not implemented yet."
        }
        Button("Render", id: WidgetID("action.render"), fontScale: 0.62) {
          state.status = "Rendering from the UI is not implemented yet; use the CLI."
        }
        Spacer()
      }
    }
    .padding(14)
  }

  private func footer(theme: ChromaTheme) -> some Block {
    HStack {
      Text(state.status)
        .fontScale(0.58)
        .foregroundColor(theme.secondaryForeground)
      Spacer()
    }
    .padding(10)
    .background(theme.elevatedSurface)
    .border(theme.border)
  }
}
