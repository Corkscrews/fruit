import Cocoa
import QuartzCore
import Foundation

final class SolidLayer: CALayer, Background {
  // MARK: - Constants
  private static let colorArray: [NSColor] = [
    NSColor(srgbRed: 67/255, green: 156/255, blue: 214/255, alpha: 1), // BLUE
    NSColor(srgbRed: 139/255, green: 69/255, blue: 147/255, alpha: 1), // PURPLE
    NSColor(srgbRed: 207/255, green: 72/255, blue: 69/255, alpha: 1), // RED
    NSColor(srgbRed: 231/255, green: 135/255, blue: 59/255, alpha: 1), // ORANGE
    NSColor(srgbRed: 243/255, green: 185/255, blue: 75/255, alpha: 1), // YELLOW
    NSColor(srgbRed: 120/255, green: 184/255, blue: 86/255, alpha: 1)  // GREEN
  ]

  // MARK: - Properties
  private var colorIndex: Int = 0
  private var elapsedTime: CGFloat = 0
  private let secondsPerColor: CGFloat = 10.0

  // MARK: - Init
  init(frame: NSRect, fruit: Fruit) {
    super.init()
    self.frame = frame
    self.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
//    config(fruit: fruit)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override init(layer: Any) {
    super.init(layer: layer)
    self.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
  }

  func update(frame: NSRect, fruit: Fruit) {
    self.frame = frame
    setNeedsDisplay()
  }

  func config(fruit: Fruit) {
    // No-op for solid square
    setNeedsDisplay()
  }

  func update(deltaTime: CGFloat) {
    elapsedTime += deltaTime
    if elapsedTime >= secondsPerColor {
      elapsedTime = 0
      colorIndex = (colorIndex + 1) % Self.colorArray.count
    }
    setNeedsDisplay()
  }

  // MARK: - Drawing
  override func draw(in ctx: CGContext) {
    let rect = bounds
    ctx.setFillColor(interpolatedColor().cgColor)
    ctx.fill(rect)
  }

  private func interpolatedColor() -> NSColor {
    let fromIndex = colorIndex
    let toIndex = (colorIndex + 1) % Self.colorArray.count
    guard let fromColor = Self.colorArray[fromIndex].usingColorSpace(.deviceRGB),
          let toColor = Self.colorArray[toIndex].usingColorSpace(.deviceRGB) else {
      return Self.colorArray[fromIndex]
    }
    let colorTransitionProgress = min(elapsedTime / secondsPerColor, 1.0)
    let red = fromColor.redComponent + (toColor.redComponent - fromColor.redComponent) * colorTransitionProgress
    let green = fromColor.greenComponent + (toColor.greenComponent - fromColor.greenComponent) * colorTransitionProgress
    let blue = fromColor.blueComponent + (toColor.blueComponent - fromColor.blueComponent) * colorTransitionProgress
    let alpha = fromColor.alphaComponent + (toColor.alphaComponent - fromColor.alphaComponent) * colorTransitionProgress
    return NSColor(deviceRed: red, green: green, blue: blue, alpha: alpha)
  }

}
