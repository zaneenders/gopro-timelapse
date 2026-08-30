// swift-tools-version: 6.3
import PackageDescription

let package = Package(
  name: "GoProTimelapse",
  platforms: [
    .macOS(.v26)
  ],
  products: [.executable(name: "gopro-timelapse", targets: ["GoProTimelapse"])],
  dependencies: [
    .package(url: "git@github.com:zaneenders/swift-gpr_tools.git", branch: "main"),
    .package(url: "git@github.com:zaneenders/swift-libraw.git", branch: "main"),
  ],
  targets: [
    .executableTarget(
      name: "GoProTimelapse",
      dependencies: [
        .product(name: "GprTools", package: "swift-gpr_tools"),
        .product(name: "Libraw", package: "swift-libraw"),
      ]
    ),
    .testTarget(name: "GoProTimelapseTests", dependencies: ["GoProTimelapse"]),
  ]
)
