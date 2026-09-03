// swift-tools-version: 6.3
import PackageDescription

var products: [Product] = [
  .executable(name: "gopro-timelapse", targets: ["GoProTimelapse"]),
  .library(name: "GoProTimelapseCore", targets: ["GoProTimelapseCore"]),
  .library(name: "GoProTimelapseUI", targets: ["GoProTimelapseUI"]),
]

var chromaTraits: Set<Package.Dependency.Trait> = []
var targets: [Target] = [
  .target(
    name: "GoProTimelapseCore",
    dependencies: [
      .product(name: "GprTools", package: "swift-gpr_tools"),
      .product(name: "Libraw", package: "swift-libraw"),
    ]
  ),
  .executableTarget(
    name: "GoProTimelapse",
    dependencies: [
      "GoProTimelapseCore",
      .product(name: "GprTools", package: "swift-gpr_tools"),
      .product(name: "Libraw", package: "swift-libraw"),
    ]
  ),
  .target(
    name: "GoProTimelapseUI",
    dependencies: [
      "GoProTimelapseCore",
      .product(name: "Chroma", package: "chroma"),
      .product(name: "GprTools", package: "swift-gpr_tools"),
      .product(name: "Libraw", package: "swift-libraw"),
    ]
  ),
  .testTarget(name: "GoProTimelapseCoreTests", dependencies: ["GoProTimelapseCore"]),
  .testTarget(name: "GoProTimelapseTests", dependencies: ["GoProTimelapse"]),
  .testTarget(
    name: "GoProTimelapseUITests",
    dependencies: ["GoProTimelapseUI", "GoProTimelapseCore"]),
]

#if os(macOS)
chromaTraits.insert("MetalBackend")
products.append(.executable(name: "gopro-timelapse-mac", targets: ["GoProTimelapseMac"]))
targets.append(
  .executableTarget(
    name: "GoProTimelapseMac",
    dependencies: [
      "GoProTimelapseUI",
      .product(name: "Chroma", package: "chroma"),
      .product(name: "MetalBackend", package: "chroma"),
    ]
  )
)
#elseif os(Linux)
chromaTraits.insert("WaylandBackend")
products.append(.executable(name: "gopro-timelapse-wayland", targets: ["GoProTimelapseWayland"]))
targets.append(
  .executableTarget(
    name: "GoProTimelapseWayland",
    dependencies: [
      "GoProTimelapseUI",
      .product(name: "Chroma", package: "chroma"),
      .product(name: "WaylandBackend", package: "chroma"),
    ]
  )
)
#endif

let package = Package(
  name: "GoProTimelapse",
  platforms: [
    .macOS(.v26)
  ],
  products: products,
  dependencies: [
    .package(
      url: "https://github.com/zaneenders/chroma.git",
      branch: "display-images",
      traits: chromaTraits
    ),
    .package(url: "git@github.com:zaneenders/swift-gpr_tools.git", branch: "main"),
    .package(url: "https://github.com/zaneenders/swift-libraw.git", branch: "main"),
  ],
  targets: targets
)
