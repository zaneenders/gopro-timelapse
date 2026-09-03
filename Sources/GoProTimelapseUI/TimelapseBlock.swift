import Chroma
import Foundation
import GoProTimelapseCore
import GprTools
import Libraw
import Synchronization

@MainActor
public final class TimelapseUIState {
  public var sourcePath: String
  public var frames: [URL] = []
  public var selectedFrame = 0
  public var preview: ImageResource?
  public var previewLabel: String?
  public var exposure: Double = 0
  public var temperature: Double = 5_200
  public var gradeKeyframes: [Int: UIGrade] = [:]
  public var luminanceSamples: [LuminanceSample] = []
  public var luminanceBaseline: [Double] = []
  public var automaticExposure: [Double] = []
  public var automaticCorrectionEnabled = false
  public var automaticStrength: Double = 1
  public var analysisProgress = 0.0
  public var isAnalyzing = false
  public var renderProgress = 0.0
  public var isRendering = false
  public var lastMovieURL: URL?
  public var renderSummaryLines: [String] = []
  public var status = "Choose a folder containing GPR or rendered photo frames."
  public var consoleLines = ["[system] Ready. Process output will appear here."]
  public var isConsoleVisible = false
  public var isRenderMenuVisible = false
  public var isLoading = false
  public let frameListController = ScrollViewController()
  public let consoleController = ScrollViewController()

  private var loadGeneration: UInt64 = 0
  private var previewTask: Task<Void, Never>?
  private var analysisTask: Task<Void, Never>?
  private var renderTask: Task<Void, Never>?
  private var previewSources: [URL: URL] = [:]

  public init(sourcePath: String = FileManager.default.currentDirectoryPath) {
    self.sourcePath = sourcePath
  }

  deinit {
    previewTask?.cancel()
    analysisTask?.cancel()
    renderTask?.cancel()
  }

  public var selectedURL: URL? {
    frames.indices.contains(selectedFrame) ? frames[selectedFrame] : nil
  }

  public var hasCompletedAnalysis: Bool {
    !frames.isEmpty && luminanceSamples.count == frames.count
  }

  public var canRender: Bool {
    hasCompletedAnalysis && !isAnalyzing && !isRendering
  }

  public func loadSource() {
    let directory = URL(fileURLWithPath: sourcePath).standardizedFileURL
    loadGeneration &+= 1
    let generation = loadGeneration
    previewTask?.cancel()
    analysisTask?.cancel()
    renderTask?.cancel()
    analysisTask = nil
    renderTask = nil
    isLoading = true
    isAnalyzing = false
    isRendering = false
    renderProgress = 0
    lastMovieURL = nil
    renderSummaryLines = []
    analysisProgress = 0
    luminanceSamples = []
    luminanceBaseline = []
    automaticExposure = []
    gradeKeyframes = [:]
    frames = []
    selectedFrame = 0
    preview = nil
    previewLabel = nil
    previewSources = [:]
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
    let grade = ExposureWorkflow.grade(at: index, keyframes: gradeKeyframes, frameCount: frames.count)
    exposure = grade.exposure
    temperature = grade.temperature
    frameListController.scroll(to: max(0, Float(index - 2) * 52))

    // Selection is immediate, but LibRaw/GPR conversion is not cooperatively
    // cancellable. Keep one conversion in flight and load the latest selection
    // as soon as it finishes instead of starting an unbounded queue of work.
    if isLoading {
      status = "Waiting to preview \(frames[index].lastPathComponent)…"
    } else {
      startPreview(for: index)
    }
  }

  public func adjustExposure(by delta: Double) {
    exposure = min(8, max(-8, exposure + delta))
    setCurrentKeyframe()
    status = String(format: "Keyframe %d — exposure %+.2f EV", selectedFrame + 1, exposure)
  }

  public func adjustTemperature(by delta: Double) {
    temperature = min(12_000, max(2_000, temperature + delta))
    setCurrentKeyframe()
    status = "Keyframe \(selectedFrame + 1) — temperature \(Int(temperature)) K"
  }

  public func setCurrentKeyframe() {
    guard frames.indices.contains(selectedFrame) else { return }
    gradeKeyframes[selectedFrame] = UIGrade(exposure: exposure, temperature: temperature)
  }

  public func removeCurrentKeyframe() {
    gradeKeyframes.removeValue(forKey: selectedFrame)
    let grade = ExposureWorkflow.grade(at: selectedFrame, keyframes: gradeKeyframes, frameCount: frames.count)
    exposure = grade.exposure
    temperature = grade.temperature
    status = "Removed keyframe \(selectedFrame + 1)."
  }

  public func resetGrade() {
    gradeKeyframes = [:]
    exposure = 0
    temperature = 5_200
    status = "All creative grade keyframes reset."
  }

  public func toggleAutomaticCorrection() {
    automaticCorrectionEnabled.toggle()
    status = "Automatic correction \(automaticCorrectionEnabled ? "enabled" : "disabled")."
  }

  public func adjustAutomaticStrength(by delta: Double) {
    automaticStrength = min(1, max(0, automaticStrength + delta))
    status = String(format: "Automatic correction strength %.0f%%", automaticStrength * 100)
  }

  public func developSelectedRAW() {
    guard let source = selectedURL else { return }
    guard source.pathExtension.lowercased() == "gpr" else {
      status = "RAW development is only available for GPR frames."
      return
    }
    startPreview(for: selectedFrame, forceRAW: true)
  }

  public func analyzeLuminance() {
    guard !frames.isEmpty, !isAnalyzing else { return }
    analysisTask?.cancel()
    let sources = frames.map { previewSources[$0] ?? $0 }
    isAnalyzing = true
    analysisProgress = 0
    luminanceSamples = []
    luminanceBaseline = []
    automaticExposure = []
    // A new analysis invalidates the currently displayed developed preview.
    preview = nil
    previewLabel = nil
    status = "Analyzing luminance 0/\(sources.count)…"
    appendConsole(
      .system,
      "Starting fresh luminance analysis for \(sources.count) frames; no analysis cache is used.\n")

    analysisTask = Task { [weak self] in
      // Decoding dominates this pass. Keep several independent frames in flight,
      // but bound the group so thousands of frames do not create thousands of
      // ffmpeg processes or unbounded RGBA buffers.
      let concurrency = min(sources.count, max(2, min(8, ProcessInfo.processInfo.activeProcessorCount / 2)))
      var orderedSamples = [LuminanceSample?](repeating: nil, count: sources.count)
      var completed = 0
      var nextIndex = 0
      var failure: (index: Int, message: String)?

      await withTaskGroup(of: AnalysisResult.self) { group in
        func enqueue(_ index: Int) {
          let source = sources[index]
          group.addTask(priority: .userInitiated) {
            guard !Task.isCancelled else {
              return .failure(index: index, message: "Analysis cancelled.")
            }
            do {
              let image = try Self.renderPreview(source: source)
              let sample = ExposureWorkflow.luminance(of: image, frame: index)
              return .success(sample)
            } catch {
              return .failure(index: index, message: String(describing: error))
            }
          }
        }

        while nextIndex < concurrency {
          enqueue(nextIndex)
          nextIndex += 1
        }

        while let result = await group.next() {
          guard !Task.isCancelled else {
            group.cancelAll()
            return
          }
          switch result {
          case .success(let sample):
            orderedSamples[sample.frame] = sample
            completed += 1
            let source = sources[sample.frame]
            self?.appendConsole(
              .system,
              String(
                format: "Analyzed %d/%d (frame %d: %@) — luminance %.3f EV, highlights %.2f%%\n",
                completed, sources.count, sample.frame + 1, source.lastPathComponent,
                sample.medianLogLuminance, sample.clippedHighlightFraction * 100))
            if let self {
              self.analysisProgress = Double(completed) / Double(sources.count)
              self.status = "Analyzing luminance \(completed)/\(sources.count)…"
            }
          case .failure(let failedIndex, let message):
            failure = (failedIndex, message)
            group.cancelAll()
            return
          }

          if nextIndex < sources.count {
            enqueue(nextIndex)
            nextIndex += 1
          }
        }
      }

      guard !Task.isCancelled else { return }
      if let failure {
        let source = sources[failure.index]
        self?.appendConsole(
          .stderr,
          "Analysis failed at frame \(failure.index + 1) (\(source.lastPathComponent)): \(failure.message)\n")
        self?.isAnalyzing = false
        self?.status = "Analysis failed at frame \(failure.index + 1): \(failure.message)"
        return
      }

      let samples = orderedSamples.compactMap { $0 }
      guard let self, samples.count == sources.count else { return }
      self.luminanceSamples = samples
      let correction = ExposureWorkflow.automaticCorrection(samples: samples)
      self.luminanceBaseline = correction.baseline
      self.automaticExposure = correction.correction
      self.automaticCorrectionEnabled = true
      self.isAnalyzing = false
      self.analysisProgress = 1
      let peak = correction.correction.map(abs).max() ?? 0
      self.status = String(
        format: "Analyzed %d frames and generated correction (peak %.2f EV).",
        samples.count, peak)
      self.appendConsole(
        .system,
        String(
          format: "Analysis complete — %d frames, correction peak %.2f EV.\n",
          samples.count, peak))
    }
  }

  public func generateAutomaticCorrection() {
    guard luminanceSamples.count == frames.count else {
      status = "Analyze all frames before generating automatic correction."
      return
    }
    let settings = AutomaticCorrectionSettings()
    let result = ExposureWorkflow.automaticCorrection(samples: luminanceSamples, settings: settings)
    luminanceBaseline = result.baseline
    automaticExposure = result.correction
    automaticCorrectionEnabled = true
    let peak = result.correction.map(abs).max() ?? 0
    status = String(
      format: "Generated bounded automatic correction (peak %.2f EV, %.0f%% trend window).",
      peak, settings.baselineWindowFraction * 100)
  }

  public func renderMovie(preview: Bool) {
    guard hasCompletedAnalysis else {
      status = "Analyze all frames before rendering."
      return
    }
    guard !isAnalyzing, !isRendering else { return }
    let sources =
      preview
      ? frames.map { previewSources[$0] ?? $0 }
      : frames
    let grades = frames.indices.map { index in
      let creative = ExposureWorkflow.grade(
        at: index, keyframes: gradeKeyframes, frameCount: frames.count)
      let automatic =
        automaticCorrectionEnabled && automaticExposure.indices.contains(index)
        ? automaticExposure[index] * automaticStrength : 0
      return UIGrade(
        exposure: creative.exposure + automatic,
        temperature: creative.temperature)
    }
    let sourceDirectory = URL(fileURLWithPath: sourcePath).standardizedFileURL
    let output = sourceDirectory.appendingPathComponent(
      preview ? "timelapse-preview.mp4" : "timelapse-render.mp4")
    let settings = MovieRenderSettings(
      maximumWidth: preview ? 960 : 3_840,
      fps: 30,
      preview: preview)
    isRendering = true
    renderProgress = 0
    lastMovieURL = nil
    renderSummaryLines = []
    status = "Rendering \(preview ? "quick preview" : "final movie") 0/\(frames.count)…"
    appendConsole(.system, "Starting \(preview ? "quick preview" : "final render") for \(frames.count) frames.\n")

    renderTask = Task { [weak self] in
      guard let self else { return }
      let progressState = RenderProgressState()
      let progressMonitor = Task { [weak self] in
        while !Task.isCancelled {
          let completed = progressState.completed
          await MainActor.run {
            guard let self else { return }
            self.renderProgress = Double(completed) / Double(sources.count)
            self.status = "Rendering \(preview ? "quick preview" : "final movie") \(completed)/\(sources.count)…"
          }
          try? await Task.sleep(for: .milliseconds(150))
        }
      }
      let result = await Task.detached(priority: .userInitiated) {
        do {
          let metrics: MovieRenderMetrics
          if preview {
            metrics = try MovieRenderer.renderProxyPreview(
              sources: sources, grades: grades, output: output, settings: settings,
              progress: { completed in progressState.completed = completed },
              outputHandler: { stream, text in self.appendConsole(stream, text) })
          } else {
            metrics = try await MovieRenderer.render(
              sources: sources, grades: grades, output: output, settings: settings,
              progress: { completed in progressState.completed = completed },
              outputHandler: { stream, text in self.appendConsole(stream, text) })
          }
          return RenderResult.success(output, metrics: metrics)
        } catch {
          return RenderResult.failure(String(describing: error))
        }
      }.value
      progressMonitor.cancel()
      guard !Task.isCancelled else { return }
      await MainActor.run {
        self.isRendering = false
        switch result {
        case .success(let output, let metrics):
          self.renderProgress = 1
          self.lastMovieURL = output
          self.renderSummaryLines = Self.renderSummaryLines(output: output, metrics: metrics)
          self.status = "Render complete — \(output.lastPathComponent)"
          self.appendConsole(.system, Self.renderSummary(output: output, metrics: metrics) + "\n")
        case .failure(let message):
          self.renderSummaryLines = ["RENDER FAILED", message]
          self.status = "Render failed: \(message)"
          self.appendConsole(.stderr, "Render failed: \(message)\n")
        }
      }
    }
  }

  nonisolated private func appendConsole(_ stream: ProcessOutputStream, _ text: String) {
    Task { @MainActor [weak self] in
      guard let self else { return }
      let prefix = "[\(stream.rawValue)] "
      let entry = prefix + text.trimmingCharacters(in: .newlines)
      guard entry != prefix else { return }
      let incoming = entry.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
      self.consoleLines.append(contentsOf: incoming)
      let maximumLines = 1_000
      if self.consoleLines.count > maximumLines {
        self.consoleLines.removeFirst(self.consoleLines.count - maximumLines)
        self.consoleLines[0] = "[… earlier output trimmed …]"
      }
      self.consoleController.scrollToBottom()
    }
  }

  private static func renderSummaryLines(
    output: URL, metrics: MovieRenderMetrics
  ) -> [String] {
    let megabytes = Double(metrics.outputBytes) / 1_000_000
    let millisecondsPerFrame =
      metrics.frameCount > 0
      ? metrics.elapsedSeconds * 1_000 / Double(metrics.frameCount) : 0
    let dimensions = metrics.maximumWidth > 0 ? "up to \(metrics.maximumWidth) px wide" : "source size"
    return [
      "RENDER COMPLETE",
      String(
        format: "%d frames  •  %.1f s elapsed  •  %.1f fps  •  %.1f ms/frame",
        metrics.frameCount, metrics.elapsedSeconds, metrics.framesPerSecond,
        millisecondsPerFrame),
      String(
        format: "%.1f s video  •  %.2fx realtime  •  %.1f MB  •  %@",
        metrics.videoDurationSeconds, metrics.realtimeFactor, megabytes, dimensions),
      "\(metrics.encoder)  •  \(metrics.source)",
      "Saved to: \(output.path)",
    ]
  }

  private static func renderSummary(output: URL, metrics: MovieRenderMetrics) -> String {
    renderSummaryLines(output: output, metrics: metrics).joined(separator: "\n")
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

  private func startPreview(for index: Int, forceRAW: Bool = false) {
    guard frames.indices.contains(index) else { return }
    previewTask?.cancel()
    loadGeneration &+= 1
    let generation = loadGeneration
    let source = frames[index]
    let previewSource = forceRAW ? source : previewSources[source] ?? source
    let previewKind: PreviewKind =
      previewSource == source && source.pathExtension.lowercased() == "gpr"
      ? .rawDeveloped : .renderedProxy
    let creativeGrade = ExposureWorkflow.grade(
      at: index, keyframes: gradeKeyframes, frameCount: frames.count)
    let automatic =
      automaticCorrectionEnabled && automaticExposure.indices.contains(index)
      ? automaticExposure[index] * automaticStrength : 0
    let grade = PreviewGrade(
      exposure: creativeGrade.exposure + automatic,
      temperature: creativeGrade.temperature)
    isLoading = true
    status = "Loading \(previewSource.lastPathComponent)…"

    previewTask = Task { [weak self] in
      let result = await Task.detached(priority: .userInitiated) {
        do {
          return PreviewResult.success(
            try Self.renderPreview(source: previewSource, grade: grade), kind: previewKind)
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
          self.preview = image
          self.previewLabel = kind.label
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

  nonisolated private static func renderPreview(
    source: URL,
    grade: PreviewGrade = PreviewGrade()
  ) throws -> ImageResource {
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
    developer.setGrade(
      LibrawGrade(exposure: grade.exposure, temperature: grade.temperature))
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
      id: ImageID("\(source.path)#raw-e\(grade.exposure)-t\(grade.temperature)"),
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
      let detail =
        String(
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

}

private struct PreviewGrade: Sendable {
  var exposure: Double = 0
  var temperature: Double = 5_200
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

private enum AnalysisResult: Sendable {
  case success(LuminanceSample)
  case failure(index: Int, message: String)
}

private final class RenderProgressState: Sendable {
  private let value = Mutex(0)

  var completed: Int {
    get { value.withLock { $0 } }
    set { value.withLock { $0 = newValue } }
  }
}

private enum RenderResult: Sendable {
  case success(URL, metrics: MovieRenderMetrics)
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
        onSubmit: { _ in state.loadSource() }
      )
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
          }
        )
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
        radius: 5
      )
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
      if !state.luminanceSamples.isEmpty {
        LuminanceGraph(
          samples: state.luminanceSamples,
          baseline: state.luminanceBaseline,
          correction: state.automaticExposure,
          selectedFrame: state.selectedFrame,
          theme: theme
        )
        .sizing(x: .grow, y: .fixed(100))
      }
      if !state.renderSummaryLines.isEmpty {
        renderSummary(theme: theme)
      }
      if state.isConsoleVisible {
        console(theme: theme)
          .sizing(x: .grow, y: .fixed(150))
      }
      VStack(spacing: 8) {
        HStack(spacing: 8) {
          Button(
            state.isConsoleVisible ? "Hide Output" : "Show Output",
            id: WidgetID("process.output.toggle"), fontScale: 0.62
          ) {
            state.isConsoleVisible.toggle()
            if state.isConsoleVisible { state.consoleController.scrollToBottom() }
          }
          Button(
            state.luminanceSamples.isEmpty ? "Analyze" : "Reanalyze",
            id: WidgetID("action.analyze"), fontScale: 0.62
          ) {
            state.analyzeLuminance()
          }
          if state.isAnalyzing {
            Text(String(format: "%.0f%%", state.analysisProgress * 100))
              .fontScale(0.56)
              .foregroundColor(theme.warning)
          } else if !state.luminanceSamples.isEmpty {
            Text("Correction generated automatically")
              .fontScale(0.56)
              .foregroundColor(theme.positive)
          }
          Spacer()
          if state.isRendering {
            Text(String(format: "%.0f%%", state.renderProgress * 100))
              .fontScale(0.56)
              .foregroundColor(theme.warning)
          }
          Button(
            state.isRenderMenuVisible ? "Export Movie ▴" : "Export Movie ▾",
            id: WidgetID("render.menu.toggle"), fontScale: 0.62,
            style: state.canRender ? nil : lockedButtonStyle(theme: theme)
          ) {
            state.isRenderMenuVisible.toggle()
          }
        }
        if state.isRenderMenuVisible {
          HStack(spacing: 8) {
            Spacer()
            VStack(spacing: 4) {
              Button(
                state.canRender ? "Proxy Transcode (960p)" : "Proxy Transcode (960p) 🔒",
                id: WidgetID("render.preview"), fontScale: 0.56,
                style: state.canRender ? nil : lockedButtonStyle(theme: theme)
              ) {
                state.isRenderMenuVisible = false
                state.renderMovie(preview: true)
              }
              Button(
                state.canRender ? "RAW Develop + Encode (4K)" : "RAW Develop + Encode (4K) 🔒",
                id: WidgetID("render.final"), fontScale: 0.56,
                style: state.canRender ? nil : lockedButtonStyle(theme: theme)
              ) {
                state.isRenderMenuVisible = false
                state.renderMovie(preview: false)
              }
            }
            .padding(6)
            .roundedBackground(theme.elevatedSurface, radius: 5)
            .roundedBorder(theme.border, radius: 5)
          }
        }
      }
    }
    .padding(14)
  }

  private func renderSummary(theme: ChromaTheme) -> some Block {
    VStack(spacing: 4) {
      for (index, line) in state.renderSummaryLines.enumerated() {
        Text(line)
          .fontScale(index == 0 ? 0.58 : 0.5)
          .fontFace(.display)
          .foregroundColor(index == 0 ? theme.positive : theme.secondaryForeground)
      }
    }
    .padding(8)
    .sizing(x: .grow)
    .background(theme.elevatedSurface)
    .border(theme.border)
  }

  private func console(theme: ChromaTheme) -> some Block {
    VStack(spacing: 6) {
      HStack {
        Text("PROCESS OUTPUT")
          .fontScale(0.55)
          .fontFace(.display)
          .foregroundColor(theme.secondaryForeground)
        Spacer()
        Text(state.isAnalyzing ? "● ANALYZING" : state.isRendering ? "● RENDERING" : "● IDLE")
          .fontScale(0.5)
          .fontFace(.display)
          .foregroundColor(state.isAnalyzing || state.isRendering ? theme.warning : theme.positive)
      }
      LazyVStack(
        id: WidgetID("process.output"),
        spacing: 3,
        sticksToBottom: true,
        controller: state.consoleController,
        rows: state.consoleLines.enumerated().map { index, line in
          LazyVStack.Row(
            id: WidgetID("process.output.line.\(index)"),
            content: Text(line)
              .fontScale(0.48)
              .fontFace(.display)
              .foregroundColor(line.hasPrefix("[stderr]") ? theme.warning : theme.foreground)
              .selectable(WidgetID("process.output.text.\(index)")))
        }
      )
      .padding(8)
      .sizing(x: .grow, y: .grow)
      .background(Color.black)
      .border(theme.border)
    }
  }

  private func lockedButtonStyle(theme: ChromaTheme) -> ButtonStyle {
    ButtonStyle(
      idleBackground: theme.surface,
      hoveredBackground: theme.surface,
      pressedBackground: theme.surface,
      foreground: theme.secondaryForeground,
      border: theme.border)
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
