import Foundation
import GoProTimelapseCore

let status =
  DNGCache.runWorkerIfRequested(
    arguments: [CommandLine.arguments[0], "--gpr-conversion-worker"]
      + Array(CommandLine.arguments.dropFirst())) ?? 64
exit(status)
