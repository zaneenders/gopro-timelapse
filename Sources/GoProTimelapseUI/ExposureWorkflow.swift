import Chroma
import GoProTimelapseCore

extension ExposureWorkflow {
  public static func luminance(of image: ImageResource, frame: Int) -> LuminanceSample {
    luminance(width: image.width, height: image.height, rgba8: image.rgba8, frame: frame)
  }
}
