import Foundation
import GoProTimelapseCore
import Synchronization
import Testing

private let shellExecutable = URL(fileURLWithPath: "/bin/sh")

@Test func processRunnerCapturesOutputAndClosedInput() async throws {
  let result = try await ProcessRunner.run(
    executable: shellExecutable,
    arguments: ["-c", "if read value; then exit 1; fi; printf hello; printf diagnostic >&2"])
  #expect(result.status == 0)
  #expect(String(decoding: result.stdout, as: UTF8.self) == "hello")
  #expect(String(decoding: result.stderr, as: UTF8.self) == "diagnostic")
}

@Test func processRunnerDrainsLargeStreamsAndBoundsCapture() async throws {
  let totals = Mutex((stdout: 0, stderr: 0))
  let result = try await ProcessRunner.run(
    executable: shellExecutable,
    arguments: ["-c", "i=0; while [ $i -lt 20000 ]; do printf 0123456789; printf abcdefghij >&2; i=$((i+1)); done"],
    captureLimit: 128
  ) { stream, data in
    totals.withLock {
      if stream == .stdout { $0.stdout += data.count } else { $0.stderr += data.count }
    }
  }
  #expect(result.stdout.count == 128)
  #expect(result.stderr.count == 128)
  #expect(totals.withLock { $0.stdout } == 200000)
  #expect(totals.withLock { $0.stderr } == 200000)
  #expect(String(decoding: result.stderr.suffix(10), as: UTF8.self) == "abcdefghij")
}

@Test func processRunnerReportsNonzeroExitWithDiagnostics() async throws {
  do {
    _ = try await ProcessRunner.run(
      executable: shellExecutable, arguments: ["-c", "printf broken >&2; exit 7"])
    Issue.record("Expected nonzero exit to throw")
  } catch let failure as ProcessFailure {
    #expect(failure.result.status == 7)
    #expect(String(decoding: failure.result.stderr, as: UTF8.self) == "broken")
  }
}

@Test func processRunnerLaunchFailureDoesNotHang() async {
  do {
    _ = try await ProcessRunner.run(
      executable: URL(fileURLWithPath: "/missing/\(UUID().uuidString)"), arguments: [])
    Issue.record("Expected launch failure")
  } catch {
    #expect(!(error is CancellationError))
  }
}

@Test func processRunnerCancellationTerminatesUncooperativeChild() async throws {
  let ready = Mutex(false)
  let task = Task {
    try await ProcessRunner.run(
      executable: shellExecutable, arguments: ["-c", "trap '' TERM; printf ready; while :; do :; done"]
    ) { _, _ in ready.withLock { $0 = true } }
  }
  for _ in 0..<200 {
    if ready.withLock({ $0 }) { break }
    try await Task.sleep(for: .milliseconds(10))
  }
  #expect(ready.withLock { $0 })
  let start = ContinuousClock.now
  task.cancel()
  do {
    _ = try await task.value
    Issue.record("Expected cancellation")
  } catch {
    #expect(error is CancellationError)
  }
  #expect(start.duration(to: .now) < .seconds(3))
}

@Test func processRunnerHonorsCancellationBeforeLaunch() async {
  let task = Task {
    withUnsafeCurrentTask { $0?.cancel() }
    return try await ProcessRunner.run(executable: shellExecutable, arguments: ["-c", "exit 99"])
  }
  do {
    _ = try await task.value
    Issue.record("Expected cancellation")
  } catch {
    #expect(error is CancellationError)
  }
}

@Test func processRunnerResolvesExecutablesAndSupportsZeroCapture() async throws {
  #expect(ProcessRunner.executableURL("sh", searchPath: "/bin") == shellExecutable)
  #expect(ProcessRunner.executableURL("sh", searchPath: "/missing", additionalDirectories: ["/bin"]) == shellExecutable)
  #expect(ProcessRunner.executableURL("missing-\(UUID().uuidString)", searchPath: "/bin") == nil)
  let result = try await ProcessRunner.run(
    executable: shellExecutable, arguments: ["-c", "printf ignored"], captureLimit: 0)
  #expect(result.stdout.isEmpty)
}
