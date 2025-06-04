import Cocoa
import QuartzCore
import Foundation

/// A layer that renders a circular gradient background with smooth color transitions and orbital movement.
/// The gradient rotates around the fruit's center point, creating a dynamic and engaging visual effect.
final class CircularGradientLayer: CALayer, Background {
  // MARK: - Color Configuration

  /// The array of colors used in the gradient animation.
  /// Colors are defined in sRGB color space for consistent color reproduction.
  private let colorArray: [NSColor] = [
    NSColor(srgbRed: 67/255, green: 156/255, blue: 214/255, alpha: 1), // BLUE
    NSColor(srgbRed: 139/255, green: 69/255, blue: 147/255, alpha: 1), // PURPLE
    NSColor(srgbRed: 207/255, green: 72/255, blue: 69/255, alpha: 1), // RED
    NSColor(srgbRed: 231/255, green: 135/255, blue: 59/255, alpha: 1), // ORANGE
    NSColor(srgbRed: 243/255, green: 185/255, blue: 75/255, alpha: 1), // YELLOW
    NSColor(srgbRed: 120/255, green: 184/255, blue: 86/255, alpha: 1)  // GREEN
  ]

  /// Reusable array for CGColors to avoid allocation during drawing.
  /// This array is cleared and reused on each draw call.
  private var cgColors: [CGColor] = []

  /// Cache for all possible color combinations used in the gradient.
  /// The dictionary is keyed by the starting color index and contains tuples of
  /// (fromColors, toColors) arrays for smooth transitions.
  private lazy var colorCombinations: [Int: ([NSColor], [NSColor])] = {
    let colorCount = colorArray.count
    var combinations: [Int: ([NSColor], [NSColor])] = [:]
    combinations.reserveCapacity(colorCount)

    for startColorIndex in 0..<colorCount {
      var fromColors: [NSColor] = []
      fromColors.reserveCapacity(colorCount)
      var toColors: [NSColor] = []
      toColors.reserveCapacity(colorCount)

      for endColorIndex in 0..<colorCount {
        let fromIdx = (startColorIndex + endColorIndex) % colorCount
        let toIdx = (startColorIndex + endColorIndex + 1) % colorCount
        fromColors.append(colorArray[fromIdx])
        toColors.append(colorArray[toIdx])
      }

      combinations[startColorIndex] = (fromColors, toColors)
    }
    return combinations
  }()

  // MARK: - Gradient Configuration

  /// The color space used for gradient rendering.
  /// Using device RGB color space for optimal performance.
  private let gradientColorSpace = CGColorSpaceCreateDeviceRGB()

  /// Pre-calculated gradient locations for consistent color distribution.
  /// Locations are evenly spaced between 0 and 1.
  private lazy var gradientLocations: [CGFloat] = (0..<colorArray.count).map {
    CGFloat($0) / CGFloat(colorArray.count - 1)
  }

  // MARK: - Animation Properties

  /// The current index in the color array.
  private var colorIndex: Int = 0

  /// Time elapsed since the last color transition.
  private var elapsedTime: CGFloat = 0

  /// Total elapsed time used for continuous rotation calculation.
  private var continuousTotalElapsedTimeForRotation: CGFloat = 0

  /// The maximum dimension of the current fruit.
  private var currentFruitMaxDimension: CGFloat = 50.0

  /// Duration for each color transition in seconds.
  private let secondsPerColor: CGFloat = 2.0

  // MARK: - Initialization

  /// Initializes a new circular gradient layer with the specified frame and fruit.
  /// - Parameters:
  ///   - frame: The frame rectangle for the layer.
  ///   - fruit: The fruit object to determine the gradient's dimensions and positioning.
  init(frame: NSRect, fruit: Fruit) {
    self.currentFruitMaxDimension = fruit.maxDimen()
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

  // MARK: - Public Methods

  /// Updates the layer's frame and fruit dimensions.
  /// - Parameters:
  ///   - frame: The new frame rectangle.
  ///   - fruit: The fruit object containing updated dimensions.
  func update(frame: NSRect, fruit: Fruit) {
    self.frame = frame
    self.currentFruitMaxDimension = fruit.maxDimen()
    setNeedsDisplay()
  }

  /// Configures the layer with a new fruit object.
  /// - Parameter fruit: The fruit object to configure the layer with.
  func config(fruit: Fruit) {
    self.currentFruitMaxDimension = fruit.maxDimen()
    setNeedsDisplay()
  }

  /// Updates the animation state with the elapsed time since the last update.
  /// - Parameter deltaTime: The time elapsed since the last update in seconds.
  func update(deltaTime: CGFloat) {
    continuousTotalElapsedTimeForRotation += deltaTime

    elapsedTime += deltaTime
    while elapsedTime >= secondsPerColor {
      elapsedTime -= secondsPerColor
      colorIndex = (colorIndex + 1) % colorArray.count
    }
    setNeedsDisplay()
  }

  // MARK: - Drawing

  override func draw(in ctx: CGContext) {
    let rect = bounds

    // Get pre-calculated color combinations for the current index
    guard let (fromColors, toColors) = colorCombinations[colorIndex] else { return }

    // Calculate the current transition progress
    let colorTransitionProgress = min(max(elapsedTime / secondsPerColor, 0.0), 1.0)
    let colorCount = fromColors.count

    // Ensure we have enough colors for a gradient
    guard colorCount >= 2 else { return }

    // Reuse the CGColors array
    self.cgColors.removeAll(keepingCapacity: true)

    // Interpolate colors based on the current transition progress
    for index in 0..<colorCount {
      let fromColor = fromColors[index]
      let toColor = toColors[index]

      // Clamp color components to [0,1] to avoid color glitches
      let red = min(max(fromColor.redComponent + (toColor.redComponent - fromColor.redComponent) * colorTransitionProgress, 0), 1)
      let green = min(max(fromColor.greenComponent + (toColor.greenComponent - fromColor.greenComponent) * colorTransitionProgress, 0), 1)
      let blue = min(max(fromColor.blueComponent + (toColor.blueComponent - fromColor.blueComponent) * colorTransitionProgress, 0), 1)
      let alpha = min(max(fromColor.alphaComponent + (toColor.alphaComponent - fromColor.alphaComponent) * colorTransitionProgress, 0), 1)

      // Create CGColor directly from components
      self.cgColors.append(CGColor(colorSpace: gradientColorSpace, components: [red, green, blue, alpha])!)
    }

    // Calculate gradient center position and movement
    let offset = rect.height * 0.021
    let movementRadius = self.currentFruitMaxDimension * 0.75
    let rotationPeriod = max(secondsPerColor * 16, 0.01)

    // Calculate rotation angle using continuous time
    let angle = (continuousTotalElapsedTimeForRotation / rotationPeriod)
      .truncatingRemainder(dividingBy: 1.0) * 2 * .pi

    // Calculate gradient center point
    let center = CGPoint(
      x: rect.midX + movementRadius * cos(angle),
      y: rect.midY - offset + movementRadius * sin(angle)
    )

    // Calculate gradient radius
    let radius = min(rect.width, rect.height) / 2.0

    // Create and draw the gradient
    if let gradient = CGGradient(
      colorsSpace: gradientColorSpace,
      colors: self.cgColors as CFArray,
      locations: gradientLocations
    ) {
      ctx.saveGState()
      // Clip to bounds for safety
      ctx.addRect(rect)
      ctx.clip()

      // Draw the radial gradient
      ctx.drawRadialGradient(
        gradient,
        startCenter: center,
        startRadius: 0,
        endCenter: center,
        endRadius: radius,
        options: [.drawsAfterEndLocation, .drawsBeforeStartLocation]
      )

      ctx.restoreGState()
    }
  }
}
