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
  public var previewLabel: String?
  public var status = "Choose a folder containing GPR or rendered photo frames."
  public var isLoading = false
  public let frameListController = ScrollViewController()

  private var loadGeneration: UInt64 = 0
  private var previewTask: Task<Void, Never>?
  private var prefetchTask: Task<Void, Never>?
  private var previewSources: [URL: URL] = [:]
  private var previewCache: [URL: CachedPreview] = [:]
  private var previewCacheTick: UInt64 = 0
  private let maximumPreviewCacheCount = 24
  private let maximumPreviewCacheBytes = 160 * 1024 * 1024

  public init(sourcePath: String = FileManager.default.currentDirectoryPath) {
    self.sourcePath = sourcePath
  }

  deinit {
    previewTask?.cancel()
    prefetchTask?.cancel()
  }

  public var selectedURL: URL? {
    frames.indices.contains(selectedFrame) ? frames[selectedFrame] : nil
  }

  public func loadSource() {
    let directory = URL(fileURLWithPath: sourcePath).standardizedFileURL
    loadGeneration &+= 1
    let generation = loadGeneration
    previewTask?.cancel()
    prefetchTask?.cancel()
    prefetchTask = nil
    isLoading = true
    frames = []
    selectedFrame = 0
    preview = nil
    previewLabel = nil
    previewSources = [:]
    previewCache = [:]
    previewCacheTick = 0
    status = "Scanning \(directory.path)…"

    Task { [weak self] in
      let result = await Task.detached(priority: .userInitiated) {
        Self.scan(directory: directory)
      }.value
      guard !Task.isCancelled else { return }
      await MainActor.run {
        guard let self, self.loadGeneration == generation else { return }
        switch result {
        case .success(let frames, let previewSources, let isRAW):
          self.frames = frames
          self.previewSources = previewSources
          self.selectedFrame = 0
          self.preview = nil
          self.previewLabel = nil
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
          self.previewLabel = nil
          self.previewSources = [:]
          self.isLoading = false
          self.status = message
        }
      }
    }
  }

  public func selectFrame(_ index: Int) {
    guard frames.indices.contains(index), index != selectedFrame else { return }
    selectedFrame = index
    frameListController.scroll(to: max(0, Float(index - 2) * 52))
    if let cached = cachedPreview(for: frames[index]) {
      preview = cached.image
      previewLabel = cached.kind.label
      status = "Frame \(index + 1) of \(frames.count) — \(frames[index].lastPathComponent)"
      prefetchNeighbors(around: index)
      return
    }

    // Selection is immediate, but LibRaw/GPR conversion is not cooperatively
    // cancellable. Keep one conversion in flight and load the latest selection
    // as soon as it finishes instead of starting an unbounded queue of work.
    if isLoading {
      status = "Waiting to preview \(frames[index].lastPathComponent)…"
    } else {
      startPreview(for: index)
    }
  }

  public func moveSelection(by delta: Int) -> CommandResult {
    guard !frames.isEmpty else { return .ignored }
    let next = min(max(0, selectedFrame + delta), frames.count - 1)
    guard next != selectedFrame else { return .handled }
    selectFrame(next)
    return .handled
  }

  public func selectFirstFrame() -> CommandResult {
    guard !frames.isEmpty else { return .ignored }
    selectFrame(0)
    return .handled
  }

  public func selectLastFrame() -> CommandResult {
    guard !frames.isEmpty else { return .ignored }
    selectFrame(frames.count - 1)
    return .handled
  }

  private func startPreview(for index: Int) {
    guard frames.indices.contains(index) else { return }
    previewTask?.cancel()
    loadGeneration &+= 1
    let generation = loadGeneration
    let source = frames[index]
    let previewSource = previewSources[source] ?? source
    let previewKind: PreviewKind = previewSource == source && source.pathExtension.lowercased() == "gpr"
      ? .rawDeveloped : .renderedProxy
    isLoading = true
    status = "Loading \(previewSource.lastPathComponent)…"

    previewTask = Task { [weak self] in
      let result = await Task.detached(priority: .userInitiated) {
        do {
          return PreviewResult.success(
            try Self.renderPreview(source: previewSource), kind: previewKind)
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
        case .success(let image, let kind):
          self.storePreview(image, kind: kind, for: source)
          self.preview = image
          self.previewLabel = kind.label
          self.status = "Frame \(index + 1) of \(self.frames.count) — \(source.lastPathComponent)"
          self.prefetchNeighbors(around: index)
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
      guard !gprs.isEmpty else {
        return .success(
          frames: rendered,
          previewSources: Dictionary(uniqueKeysWithValues: rendered.map { ($0, $0) }),
          isRAW: false)
      }
      let renderedByStem = Dictionary(
        rendered.map { ($0.deletingPathExtension().lastPathComponent.lowercased(), $0) },
        uniquingKeysWith: { first, _ in first })
      let previewSources = Dictionary(
        uniqueKeysWithValues: gprs.map { raw in
          let stem = raw.deletingPathExtension().lastPathComponent.lowercased()
          return (raw, renderedByStem[stem] ?? raw)
        })
      return .success(frames: gprs, previewSources: previewSources, isRAW: true)
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
      return try decodeRenderedPreview(source: source)
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

  nonisolated private static func decodeRenderedPreview(source: URL) throws -> ImageResource {
    let process = Process()
    process.executableURL = try ffmpegURL()
    process.arguments = [
      "-v", "error", "-i", source.path,
      "-vf", "scale='min(1280,iw)':-2",
      "-frames:v", "1", "-f", "image2pipe", "-vcodec", "pam", "-pix_fmt", "rgba", "-",
    ]
    process.standardInput = FileHandle.nullDevice
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe
    try process.run()
    let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      let detail = String(
        data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
      throw PreviewError.ffmpegFailed(detail.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // PAM carries dimensions in a short ASCII header followed by tightly packed
    // RGBA bytes, allowing one ffmpeg process without a platform image decoder.
    let marker = Data("ENDHDR\n".utf8)
    guard let markerRange = data.range(of: marker),
      let header = String(data: data[..<markerRange.upperBound], encoding: .utf8)
    else { throw PreviewError.invalidPAM }
    var width: Int?
    var height: Int?
    for line in header.split(separator: "\n") {
      let fields = line.split(separator: " ", maxSplits: 1)
      guard fields.count == 2 else { continue }
      if fields[0] == "WIDTH" { width = Int(fields[1]) }
      if fields[0] == "HEIGHT" { height = Int(fields[1]) }
    }
    guard let width, let height else { throw PreviewError.invalidPAM }
    let pixels = Data(data[markerRange.upperBound...])
    return try ImageResource(
      id: ImageID(source.path), width: width, height: height, rgba8: pixels)
  }

  nonisolated private static func ffmpegURL() throws -> URL {
    var directories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
      .split(separator: ":").map(String.init)
    #if os(macOS)
    // GUI apps launched from Finder inherit a minimal PATH without Homebrew.
    directories += ["/opt/homebrew/bin", "/usr/local/bin"]
    #endif
    for directory in directories {
      let candidate = URL(fileURLWithPath: directory).appendingPathComponent("ffmpeg")
      if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
    }
    throw PreviewError.ffmpegNotFound
  }

  private func prefetchNeighbors(around index: Int) {
    guard prefetchTask == nil else { return }
    let candidates = [index - 1, index + 1].compactMap { neighbor -> (URL, URL)? in
      guard frames.indices.contains(neighbor) else { return nil }
      let frame = frames[neighbor]
      guard previewCache[frame] == nil, let source = previewSources[frame], source != frame else {
        return nil
      }
      return (frame, source)
    }
    guard !candidates.isEmpty else { return }

    // Keep prefetch bounded to one task. It decodes the two adjacent proxies
    // serially, then starts another pass around the latest selection.
    prefetchTask = Task { [weak self] in
      for (frame, source) in candidates {
        guard !Task.isCancelled else { return }
        let result = await Task.detached(priority: .utility) {
          do { return PreviewResult.success(try Self.renderPreview(source: source), kind: .renderedProxy) }
          catch { return PreviewResult.failure(String(describing: error)) }
        }.value
        guard !Task.isCancelled else { return }
        await MainActor.run {
          guard let self else { return }
          if case .success(let image, let kind) = result {
            self.storePreview(image, kind: kind, for: frame)
          }
        }
      }
      await MainActor.run {
        guard let self else { return }
        self.prefetchTask = nil
        self.prefetchNeighbors(around: self.selectedFrame)
      }
    }
  }

  private func cachedPreview(for source: URL) -> CachedPreview? {
    guard var cached = previewCache[source] else { return nil }
    previewCacheTick &+= 1
    cached.lastUsed = previewCacheTick
    previewCache[source] = cached
    return cached
  }

  private func storePreview(_ image: ImageResource, kind: PreviewKind, for source: URL) {
    previewCacheTick &+= 1
    previewCache[source] = CachedPreview(image: image, kind: kind, lastUsed: previewCacheTick)
    var byteCount = previewCache.values.reduce(0) { $0 + $1.image.rgba8.count }
    while previewCache.count > maximumPreviewCacheCount || byteCount > maximumPreviewCacheBytes {
      guard let oldest = previewCache.min(by: { $0.value.lastUsed < $1.value.lastUsed }) else { break }
      byteCount -= oldest.value.image.rgba8.count
      previewCache.removeValue(forKey: oldest.key)
    }
  }
}

private struct CachedPreview {
  var image: ImageResource
  var kind: PreviewKind
  var lastUsed: UInt64
}

private enum PreviewKind: Sendable {
  case renderedProxy
  case rawDeveloped

  var label: String {
    switch self {
    case .renderedProxy: "JPEG proxy"
    case .rawDeveloped: "RAW developed"
    }
  }
}

private enum ScanResult: Sendable {
  case success(frames: [URL], previewSources: [URL: URL], isRAW: Bool)
  case failure(String)
}

private enum PreviewResult: Sendable {
  case success(ImageResource, kind: PreviewKind)
  case failure(String)
}

private enum PreviewError: Error, CustomStringConvertible {
  case invalidRGBData
  case invalidPAM
  case ffmpegNotFound
  case ffmpegFailed(String)

  var description: String {
    switch self {
    case .invalidRGBData:
      "LibRaw returned an unexpected RGB buffer."
    case .invalidPAM:
      "ffmpeg returned an invalid PAM preview image."
    case .ffmpegNotFound:
      "ffmpeg was not found on PATH."
    case .ffmpegFailed(let detail):
      detail.isEmpty ? "ffmpeg could not decode the preview image." : detail
    }
  }
}

@MainActor
public struct TimelapseBlock: Block {
  public static let previousFrameCommand = Command.application("gopro-timelapse.frame.previous")
  public static let nextFrameCommand = Command.application("gopro-timelapse.frame.next")
  public static let firstFrameCommand = Command.application("gopro-timelapse.frame.first")
  public static let lastFrameCommand = Command.application("gopro-timelapse.frame.last")

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
      .onCommand(Self.previousFrameCommand) { state.moveSelection(by: -1) }
      .onCommand(Self.nextFrameCommand) { state.moveSelection(by: 1) }
      .onCommand(Self.firstFrameCommand) { state.selectFirstFrame() }
      .onCommand(Self.lastFrameCommand) { state.selectLastFrame() }
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
        if let previewLabel = state.previewLabel {
          Text(previewLabel)
            .fontScale(0.56)
            .foregroundColor(theme.secondaryForeground)
        }
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
