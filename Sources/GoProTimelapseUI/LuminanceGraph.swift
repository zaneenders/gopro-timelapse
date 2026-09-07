import Chroma
import GoProTimelapseCore

struct LuminanceGraph: PrimitiveBlock {
  var samples: [LuminanceSample]
  var baseline: [Double]
  var correction: [Double]
  var selectedFrame: Int
  var theme: ChromaTheme

  func sizeThatFits(_ proposal: Size, context: RenderContext) -> Size { proposal }
  var expandsHorizontally: Bool { true }

  func draw(into drawList: inout DrawList, in rect: Rect, context: RenderContext) {
    drawList.fillRect(rect, color: theme.surface)
    drawList.strokeRect(rect, width: 1, color: theme.border)
    guard samples.count > 1 else { return }
    let all = samples.map(\.medianLogLuminance) + baseline
    guard let minimum = all.min(), let maximum = all.max() else { return }
    let span = max(0.25, maximum - minimum)
    func point(_ index: Int, _ value: Double) -> Point {
      Point(
        x: rect.minX + Float(index) / Float(samples.count - 1) * rect.size.width,
        y: rect.maxY - Float((value - minimum) / span) * rect.size.height)
    }
    func drawSeries(_ values: [Double], color: Color) {
      guard values.count == samples.count else { return }
      for index in values.indices {
        let p = point(index, values[index])
        drawList.fillRect(Rect(x: p.x, y: p.y, width: 2, height: 2), color: color)
      }
    }
    drawSeries(samples.map(\.medianLogLuminance), color: theme.secondaryForeground)
    drawSeries(baseline, color: theme.accent)
    if correction.count == samples.count {
      let corrected = zip(samples, correction).map { $0.medianLogLuminance + $1 }
      drawSeries(corrected, color: theme.positive)
    }
    let selectedX = rect.minX
      + Float(min(max(0, selectedFrame), samples.count - 1)) / Float(samples.count - 1) * rect.size.width
    drawList.fillRect(
      Rect(x: selectedX, y: rect.minY, width: 1, height: rect.size.height), color: theme.warning)
  }
}
