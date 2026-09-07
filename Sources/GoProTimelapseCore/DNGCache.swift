import Foundation
import GprTools

#if os(Windows)
import CRT
#elseif canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Persistent, source-local cache for GPR-to-DNG conversion.
///
/// Cached files live under `<source folder>/.gopro-timelapse/dng`. A DNG is
/// reused only when its recorded source size and modification date still match
/// the GPR. Removing `.gopro-timelapse/dng` forces conversion again.
public enum DNGCache {
  private static let condition = NSCondition()
  public static var maximumWorkerCount: Int {
    max(1, ProcessInfo.processInfo.activeProcessorCount)
  }
  private nonisolated(unsafe) static var activeWorkers = 0
  private nonisolated(unsafe) static var conversionsInProgress: Set<String> = []

  private static let workerArgument = "--gpr-conversion-worker"

  private struct Fingerprint: Codable, Equatable {
    var schemaVersion: Int
    var sourceSize: Int64
    var sourceModificationTime: TimeInterval
  }

  public static func dng(for source: URL) throws -> URL {
    let fileManager = FileManager.default
    let cacheDirectory = source.deletingLastPathComponent()
      .appendingPathComponent(".gopro-timelapse", isDirectory: true)
      .appendingPathComponent("dng", isDirectory: true)
    try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

    let stem = source.deletingPathExtension().lastPathComponent
    let destination = cacheDirectory.appendingPathComponent(stem).appendingPathExtension("dng")
    let metadata = cacheDirectory.appendingPathComponent(stem).appendingPathExtension("dng.json")
    let fingerprint = try fingerprint(for: source)
    let cacheKey = destination.path
    condition.lock()
    while conversionsInProgress.contains(cacheKey) { condition.wait() }
    if isValid(destination: destination, metadata: metadata, fingerprint: fingerprint) {
      condition.unlock()
      return destination
    }
    // A previous process can be interrupted after atomically installing the DNG
    // but before writing its sidecar. Recover that completed conversion instead
    // of starting it again. Conversion output is always written to a uniquely
    // named temporary file, so a file at `destination` was fully produced.
    if isRecoverable(destination: destination, metadata: metadata, fingerprint: fingerprint) {
      try? write(fingerprint: fingerprint, to: metadata)
      condition.unlock()
      return destination
    }
    conversionsInProgress.insert(cacheKey)
    while activeWorkers >= maximumWorkerCount { condition.wait() }
    activeWorkers += 1
    condition.unlock()
    defer {
      condition.lock()
      activeWorkers -= 1
      conversionsInProgress.remove(cacheKey)
      condition.broadcast()
      condition.unlock()
    }

    let temporary = cacheDirectory.appendingPathComponent(".\(stem)-\(UUID().uuidString).dng")
    defer { try? fileManager.removeItem(at: temporary) }
    try runWorker(source: source, destination: temporary)

    if fileManager.fileExists(atPath: destination.path) {
      try fileManager.removeItem(at: destination)
    }
    try fileManager.moveItem(at: temporary, to: destination)
    try write(fingerprint: fingerprint, to: metadata)
    return destination
  }

  /// Run by executable entry points before starting their normal application.
  /// Exits immediately when this process was launched as a conversion worker.
  public static func exitIfWorkerRequested(arguments: [String] = CommandLine.arguments) {
    if let status = runWorkerIfRequested(arguments: arguments) { exit(status) }
  }

  /// Returns an exit status when this process was launched as a conversion worker.
  public static func runWorkerIfRequested(arguments: [String] = CommandLine.arguments) -> Int32? {
    guard arguments.count > 1, arguments[1] == workerArgument else { return nil }
    guard arguments.count == 4 else {
      writeWorkerError("usage: <executable> \(workerArgument) INPUT.GPR OUTPUT.DNG\n")
      return 64
    }
    do {
      try GprTools.convert(gprFile: arguments[2], toDNG: arguments[3])
      return 0
    } catch {
      writeWorkerError("GPR conversion failed: \(error)\n")
      return 1
    }
  }

  private static func runWorker(source: URL, destination: URL) throws {
    let process = Process()
    process.executableURL = try workerExecutable()
    process.arguments = [source.path, destination.path]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    let errors = Pipe()
    process.standardError = errors
    try process.run()
    process.waitUntilExit()
    guard process.terminationReason == .exit, process.terminationStatus == 0 else {
      let detail = String(
        data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
      )?.trimmingCharacters(in: .whitespacesAndNewlines)
      throw DNGCacheError.workerFailed(
        status: process.terminationStatus,
        detail: detail.flatMap { $0.isEmpty ? nil : $0 })
    }
  }

  private static func workerExecutable() throws -> URL {
    let fileManager = FileManager.default
    let current = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let executableDirectory = current.deletingLastPathComponent()
    let workingDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
    // Never use the current UI executable as a conversion process: launching it
    // can initialize the application and briefly create another window before
    // argument dispatch runs. The dedicated command-line helper has no UI.
    let candidates = [
      executableDirectory.appendingPathComponent("gopro-gpr-worker"),
      executableDirectory.deletingLastPathComponent().appendingPathComponent("gopro-gpr-worker"),
      workingDirectory.appendingPathComponent(".build/out/Products/Debug/gopro-gpr-worker"),
      workingDirectory.appendingPathComponent(".build/out/Products/Release/gopro-gpr-worker"),
      workingDirectory.appendingPathComponent(".build/debug/gopro-gpr-worker"),
      workingDirectory.appendingPathComponent(".build/release/gopro-gpr-worker"),
    ]
    if let worker = candidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) }) {
      return worker
    }
    throw DNGCacheError.workerNotFound(candidates.map(\.path).joined(separator: ", "))
  }

  private static func writeWorkerError(_ text: String) {
    try? FileHandle.standardError.write(contentsOf: Data(text.utf8))
  }

  private static func isValid(
    destination: URL, metadata: URL, fingerprint: Fingerprint
  ) -> Bool {
    guard isNonemptyFile(destination),
      let cachedFingerprint = try? JSONDecoder().decode(
        Fingerprint.self, from: Data(contentsOf: metadata)),
      cachedFingerprint == fingerprint
    else { return false }
    return true
  }

  private static func isRecoverable(
    destination: URL, metadata: URL, fingerprint: Fingerprint
  ) -> Bool {
    // Only a missing sidecar represents the narrow restart window after the DNG
    // move. Existing but mismatched/corrupt metadata must force reconversion.
    guard !FileManager.default.fileExists(atPath: metadata.path),
      isNonemptyFile(destination),
      let values = try? destination.resourceValues(forKeys: [.contentModificationDateKey]),
      let destinationModificationTime = values.contentModificationDate?.timeIntervalSince1970
    else { return false }
    // A cached DNG older than its source may belong to an earlier source version.
    return destinationModificationTime >= fingerprint.sourceModificationTime
  }

  private static func isNonemptyFile(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map({ $0 > 0 }) == true
  }

  private static func write(fingerprint: Fingerprint, to metadata: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(fingerprint).write(to: metadata, options: .atomic)
  }

  private static func fingerprint(for source: URL) throws -> Fingerprint {
    let values = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    return Fingerprint(
      schemaVersion: 1,
      sourceSize: Int64(values.fileSize ?? 0),
      sourceModificationTime: values.contentModificationDate?.timeIntervalSince1970 ?? 0)
  }
}

public enum DNGCacheError: Error, CustomStringConvertible {
  case workerNotFound(String)
  case workerFailed(status: Int32, detail: String?)

  public var description: String {
    switch self {
    case .workerNotFound(let path):
      return "GPR worker executable was not found at \(path)"
    case .workerFailed(let status, let detail):
      if let detail { return "GPR worker failed (status \(status)): \(detail)" }
      return "GPR worker failed (status \(status))"
    }
  }
}
