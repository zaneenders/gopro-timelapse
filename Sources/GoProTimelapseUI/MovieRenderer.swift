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
    grades: [Grade],
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
    let encoderList = try await ProcessRunner.availableEncoders(executable: ffmpeg)
    let master = MovieEncodingPlan.masterURL(for: output)
    let first = try develop16(
      source: sources[0], grade: grades[0], width: settings.maximumWidth,
      denoise: settings.preview ? 0.15 : 0.7)
    let expectedBytes = first.width * first.height * 3 * 2
    guard first.pixels.count == expectedBytes else { throw MovieRenderError.invalidRGBData }

    try FileManager.default.createDirectory(
      at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let proResEncoder = MovieEncodingPlan.proResEncoder(available: encoderList) else {
      throw MovieRenderError.missingProResEncoder
    }
    let proResDescription = proResEncoder.description
    let process = Process()
    process.executableURL = ffmpeg
    let arguments = [
      "-y", "-v", "error", "-f", "rawvideo", "-pixel_format", "rgb48le",
      "-video_size", "\(first.width)x\(first.height)",
      "-framerate", String(settings.fps), "-i", "-",
    ] + MovieEncodingPlan.proResArguments(
      encoder: proResEncoder, output: master, explicitVideoRange: false)
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
              denoise: settings.preview ? 0.15 : 0.7)
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

    let deliveryBackend: DeliveryEncoder
    #if os(macOS)
    deliveryBackend = MovieEncodingPlan.deliveryEncoder(
      codec: .hevc, available: encoderList, preference: [.videotoolbox])
    #else
    deliveryBackend = MovieEncodingPlan.deliveryEncoder(
      codec: .hevc, available: encoderList, preference: [.nvenc])
    #endif
    let deliveryEncoder: String
    switch deliveryBackend {
    case .videotoolbox: deliveryEncoder = "VideoToolbox HEVC Main 10"
    case .nvenc: deliveryEncoder = "NVENC HEVC Main 10"
    case .software: deliveryEncoder = "libx265 HEVC Main 10"
    }
    let deliveryArguments = ["-y", "-v", "error", "-i", master.path]
      + MovieEncodingPlan.deliveryArguments(
        codec: .hevc, encoder: deliveryBackend, output: output,
        softwarePreset: "medium", explicitVideoRange: false, explicitMain10Profile: true)
    outputHandler(.system, commandDescription(executable: ffmpeg, arguments: deliveryArguments))
    _ = try await ProcessRunner.run(executable: ffmpeg, arguments: deliveryArguments) { stream, data in
      outputHandler(stream == .stdout ? .stdout : .stderr, String(decoding: data, as: UTF8.self))
    }
    return metrics(
      start: start, sources: sources, output: output, settings: settings,
      encoder: "\(proResDescription) → \(deliveryEncoder)", source: "GPR/LibRaw 16-bit")
  }

  private static func develop16(
    source: URL, grade: Grade, width: Int, denoise: Double
  ) throws -> LibrawRGB16Image {
    try RAWDeveloper.developRGB16(
      source: source, grade: grade,
      settings: .init(maximumWidth: width, denoise: denoise))
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

  private static func ffmpegURL() throws -> URL {
    #if os(macOS)
    let additionalDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]
    #else
    let additionalDirectories: [String] = []
    #endif
    guard let executable = ProcessRunner.executableURL(
      "ffmpeg", additionalDirectories: additionalDirectories)
    else { throw MovieRenderError.ffmpegNotFound }
    return executable
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
