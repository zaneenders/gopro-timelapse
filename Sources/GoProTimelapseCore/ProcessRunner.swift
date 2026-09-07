import Foundation
import Synchronization

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum ProcessStream: Sendable { case stdout, stderr }

public struct ProcessResult: Sendable {
  public let status: Int32
  public let stdout: Data
  public let stderr: Data
}

public struct ProcessFailure: Error, CustomStringConvertible, Sendable {
  public let executable: URL
  public let result: ProcessResult
  public var description: String {
    let detail = String(decoding: result.stderr, as: UTF8.self)
    return "\(executable.lastPathComponent) failed (status \(result.status)): \(detail)"
  }
}

/// Executes non-interactive commands. Output callbacks receive raw chunks on
/// concurrent reader queues and must be thread-safe and nonblocking. Captures
/// retain only the final `captureLimit` bytes of each stream.
public enum ProcessRunner {
  public typealias OutputHandler = @Sendable (ProcessStream, Data) -> Void

  public static func executableURL(
    _ name: String, searchPath: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
    additionalDirectories: [String] = []
  ) -> URL? {
    let candidates =
      name.contains("/")
      ? [URL(fileURLWithPath: name)]
      : (searchPath.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        + additionalDirectories).map {
          URL(fileURLWithPath: $0.isEmpty ? FileManager.default.currentDirectoryPath : $0)
            .appendingPathComponent(name)
        }
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }?.standardizedFileURL
  }

  public static func run(
    executable: URL, arguments: [String], captureLimit: Int = 256 * 1024,
    output: @escaping OutputHandler = { _, _ in }
  ) async throws -> ProcessResult {
    let execution = Execution(executable: executable, arguments: arguments)
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await Task.detached {
        try execution.run(captureLimit: max(0, captureLimit), output: output)
      }.value
    } onCancel: {
      execution.cancel()
    }
  }

  public static func availableEncoders(executable: URL) async throws -> String {
    let result = try await run(
      executable: executable, arguments: ["-hide_banner", "-encoders"], captureLimit: 1024 * 1024)
    return String(decoding: result.stdout, as: UTF8.self)
  }
}

private final class Execution: Sendable {
  private struct State {
    let process: Process
    var cancelled = false
  }
  private let state: Mutex<State>
  private let executable: URL

  init(executable: URL, arguments: [String]) {
    self.executable = executable
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    state = Mutex(State(process: process))
  }

  func cancel() {
    state.withLock {
      $0.cancelled = true
      if $0.process.isRunning { $0.process.terminate() }
    }
    // Do not let a child that ignores SIGTERM hold the cancelled task forever.
    // This runner owns only its direct child, not an arbitrary descendant tree.
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [self] in
      state.withLock {
        if $0.cancelled && $0.process.isRunning {
          _ = kill($0.process.processIdentifier, SIGKILL)
        }
      }
    }
  }

  func run(captureLimit: Int, output: @escaping ProcessRunner.OutputHandler) throws -> ProcessResult {
    let stdout = Pipe()
    let stderr = Pipe()
    defer {
      try? stdout.fileHandleForReading.close()
      try? stderr.fileHandleForReading.close()
      try? stdout.fileHandleForWriting.close()
      try? stderr.fileHandleForWriting.close()
    }
    let process = try state.withLock { state in
      if state.cancelled { throw CancellationError() }
      state.process.standardOutput = stdout
      state.process.standardError = stderr
      try state.process.run()
      return state.process
    }
    // Parent copies must not keep the pipes open after the child exits.
    try? stdout.fileHandleForWriting.close()
    try? stderr.fileHandleForWriting.close()
    let readers = DispatchGroup()
    let capturedOutput = Capture(limit: captureLimit)
    let capturedError = Capture(limit: captureLimit)
    for (pipe, stream, capture) in [
      (stdout, ProcessStream.stdout, capturedOutput), (stderr, ProcessStream.stderr, capturedError),
    ] {
      readers.enter()
      DispatchQueue.global().async {
        defer { readers.leave() }
        while true {
          let data = pipe.fileHandleForReading.availableData
          guard !data.isEmpty else { break }
          capture.append(data)
          output(stream, data)
        }
      }
    }
    process.waitUntilExit()
    readers.wait()
    if state.withLock({ $0.cancelled }) { throw CancellationError() }
    let result = ProcessResult(
      status: process.terminationStatus, stdout: capturedOutput.data, stderr: capturedError.data)
    guard process.terminationReason == .exit, result.status == 0 else {
      throw ProcessFailure(executable: executable, result: result)
    }
    return result
  }
}

private final class Capture: Sendable {
  private let storage = Mutex(Data())
  private let limit: Int
  init(limit: Int) { self.limit = limit }
  var data: Data { storage.withLock { $0 } }
  func append(_ data: Data) {
    storage.withLock {
      if data.count >= limit {
        $0 = Data(data.suffix(limit))
      } else {
        let excess = max(0, $0.count + data.count - limit)
        $0.removeFirst(excess)
        $0.append(data)
      }
    }
  }
}
