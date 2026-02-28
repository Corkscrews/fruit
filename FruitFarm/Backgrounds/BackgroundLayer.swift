import Cocoa
import QuartzCore

/// BackgroundLayer is a CAShapeLayer subclass that draws a black background using a given NSBezierPath.
final class BackgroundLayer: CAShapeLayer, Background {
  init(frame: CGRect) {
    super.init()
    self.frame = frame
    self.allowsEdgeAntialiasing = true
    updateBezierPath()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    self.allowsEdgeAntialiasing = true
    updateBezierPath()
  }

  override init(layer: Any) {
    super.init(layer: layer)
    self.allowsEdgeAntialiasing = true
    updateBezierPath()
  }

  func config(fruit: Fruit) { }

  func update(deltaTime: CGFloat) { }

  func update(frame: NSRect, fruit: Fruit) {
    self.frame = frame
    updateBezierPath()
  }

  private func updateBezierPath() {
    let foreground = {
      let foreground = NSBezierPath()
      foreground.move(to: NSPoint(x: 0, y: 0))
      foreground.line(to: NSPoint(x: frame.size.width, y: 0))
      foreground.line(to: NSPoint(x: frame.size.width, y: frame.size.height))
      foreground.line(to: NSPoint(x: 0, y: frame.size.height))
      foreground.close()
      return foreground
    }()
    self.path = foreground.quartzPath
  }
}
