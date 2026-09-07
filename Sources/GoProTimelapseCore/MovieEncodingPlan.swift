import Foundation

public enum DeliveryCodec: String, Sendable { case hevc, h264 }
public enum DeliveryEncoder: String, Sendable { case software, videotoolbox, nvenc }

/// Pure FFmpeg argument construction, independent of process execution and UI.
public enum MovieEncodingPlan {
  public enum ProResEncoder: String, Sendable {
    case videotoolbox = "prores_videotoolbox"
    case software = "prores_ks"

    public var description: String {
      self == .videotoolbox ? "VideoToolbox ProRes 422 HQ" : "software ProRes 422 HQ"
    }
  }

  public static func proResEncoder(available: String) -> ProResEncoder? {
    if available.contains(ProResEncoder.videotoolbox.rawValue) { return .videotoolbox }
    if available.contains(ProResEncoder.software.rawValue) { return .software }
    return nil
  }

  /// Callers choose backend preference; this does not claim hardware is usable
  /// merely because FFmpeg was compiled with an encoder.
  public static func deliveryEncoder(
    codec: DeliveryCodec, available: String,
    preference: [DeliveryEncoder] = [.videotoolbox, .nvenc]
  ) -> DeliveryEncoder {
    preference.first {
      $0 == .software || available.contains("\(codec.rawValue)_\($0.rawValue)")
    } ?? .software
  }

  public static func masterURL(for output: URL) -> URL {
    output.deletingPathExtension().appendingPathExtension("prores.mov")
  }

  public static func proResArguments(
    encoder: ProResEncoder, output: URL, filter: String? = nil,
    explicitVideoRange: Bool = true
  ) -> [String] {
    let format = encoder == .videotoolbox ? "p210le" : "yuv422p10le"
    let filters = [filter, "format=\(format)"].compactMap { $0 }.joined(separator: ",")
    var args = ["-vf", filters, "-c:v", encoder.rawValue, "-profile:v", "3"]
    if encoder == .videotoolbox { args += ["-allow_sw", "0"] }
    args += ["-pix_fmt", format] + colorArguments(explicitVideoRange: explicitVideoRange)
    return args + [output.path]
  }

  public static func deliveryArguments(
    codec: DeliveryCodec, encoder: DeliveryEncoder, output: URL,
    quality: Int = 20, bitrateMbps: Int = 30, softwarePreset: String = "slow",
    explicitVideoRange: Bool = true, explicitMain10Profile: Bool = false
  ) -> [String] {
    var args: [String]
    switch encoder {
    case .videotoolbox:
      args = [
        "-c:v", "\(codec.rawValue)_videotoolbox", "-b:v", "\(bitrateMbps)M",
        "-maxrate", "\(bitrateMbps)M", "-bufsize", "\(bitrateMbps * 2)M", "-allow_sw", "0",
      ]
    case .nvenc:
      args = ["-c:v", "\(codec.rawValue)_nvenc", "-preset", "p6", "-rc", "vbr", "-cq", String(quality)]
    case .software:
      args = [
        "-c:v", codec == .hevc ? "libx265" : "libx264",
        "-preset", softwarePreset, "-crf", String(quality),
      ]
    }
    if explicitMain10Profile && codec == .hevc && encoder != .software {
      args += ["-profile:v", "main10"]
    }
    let format = codec == .h264 ? "yuv420p" : encoder == .software ? "yuv420p10le" : "p010le"
    args += ["-pix_fmt", format] + colorArguments(explicitVideoRange: explicitVideoRange)
    if codec == .hevc { args += ["-tag:v", "hvc1"] }
    return args + ["-movflags", "+faststart", output.path]
  }

  private static func colorArguments(explicitVideoRange: Bool) -> [String] {
    (explicitVideoRange ? ["-color_range", "tv"] : [])
      + ["-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709"]
  }
}
