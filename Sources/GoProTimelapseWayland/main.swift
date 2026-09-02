import Chroma
import GoProTimelapseUI
import WaylandBackend

@main
@MainActor
struct GoProTimelapseWaylandApp: WaylandApp {
  private let state = TimelapseUIState()

  var title: String { "GoPro Timelapse" }
  var windowSize: Size { Size(width: 1200, height: 800) }
  var minimumRefreshRate: Double { 15 }

  var keyBindings: KeyBindings {
    KeyBindings {
      bind("a", modifiers: .superKey, to: .editing(.selectAll))
      bind("c", modifiers: .superKey, to: .editing(.copy))
      bind("x", modifiers: .superKey, to: .editing(.cut))
      bind("v", modifiers: .superKey, to: .editing(.paste))
      bind(.backspace, to: .editing(.backspace))
      bind(.delete, to: .editing(.deleteForward))
      bind(.leftArrow, to: .editing(.moveCaretLeft))
      bind(.rightArrow, to: .editing(.moveCaretRight))
      bind(.upArrow, to: .editing(.moveCaretUp))
      bind(.downArrow, to: .editing(.moveCaretDown))
      bind(.upArrow, modifiers: .shift, to: .editing(.selectCaretUp))
      bind(.downArrow, modifiers: .shift, to: .editing(.selectCaretDown))
      bind(.home, to: .editing(.moveCaretToStart))
      bind(.end, to: .editing(.moveCaretToEnd))
      bind(.enter, to: .editing(.submit))
      bind(.escape, to: .editing(.endEditing))
      bind(.space, to: .action(.activate))
      bind(.pageUp, to: .navigation(.pageUp))
      bind(.pageDown, to: .navigation(.pageDown))
      bind("k", to: TimelapseBlock.previousFrameCommand)
      bind("j", to: TimelapseBlock.nextFrameCommand)
      bind(.upArrow, modifiers: .superKey, to: TimelapseBlock.firstFrameCommand)
      bind(.downArrow, modifiers: .superKey, to: TimelapseBlock.lastFrameCommand)
    }
  }

  var body: some Block {
    TimelapseBlock(state: state)
      .chromaTheme(.dark)
  }
}
