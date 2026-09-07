import Libraw

extension Grade {
  /// The single mapping used by CLI rendering, UI previews, and UI export.
  /// LibRaw uses zero to mean unspecified white balance.
  public var librawGrade: LibrawGrade {
    LibrawGrade(
      exposure: exposure, temperature: temperature ?? 0, tint: tint ?? 0,
      contrast: contrast, saturation: saturation, vibrance: vibrance,
      shadows: shadows, highlights: highlights)
  }

  /// Lossless, deterministic identity covering every develop control, including
  /// unspecified white balance. Avoid rounded values that alias nearby edits.
  public var previewIdentity: String {
    [Optional(exposure), temperature, tint, contrast, saturation, vibrance, shadows, highlights]
      .map { $0.map { String($0.bitPattern, radix: 16) } ?? "nil" }
      .joined(separator: "-")
  }
}
