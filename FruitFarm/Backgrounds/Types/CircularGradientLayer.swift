import Cocoa
import QuartzCore
import Foundation

final class CircularGradientLayer: CALayer, Background {
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
    let t = min(max(elapsedTime / secondsPerColor, 0.0), 1.0)
    let colorCount = fromColors.count

    // Defensive: ensure at least two colors for gradient
    guard colorCount >= 2 else { return }

    var cgColors: [CGColor] = []
    for i in 0..<colorCount {
      let from = fromColors[i]
      let to = toColors[i]
      // Clamp color components to [0,1] to avoid color glitches
      let r = min(max(from.redComponent + (to.redComponent - from.redComponent) * t, 0), 1)
      let g = min(max(from.greenComponent + (to.greenComponent - from.greenComponent) * t, 0), 1)
      let b = min(max(from.blueComponent + (to.blueComponent - from.blueComponent) * t, 0), 1)
      let a = min(max(from.alphaComponent + (to.alphaComponent - from.alphaComponent) * t, 0), 1)
      cgColors.append(NSColor(deviceRed: r, green: g, blue: b, alpha: a).cgColor)
    }

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    // Avoid division by zero if colorCount == 1 (shouldn't happen, but be safe)
    let locations: [CGFloat]
    if colorCount > 1 {
      locations = (0..<colorCount).map { CGFloat($0) / CGFloat(colorCount - 1) }
    } else {
      locations = [0.0]
    }

    // Offset and movement
    let offset = rect.height * 0.021
    let movementRadius = min(rect.width, rect.height) * 0.08
    let rotationPeriod = max(secondsPerColor * 4, 0.01) // avoid division by zero
    // Use total elapsed time for smooth rotation, not just within color step
    let totalElapsed = (CGFloat(colorIndex) * secondsPerColor + elapsedTime)
    let angle = (totalElapsed / rotationPeriod).truncatingRemainder(dividingBy: 1.0) * 2 * .pi

    let center = CGPoint(
      x: rect.midX + movementRadius * cos(angle),
      y: rect.midY - offset + movementRadius * sin(angle)
    )
    let radius = min(rect.width, rect.height) / 2.0

    if let gradient = CGGradient(colorsSpace: colorSpace, colors: cgColors as CFArray, locations: locations) {
      ctx.saveGState()
      // Clip to bounds for safety
      ctx.addRect(rect)
      ctx.clip()
      ctx.drawRadialGradient(
        gradient,
        startCenter: center, startRadius: 0,
        endCenter: center, endRadius: radius,
        options: [.drawsAfterEndLocation, .drawsBeforeStartLocation]
      )
      ctx.restoreGState()
    }
  }

  private func interpolatedGradientColors() -> ([NSColor], [NSColor]) {
    // For a smooth gradient, use all stops, wrapping around
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
