import Cocoa
import QuartzCore

public class FruitAnimator {
  private var lineLayers: [CAShapeLayer]
  private var colorsPath: [NSBezierPath]
  private var visibleLinesCount: Int
  private var heightOfBars: CGFloat
  private var totalLines: Int
  private var onLoop: (() -> Void)?

  public init(
    lineLayers: [CAShapeLayer], 
    colorsPath: [NSBezierPath], 
    visibleLinesCount: Int, 
    heightOfBars: CGFloat, 
    totalLines: Int, 
    onLoop: (() -> Void)? = nil
  ) {
    self.lineLayers = lineLayers
    self.colorsPath = colorsPath
    self.visibleLinesCount = visibleLinesCount
    self.heightOfBars = heightOfBars
    self.totalLines = totalLines
    self.onLoop = onLoop
  }

  public func startA(
    _ layer: CAShapeLayer, 
    from: NSBezierPath, 
    to: NSBezierPath, 
    duration: Double
  ) {
    let animation = CABasicAnimation(keyPath: "path")
    animation.duration = duration
    animation.fromValue = from.quartzPath
    animation.toValue = to.quartzPath
    layer.path = to.quartzPath
    layer.add(animation, forKey: "path")
  }

  public func add() {
    let sm = TransformHelpers.translationTransform(
      NSPoint(x: 0, y: heightOfBars * CGFloat(visibleLinesCount))
    )
    let delayInSeconds = 3.0 * Double(visibleLinesCount)
    let popTime = DispatchTime.now() + delayInSeconds
    for i in 0...totalLines {
      let maskLineLayer = lineLayers[i]
      let from = colorsPath[i]
      let to = colorsPath[i].copy() as! NSBezierPath
      to.transform(using: sm as AffineTransform)
      if i == totalLines {
        startA(maskLineLayer, from: from, to: to, duration: delayInSeconds)
        DispatchQueue.main.asyncAfter(deadline: popTime) { [weak self] in
          self?.onLoop?()
        }
        return
      }
      startA(maskLineLayer, from: from, to: to, duration: delayInSeconds)
    }
  }
}
