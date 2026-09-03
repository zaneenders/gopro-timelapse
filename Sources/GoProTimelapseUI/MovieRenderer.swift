import Foundation
import GoProTimelapseCore
import GprTools
import Libraw
import Synchronization

struct MovieRenderSettings: Sendable {
  var maximumWidth: Int
  var fps: Double
  var preview: Bool
}

struct MovieRenderMetrics: Sendable {
  var frameCount: Int
  var outputBytes: Int64
  var elapsedSeconds: Double
  var videoDurationSeconds: Double
  var encoder: String
  var source: String
  var maximumWidth: Int

  var framesPerSecond: Double {
    elapsedSeconds > 0 ? Double(frameCount) / elapsedSeconds : 0
  }

  var realtimeFactor: Double {
    elapsedSeconds > 0 ? videoDurationSeconds / elapsedSeconds : 0
  }
}

enum ProcessOutputStream: String, Sendable {
  case stdout
  case stderr
  case system
}

typealias ProcessOutputHandler = @Sendable (ProcessOutputStream, String) -> Void

private final class ProcessOutputCapture: Sendable {
  private let storage = Mutex("")

  var text: String { storage.withLock { $0 } }
  func append(_ text: String) { storage.withLock { $0.append(text) } }
}

private final class FFmpegProgressParser: Sendable {
  private struct State: Sendable {
    var pending = ""
    var lastFrame = 0
  }

  private let storage = Mutex(State())

  func append(_ text: String) -> Int? {
    storage.withLock { state in
      state.pending += text
      let lines = state.pending.split(separator: "\n", omittingEmptySubsequences: false)
      state.pending = lines.last.map(String.init) ?? ""
      var latest: Int?
      for line in lines.dropLast() {
        guard line.hasPrefix("frame="),
          let frame = Int(line.dropFirst("frame=".count)), frame > state.lastFrame
        else { continue }
        state.lastFrame = frame
        latest = frame
      }
      return latest
    }
  }
}

enum MovieRenderer {
  static func renderProxyPreview(
    sources: [URL],
    grades: [UIGrade],
    output: URL,
    settings: MovieRenderSettings,
    progress: @escaping @Sendable (Int) -> Void,
    outputHandler: @escaping ProcessOutputHandler
  ) throws -> MovieRenderMetrics {
    let start = ContinuousClock.now
    guard !sources.isEmpty, sources.count == grades.count else {
      throw MovieRenderError.invalidSequence
    }
    guard !sources.contains(where: { $0.pathExtension.lowercased() == "gpr" }) else {
      throw MovieRenderError.missingProxy
    }
    let ffmpeg = try ffmpegURL()
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
      "gopro-timelapse-proxy-movie-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    // Keep each proxy's real filename/extension. A synthetic `.img` sequence is
    // interpreted as GEM by newer FFmpeg releases instead of being content-probed.
    // The concat demuxer supports mixed JPEG/PNG/TIFF inputs without disguising them.
    let frameList = temporary.appendingPathComponent("frames.txt")
    let frameDuration = 1 / settings.fps
    var frameLines = sources.flatMap { source in
      [
        "file '\(escapeConcatPath(source.path))'",
        String(format: "duration %.12f", frameDuration),
      ]
    }
    // concat applies the final duration only when another file follows it. Repeat
    // the last entry and cap output to the real frame count below.
    frameLines.append("file '\(escapeConcatPath(sources[sources.count - 1].path))'")
    try (frameLines.joined(separator: "\n") + "\n").write(
      to: frameList, atomically: true, encoding: .utf8)

    let commands = temporary.appendingPathComponent("exposure.txt")
    let lines = grades.indices.map { index in
      let time = Double(index) / settings.fps
      let exposure = min(3, max(-3, grades[index].exposure))
      return String(format: "%.6f exposure exposure %.6f;", time, exposure)
    }
    try (lines.joined(separator: "\n") + "\n").write(
      to: commands, atomically: true, encoding: .utf8)

    try FileManager.default.createDirectory(
      at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    let filter =
      "sendcmd=f='\(escapeFilterPath(commands.path))',exposure@exposure=0,scale='min(\(settings.maximumWidth),iw)':-2"
    let encoderList = availableEncoders(ffmpeg)
    let encoder: String
    let process = Process()
    process.executableURL = ffmpeg
    var arguments = [
      "-y", "-v", "error", "-progress", "pipe:1", "-nostats",
      "-r", String(settings.fps),
      "-f", "concat", "-safe", "0", "-i", frameList.path,
      "-vf", filter, "-fps_mode", "cfr", "-r", String(settings.fps),
      "-frames:v", String(sources.count),
    ]
    #if os(macOS)
    if encoderList.contains("h264_videotoolbox") {
      encoder = "VideoToolbox H.264"
      arguments += ["-c:v", "h264_videotoolbox", "-b:v", "3M", "-allow_sw", "1"]
    } else {
      encoder = "libx264"
      arguments += ["-c:v", "libx264", "-preset", "veryfast", "-crf", "30"]
    }
    #else
    if encoderList.contains("h264_nvenc") {
      encoder = "NVENC H.264"
      arguments += ["-c:v", "h264_nvenc", "-preset", "p4", "-cq", "30"]
    } else {
      encoder = "libx264"
      arguments += ["-c:v", "libx264", "-preset", "veryfast", "-crf", "30"]
    }
    #endif
    arguments += [
      "-pix_fmt", "yuv420p", "-colorspace", "bt709", "-color_primaries", "bt709",
      "-color_trc", "bt709", "-movflags", "+faststart", output.path,
    ]
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    outputHandler(.system, commandDescription(executable: ffmpeg, arguments: arguments))
    let progressParser = FFmpegProgressParser()
    let captured = try runCapturingOutput(
      process,
      outputHandler: { stream, text in
        guard stream == .stdout else {
          outputHandler(stream, text)
          return
        }
        if let completed = progressParser.append(text) {
          progress(min(completed, sources.count))
        }
      })
    guard process.terminationStatus == 0 else {
      throw MovieRenderError.ffmpegFailed(
        captured.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    progress(sources.count)
    return metrics(
      start: start, sources: sources, output: output, settings: settings,
      encoder: encoder, source: "JPEG proxies")
  }

  static func render(
    sources: [URL],
    grades: [UIGrade],
    output: URL,
    settings: MovieRenderSettings,
    progress: @escaping @Sendable (Int) -> Void,
    outputHandler: @escaping ProcessOutputHandler
  ) async throws -> MovieRenderMetrics {
    let start = ContinuousClock.now
    guard !sources.isEmpty, sources.count == grades.count else {
      throw MovieRenderError.invalidSequence
    }
    guard sources.allSatisfy({ $0.pathExtension.lowercased() == "gpr" }) else {
      throw MovieRenderError.rawOnly
    }
    let ffmpeg = try ffmpegURL()
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
      "gopro-timelapse-movie-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let first = try develop(
      source: sources[0], grade: grades[0], width: settings.maximumWidth,
      denoise: settings.preview ? 0.15 : 0.7, temporary: temporary)
    let expectedBytes = first.width * first.height * 3
    guard first.pixels.count == expectedBytes else { throw MovieRenderError.invalidRGBData }

    try FileManager.default.createDirectory(
      at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    let process = Process()
    process.executableURL = ffmpeg
    var arguments = [
      "-y", "-v", "error",
      "-f", "rawvideo", "-pixel_format", "rgb24",
      "-video_size", "\(first.width)x\(first.height)",
      "-framerate", String(settings.fps), "-i", "-",
    ]
    let encoderList = availableEncoders(ffmpeg)
    let encoder: String
    if settings.preview {
      encoder = "libx264"
      arguments += ["-c:v", "libx264", "-preset", "veryfast", "-crf", "30"]
    } else {
      #if os(macOS)
      if encoderList.contains("hevc_videotoolbox") {
        encoder = "VideoToolbox HEVC"
        arguments += [
          "-c:v", "hevc_videotoolbox", "-b:v", "30M", "-maxrate", "30M",
          "-bufsize", "60M", "-allow_sw", "0", "-tag:v", "hvc1",
        ]
      } else {
        encoder = "libx265 HEVC"
        arguments += ["-c:v", "libx265", "-preset", "medium", "-crf", "20", "-tag:v", "hvc1"]
      }
      #else
      if encoderList.contains("hevc_nvenc") {
        encoder = "NVENC HEVC"
        arguments += ["-c:v", "hevc_nvenc", "-preset", "p6", "-rc", "vbr", "-cq", "20", "-tag:v", "hvc1"]
      } else {
        encoder = "libx265 HEVC"
        arguments += ["-c:v", "libx265", "-preset", "medium", "-crf", "20", "-tag:v", "hvc1"]
      }
      #endif
    }
    arguments += [
      "-pix_fmt", "yuv420p", "-colorspace", "bt709", "-color_primaries", "bt709",
      "-color_trc", "bt709", "-movflags", "+faststart", output.path,
    ]
    process.arguments = arguments
    let input = Pipe()
    let outputPipe = Pipe()
    let errors = Pipe()
    process.standardInput = input
    process.standardOutput = outputPipe
    process.standardError = errors
    outputHandler(.system, commandDescription(executable: ffmpeg, arguments: arguments))
    let capturedError = ProcessOutputCapture()
    let outputReaders = DispatchGroup()
    startReading(
      outputPipe, stream: .stdout, captured: nil, group: outputReaders,
      outputHandler: outputHandler)
    startReading(
      errors, stream: .stderr, captured: capturedError, group: outputReaders,
      outputHandler: outputHandler)
    try process.run()

    let writer = input.fileHandleForWriting
    do {
      try writer.write(contentsOf: first.pixels)
      progress(1)

      // RAW development dwarfs pipe writes and encoding. Develop independent
      // frames concurrently, but consume them in source order so ffmpeg still
      // receives a deterministic stream. Keeping the window small bounds 4K
      // RGB memory (roughly 24 MB per completed frame).
      let workerCount = min(
        max(2, ProcessInfo.processInfo.activeProcessorCount / 2),
        max(1, sources.count - 1))
      var nextToEnqueue = 1
      var nextToWrite = 1
      var completedImages: [Int: LibrawRGBImage] = [:]

      try await withThrowingTaskGroup(of: (Int, LibrawRGBImage).self) { group in
        func enqueue(_ index: Int) {
          group.addTask(priority: .userInitiated) {
            if Task.isCancelled { throw CancellationError() }
            let image = try develop(
              source: sources[index], grade: grades[index], width: settings.maximumWidth,
              denoise: settings.preview ? 0.15 : 0.7, temporary: temporary)
            return (index, image)
          }
        }

        while nextToEnqueue < sources.count && nextToEnqueue < 1 + workerCount {
          enqueue(nextToEnqueue)
          nextToEnqueue += 1
        }

        while let (index, image) = try await group.next() {
          completedImages[index] = image
          while let ready = completedImages.removeValue(forKey: nextToWrite) {
            guard ready.width == first.width, ready.height == first.height,
              ready.pixels.count == expectedBytes
            else { throw MovieRenderError.inconsistentDimensions }
            try writer.write(contentsOf: ready.pixels)
            nextToWrite += 1
            progress(nextToWrite)
            if nextToEnqueue < sources.count {
              enqueue(nextToEnqueue)
              nextToEnqueue += 1
            }
          }
        }
      }
      try writer.close()
      process.waitUntilExit()
    } catch {
      try? writer.close()
      process.terminate()
      process.waitUntilExit()
      await wait(for: outputReaders)
      throw error
    }
    await wait(for: outputReaders)
    guard process.terminationStatus == 0 else {
      throw MovieRenderError.ffmpegFailed(
        capturedError.text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return metrics(
      start: start, sources: sources, output: output, settings: settings,
      encoder: encoder, source: "GPR/LibRaw")
  }

  private static func develop(
    source: URL, grade: UIGrade, width: Int, denoise: Double, temporary: URL
  ) throws -> LibrawRGBImage {
    let dng = temporary.appendingPathComponent("frame-\(UUID().uuidString).dng")
    defer { try? FileManager.default.removeItem(at: dng) }
    try GprTools.convert(gprFile: source.path, toDNG: dng.path)
    let developer = Libraw()
    try developer.open(dng.path)
    developer.setGrade(
      LibrawGrade(exposure: grade.exposure, temperature: grade.temperature))
    developer.setDenoise(denoise)
    developer.setMaxWidth(width)
    return try developer.developRGB()
  }

  private static func metrics(
    start: ContinuousClock.Instant,
    sources: [URL],
    output: URL,
    settings: MovieRenderSettings,
    encoder: String,
    source: String
  ) -> MovieRenderMetrics {
    let elapsed = start.duration(to: .now)
    let seconds =
      Double(elapsed.components.seconds)
      + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000
    let bytes = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    return MovieRenderMetrics(
      frameCount: sources.count,
      outputBytes: bytes,
      elapsedSeconds: seconds,
      videoDurationSeconds: Double(sources.count) / settings.fps,
      encoder: encoder,
      source: source,
      maximumWidth: settings.maximumWidth)
  }

  private static func runCapturingOutput(
    _ process: Process,
    outputHandler: @escaping ProcessOutputHandler
  ) throws -> (stdout: String, stderr: String) {
    let output = Pipe()
    let errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    let capturedOutput = ProcessOutputCapture()
    let capturedError = ProcessOutputCapture()
    let readers = DispatchGroup()
    startReading(
      output, stream: .stdout, captured: capturedOutput, group: readers,
      outputHandler: outputHandler)
    startReading(
      errors, stream: .stderr, captured: capturedError, group: readers,
      outputHandler: outputHandler)
    try process.run()
    process.waitUntilExit()
    readers.wait()
    return (capturedOutput.text, capturedError.text)
  }

  private static func wait(for group: DispatchGroup) async {
    await withCheckedContinuation { continuation in
      group.notify(queue: .global(qos: .utility)) {
        continuation.resume()
      }
    }
  }

  private static func startReading(
    _ pipe: Pipe,
    stream: ProcessOutputStream,
    captured: ProcessOutputCapture?,
    group: DispatchGroup,
    outputHandler: @escaping ProcessOutputHandler
  ) {
    group.enter()
    DispatchQueue.global(qos: .utility).async {
      let handle = pipe.fileHandleForReading
      while true {
        let data = handle.availableData
        guard !data.isEmpty else { break }
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { continue }
        captured?.append(text)
        outputHandler(stream, text)
      }
      group.leave()
    }
  }

  private static func commandDescription(executable: URL, arguments: [String]) -> String {
    let command = ([executable.path] + arguments).map { argument in
      guard argument.contains(where: { $0.isWhitespace || "'\\\"".contains($0) }) else {
        return argument
      }
      return "'\(argument.replacingOccurrences(of: "'", with: "'\\''"))'"
    }.joined(separator: " ")
    return "$ \(command)\n"
  }

  private static func availableEncoders(_ ffmpeg: URL) -> String {
    let process = Process()
    process.executableURL = ffmpeg
    process.arguments = ["-hide_banner", "-encoders"]
    process.standardInput = FileHandle.nullDevice
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return "" }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
  }

  private static func escapeConcatPath(_ path: String) -> String {
    // FFmpeg concat files use shell-style single-quoted paths.
    path.replacingOccurrences(of: "'", with: "'\\''")
  }

  private static func escapeFilterPath(_ path: String) -> String {
    path.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: ":", with: "\\:")
      .replacingOccurrences(of: "'", with: "\\'")
  }

  private static func ffmpegURL() throws -> URL {
    var directories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
      .split(separator: ":").map(String.init)
    #if os(macOS)
    directories += ["/opt/homebrew/bin", "/usr/local/bin"]
    #endif
    for directory in directories {
      let candidate = URL(fileURLWithPath: directory).appendingPathComponent("ffmpeg")
      if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
    }
    throw MovieRenderError.ffmpegNotFound
  }
}

enum MovieRenderError: Error, CustomStringConvertible {
  case invalidSequence
  case rawOnly
  case missingProxy
  case invalidRGBData
  case inconsistentDimensions
  case ffmpegNotFound
  case ffmpegFailed(String)

  var description: String {
    switch self {
    case .invalidSequence: "The render sequence is empty or has inconsistent grades."
    case .rawOnly: "Movie rendering currently requires a GPR sequence."
    case .missingProxy: "Quick Preview requires a paired JPEG or rendered frame for every GPR."
    case .invalidRGBData: "LibRaw returned an invalid RGB frame."
    case .inconsistentDimensions: "Developed frames have inconsistent dimensions."
    case .ffmpegNotFound: "ffmpeg was not found on PATH."
    case .ffmpegFailed(let detail): detail.isEmpty ? "ffmpeg failed to encode the movie." : detail
    }
  }
}
