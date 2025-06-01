import Cocoa
import QuartzCore
import Foundation

final class LinearGradientLayer: CALayer, Background {
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
  private let secondsPerColor: CGFloat = 2.0

  // MARK: - Init
  init(frame: NSRect, fruit: Fruit) {
    super.init()
    self.frame = frame
    self.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
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
    let (fromColors, toColors) = interpolatedGradientColors()
    let t = min(elapsedTime / secondsPerColor, 1.0)
    let colorCount = fromColors.count
    var cgColors: [CGColor] = []
    for i in 0..<colorCount {
      let from = fromColors[i]
      let to = toColors[i]
      let r = from.redComponent + (to.redComponent - from.redComponent) * t
      let g = from.greenComponent + (to.greenComponent - from.greenComponent) * t
      let b = from.blueComponent + (to.blueComponent - from.blueComponent) * t
      let a = from.alphaComponent + (to.alphaComponent - from.alphaComponent) * t
      cgColors.append(NSColor(deviceRed: r, green: g, blue: b, alpha: a).cgColor)
    }
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let locations: [CGFloat] = (0..<colorCount).map { CGFloat($0) / CGFloat(colorCount - 1) }
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: cgColors as CFArray, locations: locations) {
      ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
    }
  }

  private func interpolatedGradientColors() -> ([NSColor], [NSColor]) {
    // For a smooth gradient, use 3 stops: current, next, and the one after (for wrap-around)
    let colorCount = Self.colorArray.count
    var fromColors: [NSColor] = []
    var toColors: [NSColor] = []
    for i in 0..<colorCount {
      let fromIdx = (colorIndex + i) % colorCount
      let toIdx = (colorIndex + i + 1) % colorCount
      fromColors.append(Self.colorArray[fromIdx])
      toColors.append(Self.colorArray[toIdx])
    }
    return (fromColors, toColors)
  }
}
