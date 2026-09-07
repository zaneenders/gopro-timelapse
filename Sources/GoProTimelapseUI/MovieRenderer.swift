import Foundation
import GoProTimelapseCore
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

enum MovieRenderer {
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
    let encoderList = availableEncoders(ffmpeg)
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
      "gopro-timelapse-movie-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let master = output.deletingPathExtension().appendingPathExtension("prores.mov")
    let first = try develop16(
      source: sources[0], grade: grades[0], width: settings.maximumWidth,
      denoise: settings.preview ? 0.15 : 0.7, temporary: temporary)
    let expectedBytes = first.width * first.height * 3 * 2
    guard first.pixels.count == expectedBytes else { throw MovieRenderError.invalidRGBData }

    try FileManager.default.createDirectory(
      at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    let proResEncoder: String
    let proResDescription: String
    if encoderList.contains("prores_videotoolbox") {
      proResEncoder = "prores_videotoolbox"
      proResDescription = "VideoToolbox ProRes 422 HQ"
    } else if encoderList.contains("prores_ks") {
      proResEncoder = "prores_ks"
      proResDescription = "software ProRes 422 HQ"
    } else {
      throw MovieRenderError.missingProResEncoder
    }

    let process = Process()
    process.executableURL = ffmpeg
    let proResPixelFormat =
      proResEncoder == "prores_videotoolbox" ? "p210le" : "yuv422p10le"
    var arguments = [
      "-y", "-v", "error",
      "-f", "rawvideo", "-pixel_format", "rgb48le",
      "-video_size", "\(first.width)x\(first.height)",
      "-framerate", String(settings.fps), "-i", "-",
      "-vf", "format=\(proResPixelFormat)", "-c:v", proResEncoder, "-profile:v", "3",
    ]
    if proResEncoder == "prores_videotoolbox" { arguments += ["-allow_sw", "0"] }
    arguments += [
      "-pix_fmt", proResPixelFormat, "-colorspace", "bt709", "-color_primaries", "bt709",
      "-color_trc", "bt709", master.path,
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

      // RGB48 UHD frames are roughly 50 MB. Bound the ordered completion
      // window while developing independent RAW frames concurrently.
      let workerCount = min(
        max(2, ProcessInfo.processInfo.activeProcessorCount / 2),
        max(1, sources.count - 1))
      var nextToEnqueue = 1
      var nextToWrite = 1
      var completedImages: [Int: LibrawRGB16Image] = [:]

      try await withThrowingTaskGroup(of: (Int, LibrawRGB16Image).self) { group in
        func enqueue(_ index: Int) {
          group.addTask(priority: .userInitiated) {
            if Task.isCancelled { throw CancellationError() }
            let image = try develop16(
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

    let deliveryEncoder: String
    let deliveryPixelFormat: String
    var deliveryArguments = ["-y", "-v", "error", "-i", master.path]
    #if os(macOS)
    if encoderList.contains("hevc_videotoolbox") {
      deliveryEncoder = "VideoToolbox HEVC Main 10"
      deliveryPixelFormat = "p010le"
      deliveryArguments += [
        "-c:v", "hevc_videotoolbox", "-profile:v", "main10", "-b:v", "30M",
        "-maxrate", "30M", "-bufsize", "60M", "-allow_sw", "0",
      ]
    } else {
      deliveryEncoder = "libx265 HEVC Main 10"
      deliveryPixelFormat = "yuv420p10le"
      deliveryArguments += ["-c:v", "libx265", "-preset", "medium", "-crf", "20"]
    }
    #else
    if encoderList.contains("hevc_nvenc") {
      deliveryEncoder = "NVENC HEVC Main 10"
      deliveryPixelFormat = "p010le"
      deliveryArguments += [
        "-c:v", "hevc_nvenc", "-profile:v", "main10", "-preset", "p6",
        "-rc", "vbr", "-cq", "20",
      ]
    } else {
      deliveryEncoder = "libx265 HEVC Main 10"
      deliveryPixelFormat = "yuv420p10le"
      deliveryArguments += ["-c:v", "libx265", "-preset", "medium", "-crf", "20"]
    }
    #endif
    deliveryArguments += [
      "-pix_fmt", deliveryPixelFormat, "-tag:v", "hvc1", "-colorspace", "bt709",
      "-color_primaries", "bt709", "-color_trc", "bt709", "-movflags", "+faststart",
      output.path,
    ]
    let deliveryProcess = Process()
    deliveryProcess.executableURL = ffmpeg
    deliveryProcess.arguments = deliveryArguments
    deliveryProcess.standardInput = FileHandle.nullDevice
    outputHandler(.system, commandDescription(executable: ffmpeg, arguments: deliveryArguments))
    let captured = try runCapturingOutput(deliveryProcess, outputHandler: outputHandler)
    guard deliveryProcess.terminationStatus == 0 else {
      throw MovieRenderError.ffmpegFailed(
        captured.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return metrics(
      start: start, sources: sources, output: output, settings: settings,
      encoder: "\(proResDescription) → \(deliveryEncoder)", source: "GPR/LibRaw 16-bit")
  }

  private static func develop16(
    source: URL, grade: UIGrade, width: Int, denoise: Double, temporary _: URL
  ) throws -> LibrawRGB16Image {
    let dng = try DNGCache.dng(for: source)
    let developer = Libraw()
    try developer.open(dng.path)
    developer.setGrade(
      LibrawGrade(exposure: grade.exposure, temperature: grade.temperature))
    developer.setDenoise(denoise)
    developer.setMaxWidth(width)
    return try developer.developRGB16()
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
  case invalidRGBData
  case inconsistentDimensions
  case ffmpegNotFound
  case missingProResEncoder
  case ffmpegFailed(String)

  var description: String {
    switch self {
    case .invalidSequence: "The render sequence is empty or has inconsistent grades."
    case .rawOnly: "Movie rendering currently requires a GPR sequence."
    case .invalidRGBData: "LibRaw returned an invalid RGB frame."
    case .inconsistentDimensions: "Developed frames have inconsistent dimensions."
    case .ffmpegNotFound: "ffmpeg was not found on PATH."
    case .missingProResEncoder: "ffmpeg does not provide prores_videotoolbox or prores_ks."
    case .ffmpegFailed(let detail): detail.isEmpty ? "ffmpeg failed to encode the movie." : detail
    }
  }
}
