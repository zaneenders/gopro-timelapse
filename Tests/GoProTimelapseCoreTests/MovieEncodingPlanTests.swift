import Foundation
import GoProTimelapseCore
import Testing

private let movieOutput = URL(fileURLWithPath: "/tmp/movie with spaces.mp4")

private func option(_ name: String, in arguments: [String]) -> String? {
  guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
  return arguments[index + 1]
}

@Test func encodingBackendSelectionRespectsPreferenceAndFallback() {
  let available = "prores_ks prores_videotoolbox hevc_nvenc hevc_videotoolbox"
  #expect(MovieEncodingPlan.proResEncoder(available: available) == .videotoolbox)
  #expect(MovieEncodingPlan.proResEncoder(available: "prores_ks") == .software)
  #expect(MovieEncodingPlan.proResEncoder(available: "") == nil)
  #expect(MovieEncodingPlan.deliveryEncoder(codec: .hevc, available: available) == .videotoolbox)
  #expect(MovieEncodingPlan.deliveryEncoder(codec: .hevc, available: available, preference: [.nvenc]) == .nvenc)
  #expect(MovieEncodingPlan.deliveryEncoder(codec: .h264, available: available) == .software)
  #expect(MovieEncodingPlan.deliveryEncoder(codec: .hevc, available: "") == .software)
}

@Test func proResPlanPreservesProfileFormatsFiltersAndOutputPath() {
  let master = MovieEncodingPlan.masterURL(for: movieOutput)
  #expect(master.lastPathComponent == "movie with spaces.prores.mov")
  for encoder: MovieEncodingPlan.ProResEncoder in [.software, .videotoolbox] {
    let args = MovieEncodingPlan.proResArguments(encoder: encoder, output: master, filter: "scale=1920:-2")
    let format = encoder == .software ? "yuv422p10le" : "p210le"
    #expect(option("-c:v", in: args) == encoder.rawValue)
    #expect(option("-profile:v", in: args) == "3")
    #expect(option("-pix_fmt", in: args) == format)
    #expect(option("-vf", in: args) == "scale=1920:-2,format=\(format)")
    #expect(option("-color_range", in: args) == "tv")
    #expect(option("-allow_sw", in: args) == (encoder == .videotoolbox ? "0" : nil))
    #expect(args.last == master.path)
  }
}

@Test func deliveryPlanCoversEveryCodecAndBackend() {
  for codec: DeliveryCodec in [.hevc, .h264] {
    for encoder: DeliveryEncoder in [.software, .videotoolbox, .nvenc] {
      let args = MovieEncodingPlan.deliveryArguments(
        codec: codec, encoder: encoder, output: movieOutput, quality: 18, bitrateMbps: 45)
      let name =
        encoder == .software
        ? (codec == .hevc ? "libx265" : "libx264") : "\(codec.rawValue)_\(encoder.rawValue)"
      #expect(option("-c:v", in: args) == name)
      #expect(
        option("-pix_fmt", in: args) == (codec == .h264 ? "yuv420p" : encoder == .software ? "yuv420p10le" : "p010le"))
      #expect(option("-tag:v", in: args) == (codec == .hevc ? "hvc1" : nil))
      #expect(option("-color_range", in: args) == "tv")
      #expect(option("-colorspace", in: args) == "bt709")
      #expect(option("-movflags", in: args) == "+faststart")
      #expect(args.last == movieOutput.path)
      switch encoder {
      case .software:
        #expect(option("-crf", in: args) == "18")
        #expect(option("-preset", in: args) == "slow")
      case .nvenc:
        #expect(option("-cq", in: args) == "18")
        #expect(option("-preset", in: args) == "p6")
      case .videotoolbox:
        #expect(option("-b:v", in: args) == "45M")
        #expect(option("-bufsize", in: args) == "90M")
      }
    }
  }
}

@Test func uiEncodingChoicesRemainExplicit() {
  let args = MovieEncodingPlan.deliveryArguments(
    codec: .hevc, encoder: .software, output: movieOutput,
    softwarePreset: "medium", explicitVideoRange: false, explicitMain10Profile: true)
  #expect(option("-preset", in: args) == "medium")
  #expect(option("-color_range", in: args) == nil)
  #expect(option("-profile:v", in: args) == nil)
  let hardware = MovieEncodingPlan.deliveryArguments(
    codec: .hevc, encoder: .nvenc, output: movieOutput, explicitMain10Profile: true)
  #expect(option("-profile:v", in: hardware) == "main10")
  let master = MovieEncodingPlan.proResArguments(
    encoder: .software, output: movieOutput, explicitVideoRange: false)
  #expect(option("-color_range", in: master) == nil)
}

@Test func sharedRAWDevelopmentPropagatesMissingSourceErrors() {
  let missing = URL(fileURLWithPath: "/tmp/\(UUID().uuidString).gpr")
  let settings = RAWDevelopmentSettings(maximumWidth: 1280, denoise: 0.4)
  #expect(throws: (any Error).self) {
    try RAWDeveloper.developRGB(source: missing, grade: Grade(), settings: settings)
  }
  #expect(throws: (any Error).self) {
    try RAWDeveloper.developRGB16(source: missing, grade: Grade(), settings: settings)
  }
}
