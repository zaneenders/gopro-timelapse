import Foundation
import GprTools
import Libraw

struct Options {
  var input = FileManager.default.currentDirectoryPath
  var output = "timelapse.mp4"
  var fps = 30.0
  var width = 3840
  var codec = "hevc"
  var encoder = "auto"
  var crf: Int?
  var bitrate: Int?
  var ffmpeg = "ffmpeg"
  var source = "auto"
  var ramp: String?
  var initializeRamp: String?
  var jobs = 0
  var denoise = 0.7
  var overwrite = false
  var keepFrames = false
  var dryRun = false
}

enum CLIError: Error, CustomStringConvertible, Sendable {
  case message(String)
  var description: String {
    if case .message(let text) = self { return text }
    return "Unknown error"
  }
}

func usage() {
  print(
    """
    gopro-timelapse — develop GoPro RAW photos with keyframed ramps, then encode an MP4

    USAGE
      gopro-timelapse [options]

    INPUT AND GRADING
      -i, --input <folder>       Photo folder (default: current directory)
          --source <auto|gpr|jpg> Prefer paired GPR RAW or rendered photos (default: auto)
          --ramp <file.json>     Keyframed exposure/color ramp
          --init-ramp <file>     Write a starter ramp, use it, and continue rendering
           --keep-frames          Keep developed PNG frames beside the output
      -j, --jobs <number>         Parallel RAW workers (default: all cores)
          --denoise <0...1>       Chroma noise reduction (default: 0.7; 0 disables)

    VIDEO
      -o, --output <file>        Output movie (default: timelapse.mp4)
      -r, --fps <number>         Frames per second (default: 30)
      -w, --width <pixels>       Maximum width; 0 keeps source size (default: 3840)
      -c, --codec <h264|hevc>    Video codec (default: hevc)
      -e, --encoder <auto|software|videotoolbox|nvenc>
                                 Encoder: auto-detect hardware or select a backend (default: auto)
          --crf <0...51>         Software/NVENC quality (defaults: h264 18, HEVC 20)
          --bitrate <Mbps>       Video bitrate (VideoToolbox defaults: h264 45, HEVC 30)
          --ffmpeg <path>        ffmpeg executable (default: ffmpeg)
      -y, --overwrite            Replace existing output/frames
          --dry-run              Inspect the plan without rendering
      -h, --help                 Show this help

    RAW mode converts .GPR to standard DNG with the GPR SDK (swift-gpr_tools),
    develops it using LibRaw (swift-libraw), and interpolates exposure, white
    balance, contrast, saturation, vibrance, shadows, and highlights between
    keyframes.
    """)
}

func value(after index: inout Int, in args: [String], option: String) throws -> String {
  index += 1
  guard index < args.count else { throw CLIError.message("Missing value after \(option)") }
  return args[index]
}

func parseArguments() throws -> Options? {
  var o = Options()
  var i = 0
  let args = Array(CommandLine.arguments.dropFirst())
  while i < args.count {
    let arg = args[i]
    switch arg {
    case "-h", "--help":
      usage()
      return nil
    case "-i", "--input": o.input = try value(after: &i, in: args, option: arg)
    case "-o", "--output": o.output = try value(after: &i, in: args, option: arg)
    case "-r", "--fps":
      let text = try value(after: &i, in: args, option: arg)
      guard let x = Double(text), x > 0, x <= 240 else { throw CLIError.message("Invalid fps: \(text)") }
      o.fps = x
    case "-w", "--width":
      let text = try value(after: &i, in: args, option: arg)
      guard let x = Int(text), x >= 0 else { throw CLIError.message("Invalid width: \(text)") }
      o.width = x
    case "-c", "--codec":
      o.codec = try value(after: &i, in: args, option: arg).lowercased()
      guard ["h264", "hevc"].contains(o.codec) else { throw CLIError.message("Codec must be h264 or hevc") }
    case "-e", "--encoder":
      o.encoder = try value(after: &i, in: args, option: arg).lowercased()
      guard ["auto", "software", "videotoolbox", "nvenc"].contains(o.encoder) else {
        throw CLIError.message("Encoder must be auto, software, videotoolbox, or nvenc")
      }
    case "--crf":
      let text = try value(after: &i, in: args, option: arg)
      guard let x = Int(text), (0...51).contains(x) else { throw CLIError.message("CRF must be 0...51") }
      o.crf = x
    case "--bitrate":
      let text = try value(after: &i, in: args, option: arg)
      guard let x = Int(text), x > 0, x <= 1_000 else { throw CLIError.message("Bitrate must be 1...1000 Mbps") }
      o.bitrate = x
    case "--source":
      o.source = try value(after: &i, in: args, option: arg).lowercased()
      guard ["auto", "gpr", "jpg"].contains(o.source) else {
        throw CLIError.message("Source must be auto, gpr, or jpg")
      }
    case "--ramp": o.ramp = try value(after: &i, in: args, option: arg)
    case "--init-ramp": o.initializeRamp = try value(after: &i, in: args, option: arg)
    case "--ffmpeg": o.ffmpeg = try value(after: &i, in: args, option: arg)
    case "-j", "--jobs":
      let text = try value(after: &i, in: args, option: arg)
      guard let x = Int(text), x >= 0 else { throw CLIError.message("Jobs must be >= 0") }
      o.jobs = x
    case "--denoise":
      let text = try value(after: &i, in: args, option: arg)
      guard let x = Double(text), (0...1).contains(x) else { throw CLIError.message("Denoise must be 0...1") }
      o.denoise = x
    case "--keep-frames": o.keepFrames = true
    case "-y", "--overwrite": o.overwrite = true
    case "--dry-run": o.dryRun = true
    default: throw CLIError.message("Unknown option: \(arg)\nRun with --help for usage.")
    }
    i += 1
  }
  return o
}

func executableURL(_ name: String) -> URL? {
  if name.contains("/") {
    let u = URL(fileURLWithPath: name).standardizedFileURL
    return FileManager.default.isExecutableFile(atPath: u.path) ? u : nil
  }
  for path in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
    let u = URL(fileURLWithPath: String(path)).appendingPathComponent(name)
    if FileManager.default.isExecutableFile(atPath: u.path) { return u }
  }
  return nil
}

func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

func availableEncoders(ffmpeg: URL) -> String {
  let process = Process()
  process.executableURL = ffmpeg
  process.arguments = ["-hide_banner", "-encoders"]
  let pipe = Pipe()
  process.standardInput = FileHandle.nullDevice
  process.standardOutput = pipe
  process.standardError = FileHandle.nullDevice
  do { try process.run() } catch { return "" }
  process.waitUntilExit()
  return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
}

func runProcess(_ executable: URL, _ arguments: [String], quiet: Bool = true) throws {
  let process = Process()
  process.executableURL = executable
  process.arguments = arguments
  process.standardInput = FileHandle.nullDevice
  if quiet {
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
  } else {
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError
  }
  try process.run()
  process.waitUntilExit()
  guard process.terminationReason == .exit, process.terminationStatus == 0 else {
    throw CLIError.message("\(executable.lastPathComponent) failed (status \(process.terminationStatus))")
  }
}

actor AsyncLimiter {
  private var available: Int
  private var waiters: [CheckedContinuation<Void, Never>] = []

  init(limit: Int) { available = max(1, limit) }

  func acquire() async {
    if available > 0 {
      available -= 1
    } else {
      await withCheckedContinuation { waiters.append($0) }
    }
  }

  func release() {
    if waiters.isEmpty {
      available += 1
    } else {
      waiters.removeFirst().resume()
    }
  }
}

actor RenderState {
  private var done = 0
  private var errorMessage: String?
  func setDone(_ value: Int) { done = value }
  func incrementDone() -> Int {
    done += 1
    return done
  }
  func setError(_ error: Error) { if errorMessage == nil { errorMessage = String(describing: error) } }
  func error() -> CLIError? { errorMessage.map(CLIError.message) }
}

actor RGBFrameStream {
  private let total: Int
  private let maxOutstanding: Int
  private var completed: [Int: LibrawRGBImage] = [:]
  private var nextWriteIndex: Int
  private var outstanding = 0
  private var cancelled = false
  private var frameWaiters: [CheckedContinuation<Void, Never>] = []
  private var slotWaiters: [CheckedContinuation<Void, Never>] = []

  init(total: Int, startIndex: Int, maxOutstanding: Int) {
    self.total = total
    self.nextWriteIndex = startIndex
    self.maxOutstanding = max(1, maxOutstanding)
  }

  func nextFrameToWrite() async -> LibrawRGBImage? {
    while true {
      if let image = completed.removeValue(forKey: nextWriteIndex) {
        nextWriteIndex += 1
        return image
      }
      if cancelled || nextWriteIndex >= total { return nil }
      await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in frameWaiters.append(c) }
    }
  }

  func frameCompleted(index: Int, image: LibrawRGBImage) async {
    // Always admit the next required frame so out-of-order completions cannot
    // fill the buffer and deadlock the writer waiting for that exact index.
    while !cancelled && outstanding >= maxOutstanding && index != nextWriteIndex {
      await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in slotWaiters.append(c) }
    }
    guard !cancelled else { return }
    outstanding += 1
    completed[index] = image
    resumeFrameWaiters()
  }

  func didWriteFrame() {
    outstanding -= 1
    resumeSlotWaiters()
  }

  func cancel() {
    cancelled = true
    completed.removeAll()
    resumeFrameWaiters()
    resumeSlotWaiters()
  }

  private func resumeFrameWaiters() {
    for c in frameWaiters { c.resume() }
    frameWaiters.removeAll()
  }

  private func resumeSlotWaiters() {
    for c in slotWaiters { c.resume() }
    slotWaiters.removeAll()
  }
}

func files(in directory: URL, extensions: Set<String>) throws -> [URL] {
  try FileManager.default.contentsOfDirectory(
    at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
  )
  .filter { extensions.contains($0.pathExtension.lowercased()) }
  .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
}

func loadRamp(_ path: String?) throws -> RampFile {
  guard let path else { return RampFile(keyframes: [Keyframe(frame: 0)]) }
  let data = try Data(contentsOf: URL(fileURLWithPath: path))
  let ramp = try JSONDecoder().decode(RampFile.self, from: data)
  guard !ramp.keyframes.isEmpty else { throw CLIError.message("Ramp has no keyframes") }
  return ramp
}

func writeInitialRamp(path: String, frameCount: Int, overwrite: Bool) throws {
  let url = URL(fileURLWithPath: path)
  if FileManager.default.fileExists(atPath: url.path), !overwrite {
    throw CLIError.message("Ramp exists; use --overwrite: \(url.path)")
  }
  let end = max(0, frameCount - 1)
  let ramp = RampFile(keyframes: [Keyframe(frame: 0), Keyframe(frame: end)])
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  try encoder.encode(ramp).write(to: url)
  print("Wrote ramp with keyframes 0 and \(end): \(url.path)")
}

func run() async throws {
  guard let o = try parseArguments() else { return }
  guard o.ramp == nil || o.initializeRamp == nil else {
    throw CLIError.message("Use either --ramp or --init-ramp, not both")
  }
  let fm = FileManager.default
  let input = URL(fileURLWithPath: o.input).standardizedFileURL
  var isDir: ObjCBool = false
  guard fm.fileExists(atPath: input.path, isDirectory: &isDir), isDir.boolValue else {
    throw CLIError.message("Input directory does not exist: \(input.path)")
  }

  let gprs = try files(in: input, extensions: ["gpr"])
  let photos = try files(in: input, extensions: ["jpg", "jpeg", "png", "tif", "tiff"])
  let useRAW = o.source == "gpr" || (o.source == "auto" && !gprs.isEmpty)
  let sources = useRAW ? gprs : photos
  guard !sources.isEmpty else { throw CLIError.message("No \(useRAW ? "GPR" : "photo") files found in \(input.path)") }

  if let path = o.initializeRamp {
    try writeInitialRamp(path: path, frameCount: sources.count, overwrite: o.overwrite)
  }
  let ramp = try loadRamp(o.initializeRamp ?? o.ramp)
  let output = URL(fileURLWithPath: o.output, relativeTo: URL(fileURLWithPath: fm.currentDirectoryPath))
    .standardizedFileURL
  if fm.fileExists(atPath: output.path), !o.overwrite {
    throw CLIError.message("Output exists; use --overwrite: \(output.path)")
  }

  print("Source: \(useRAW ? "GPR RAW" : "rendered photos")")
  print("Frames: \(sources.count) (\(sources.first!.lastPathComponent) … \(sources.last!.lastPathComponent))")
  print("Ramp: \(ramp.keyframes.count) keyframe(s), \(ramp.interpolation) interpolation")
  print(String(format: "Video: %.2f seconds at %.3g fps → %@", Double(sources.count) / o.fps, o.fps, output.path))
  if o.dryRun { return }

  guard let ffmpeg = executableURL(o.ffmpeg) else {
    throw CLIError.message("ffmpeg not found. Install it or pass --ffmpeg /path/to/ffmpeg")
  }
  try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
  let temporary = fm.temporaryDirectory.appendingPathComponent(
    "gopro-timelapse-\(UUID().uuidString)", isDirectory: true)
  let frames =
    o.keepFrames
    ? output.deletingPathExtension().appendingPathExtension("frames") : temporary.appendingPathComponent("frames")
  try fm.createDirectory(at: frames, withIntermediateDirectories: true)
  defer { if !o.keepFrames { try? fm.removeItem(at: temporary) } }

  let encoderList = availableEncoders(ffmpeg: ffmpeg)
  let videoToolboxName = o.codec == "hevc" ? "hevc_videotoolbox" : "h264_videotoolbox"
  let nvencName = o.codec == "hevc" ? "hevc_nvenc" : "h264_nvenc"
  let selectedEncoder: String
  switch o.encoder {
  case "videotoolbox":
    guard encoderList.contains(videoToolboxName) else {
      throw CLIError.message("ffmpeg does not provide \(videoToolboxName)")
    }
    selectedEncoder = "videotoolbox"
  case "nvenc":
    guard encoderList.contains(nvencName) else { throw CLIError.message("ffmpeg does not provide \(nvencName)") }
    selectedEncoder = "nvenc"
  case "software": selectedEncoder = "software"
  default:
    if encoderList.contains(videoToolboxName) {
      selectedEncoder = "videotoolbox"
    } else if encoderList.contains(nvencName) {
      selectedEncoder = "nvenc"
    } else {
      selectedEncoder = "software"
    }
  }
  let crf = String(o.crf ?? (o.codec == "hevc" ? 20 : 18))
  let encoderDescription =
    selectedEncoder == "videotoolbox"
    ? "VideoToolbox (Apple hardware)" : selectedEncoder == "nvenc" ? "NVENC (GPU)" : "software (CPU)"

  func appendVideoEncoding(to args: inout [String]) {
    switch selectedEncoder {
    case "videotoolbox":
      let bitrateMbps = o.bitrate ?? (o.codec == "hevc" ? 30 : 45)
      let bitrate = "\(bitrateMbps)M"
      args += [
        "-c:v", videoToolboxName, "-b:v", bitrate, "-maxrate", bitrate,
        "-bufsize", "\(bitrateMbps * 2)M", "-allow_sw", "0",
      ]
    case "nvenc":
      args += ["-c:v", nvencName, "-preset", "p6", "-rc", "vbr", "-cq", crf]
    default:
      args += [
        "-c:v", o.codec == "hevc" ? "libx265" : "libx264",
        "-preset", "slow", "-crf", crf,
      ]
    }
    args += [
      "-pix_fmt", "yuv420p", "-color_range", "tv", "-colorspace", "bt709",
      "-color_primaries", "bt709", "-color_trc", "bt709",
    ]
    // FFmpeg otherwise writes HEVC in MP4 with the `hev1` sample entry.
    // QuickTime expects `hvc1`, where parameter sets are also present in the
    // sample description, even though it can decode the underlying stream.
    if o.codec == "hevc" { args += ["-tag:v", "hvc1"] }
    args += ["-movflags", "+faststart", output.path]
  }

  if useRAW {
    try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
    let renderer = RAWRenderer(width: o.width, denoise: o.denoise)
    let workerCount = o.jobs > 0 ? o.jobs : ProcessInfo.processInfo.processorCount

    if o.keepFrames {
      var pending: [(source: URL, destination: URL, grade: Grade)] = []
      for (index, source) in sources.enumerated() {
        let destination = frames.appendingPathComponent(String(format: "%08d.png", index))
        if fm.fileExists(atPath: destination.path) {
          if o.overwrite { try fm.removeItem(at: destination) } else { continue }
        }
        pending.append((source: source, destination: destination, grade: interpolatedGrade(frame: index, ramp: ramp)))
      }

      let state = RenderState()
      let total = sources.count
      await state.setDone(sources.count - pending.count)
      let limiter = AsyncLimiter(limit: workerCount)

      await withTaskGroup(of: Void.self) { group in
        for item in pending {
          if await state.error() != nil { break }
          await limiter.acquire()
          group.addTask {
            defer { Task { await limiter.release() } }
            do {
              try renderer.render(
                source: item.source, destination: item.destination,
                grade: item.grade, temporaryDirectory: temporary)
            } catch {
              await state.setError(error)
            }
            let n = await state.incrementDone()
            print("\rDeveloping RAW \(n)/\(total)", terminator: "")
            try? FileHandle.standardOutput.synchronize()
          }
        }
        await group.waitForAll()
      }
      if let error = await state.error() { throw error }
      print()

      let pattern = frames.appendingPathComponent("%08d.png").path
      var args = o.overwrite ? ["-y"] : ["-n"]
      args += ["-hide_banner", "-framerate", String(o.fps), "-start_number", "0", "-i", pattern]
      appendVideoEncoding(to: &args)
      print("Encoder: \(encoderDescription)")
      try runProcess(ffmpeg, args, quiet: false)
    } else {
      // Develop the first frame before launching ffmpeg so rawvideo has
      // exact dimensions. Remaining frames are developed in parallel.
      let firstImage = try renderer.renderRGB(
        source: sources[0], grade: interpolatedGrade(frame: 0, ramp: ramp),
        temporaryDirectory: temporary)
      let expectedBytes = firstImage.width * firstImage.height * 3
      guard firstImage.pixels.count == expectedBytes else {
        throw CLIError.message("Unexpected RGB byte count for frame 0")
      }

      let ffProcess = Process()
      ffProcess.executableURL = ffmpeg
      var args = o.overwrite ? ["-y"] : ["-n"]
      args += [
        "-hide_banner", "-f", "rawvideo", "-pixel_format", "rgb24",
        "-video_size", "\(firstImage.width)x\(firstImage.height)",
        "-framerate", String(o.fps), "-i", "-",
      ]
      appendVideoEncoding(to: &args)
      ffProcess.arguments = args
      let inputPipe = Pipe()
      ffProcess.standardInput = inputPipe
      ffProcess.standardOutput = FileHandle.standardOutput
      ffProcess.standardError = FileHandle.standardError
      try ffProcess.run()
      print("Encoder: \(encoderDescription)")

      let writeHandle = inputPipe.fileHandleForWriting
      let state = RenderState()
      await state.setDone(1)
      let total = sources.count
      // RGB24 is about 24 MB at 4K. Keep only a small bounded reorder
      // queue while allowing all workers to continue processing.
      let stream = RGBFrameStream(total: total, startIndex: 1, maxOutstanding: 3)
      let limiter = AsyncLimiter(limit: workerCount)

      do {
        try writeHandle.write(contentsOf: firstImage.pixels)
      } catch {
        await stream.cancel()
        ffProcess.terminate()
        throw CLIError.message("Unable to send frame 0 to ffmpeg: \(error)")
      }
      print("\rDeveloping RAW 1/\(total)", terminator: "")
      try? FileHandle.standardOutput.synchronize()

      await withTaskGroup(of: Void.self) { group in
        group.addTask {
          while let image = await stream.nextFrameToWrite() {
            do {
              guard image.width == firstImage.width,
                image.height == firstImage.height,
                image.pixels.count == expectedBytes
              else {
                throw CLIError.message("RAW frames produced inconsistent dimensions")
              }
              try writeHandle.write(contentsOf: image.pixels)
            } catch {
              await state.setError(error)
              await stream.cancel()
              break
            }
            await stream.didWriteFrame()
          }
          try? writeHandle.close()
        }
        for index in sources.indices.dropFirst() {
          if await state.error() != nil { break }
          await limiter.acquire()
          group.addTask {
            defer { Task { await limiter.release() } }
            do {
              let image = try renderer.renderRGB(
                source: sources[index],
                grade: interpolatedGrade(frame: index, ramp: ramp),
                temporaryDirectory: temporary)
              await stream.frameCompleted(index: index, image: image)
            } catch {
              await state.setError(error)
              await stream.cancel()
            }
            let n = await state.incrementDone()
            print("\rDeveloping RAW \(n)/\(total)", terminator: "")
            try? FileHandle.standardOutput.synchronize()
          }
        }
        await group.waitForAll()
      }
      if let error = await state.error() {
        ffProcess.terminate()
        ffProcess.waitUntilExit()
        throw error
      }
      ffProcess.waitUntilExit()
      guard ffProcess.terminationStatus == 0 else {
        throw CLIError.message("ffmpeg failed (status \(ffProcess.terminationStatus))")
      }
      print()
    }
  } else {
    for (index, source) in sources.enumerated() {
      let link = frames.appendingPathComponent(String(format: "%08d.img", index))
      try fm.createSymbolicLink(at: link, withDestinationURL: source)
    }

    let pattern = frames.appendingPathComponent("%08d.img").path
    var args = o.overwrite ? ["-y"] : ["-n"]
    args += ["-hide_banner", "-framerate", String(o.fps), "-start_number", "0", "-i", pattern]
    let scale = o.width > 0 ? "scale='min(\(o.width),iw)':-2" : "scale=trunc(iw/2)*2:trunc(ih/2)*2"
    args += ["-vf", scale]
    appendVideoEncoding(to: &args)
    print("Encoder: \(encoderDescription)")
    try runProcess(ffmpeg, args, quiet: false)
  }
  print("Done: \(output.path)")
  if o.keepFrames { print("Developed frames: \(frames.path)") }
}

do { try await run() } catch {
  FileHandle.standardError.write(Data("error: \(error)\n".utf8))
  exit(1)
}
