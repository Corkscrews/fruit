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
  private let secondsPerRotation: CGFloat = 20.0

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
    let colorCount = Self.colorArray.count
    guard colorCount >= 2 else { return }

    // Use a continuous time base for animation, so it never "resets"
    // This avoids the colorIndex/elapsedTime step logic from causing jumps.
    // We'll use a single time accumulator for both color interpolation and rotation.
    // For this, we need to track total time since layer creation.
    // We'll use CACurrentMediaTime() as a time base.
    // If you want to use a custom time base, you can inject it.

    // Store the initial time on first draw
    struct TimeHolder {
      static var initialTime: CFTimeInterval = CACurrentMediaTime()
    }
    let now = CACurrentMediaTime()
    let totalElapsed = CGFloat(now - TimeHolder.initialTime)

    // Color interpolation: smoothly cycle through all colors
    let secondsPerColor = self.secondsPerColor
    let colorPhase = (totalElapsed / secondsPerColor).truncatingRemainder(dividingBy: CGFloat(colorCount))
    let baseColorIndex = Int(floor(colorPhase)) % colorCount
    let t = colorPhase - floor(colorPhase)

    // Build gradient colors by interpolating between each color and the next
    var cgColors: [CGColor] = []
    for i in 0..<colorCount {
      let fromIdx = (baseColorIndex + i) % colorCount
      let toIdx = (fromIdx + 1) % colorCount
      let from = Self.colorArray[fromIdx]
      let to = Self.colorArray[toIdx]
      let r = from.redComponent + (to.redComponent - from.redComponent) * t
      let g = from.greenComponent + (to.greenComponent - from.greenComponent) * t
      let b = from.blueComponent + (to.blueComponent - from.blueComponent) * t
      let a = from.alphaComponent + (to.alphaComponent - from.alphaComponent) * t
      cgColors.append(NSColor(deviceRed: r, green: g, blue: b, alpha: a).cgColor)
    }

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let locations: [CGFloat] = (0..<colorCount).map { CGFloat($0) / CGFloat(colorCount - 1) }

    // Offset and movement
    let offset = rect.height * 0.021
    let movementRadius = min(rect.width, rect.height) * 0.08
    let rotationPeriod = max(secondsPerColor * secondsPerRotation, 0.01)
    let angle = (totalElapsed / rotationPeriod).truncatingRemainder(dividingBy: 1.0) * 2 * .pi

    let center = CGPoint(
      x: rect.midX + movementRadius * cos(angle),
      y: rect.midY - offset + movementRadius * sin(angle)
    )
    let radius = min(rect.width, rect.height) / 2.0

    if let gradient = CGGradient(
      colorsSpace: colorSpace,
      colors: cgColors as CFArray,
      locations: locations
    ) {
      ctx.saveGState()
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
