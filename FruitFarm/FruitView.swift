import Cocoa
import QuartzCore

// MARK: - FruitView
/// FruitView is a custom NSView that draws and animates a stylized fruit logo with 
/// colored bars, similar to the vintage Apple logo.
/// It uses Core Animation layers for efficient rendering and smooth animation.
public class FruitView: NSView {
  // MARK: - Core Paths and Layers
  /// The background shape for the entire view.
  private var background: NSBezierPath!
  /// The transformed fruit path (logo body).
  private var fruit: NSBezierPath!
  /// The original, untransformed fruit path (used for recalculating transforms on resize).
  private var originalFruit: NSBezierPath = BuildLogo.buildFruit()
  /// The transformed leaf path (logo leaf).
  private var leaf: NSBezierPath!
  /// The original, untransformed leaf path (used for recalculating transforms on resize).
  private var originalLeaf: NSBezierPath = BuildLogo.buildLeaf()
  /// Paths for each colored bar.
  private var linePaths: [NSBezierPath] = []
  /// Colors for each bar.
  private var colorsForPath: [NSColor] = []
  /// The main background layer that holds all bar layers.
  private var maskBackgroundLayer: CAShapeLayer?
  /// Height of each colored bar.
  private var heightOfBars: CGFloat = 0
  /// Store the current offset for each line in an array instead of using value/setValue
  private var currentLineOffsets: [CGFloat] = []
  /// CAShapeLayers for each colored bar.
  private var lineLayers: [CAShapeLayer] = []
  /// Number of visible colored bars.
  private var visibleLinesCount: Int = 6
  /// Total number of animated bars (for looping effect).
  private var totalLines: Int = 18

  // MARK: - Constants
  /// Number of bars per color cycle.
  private let kBarCountPerCycle = 6
  /// Number of visible bars at once.
  private let kVisibleLinesCount = 6
  /// Multiplier for total animated bars.
  private let kTotalLinesMultiplier = 3

  /// The color palette for the bars, in rainbow order.
  private static let colorArray: [NSColor] = [
    NSColor(srgbRed: 67/255, green: 156/255, blue: 214/255, alpha: 1), // BLUE
    NSColor(srgbRed: 139/255, green: 69/255, blue: 147/255, alpha: 1), // PURPLE
    NSColor(srgbRed: 207/255, green: 72/255, blue: 69/255, alpha: 1), // RED
    NSColor(srgbRed: 231/255, green: 135/255, blue: 59/255, alpha: 1), // ORANGE
    NSColor(srgbRed: 243/255, green: 185/255, blue: 75/255, alpha: 1), // YELLOW
    NSColor(srgbRed: 120/255, green: 184/255, blue: 86/255, alpha: 1) // GREEN
//    NSColor(srgbRed: 67/255, green: 156/255, blue: 214/255, alpha: 1)  // BLUE
  ]

  /// Initializes the view and sets up the initial geometry and animation.
  public override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    updateFrame()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    updateFrame()
  }

  /// Updates all geometry and paths based on the current view size.
  /// Called on initialization and whenever the view is resized.
  private func updateFrame() {
    setupFruitAndLeafTransforms() // Recalculate fruit/leaf transforms for new size
    setupBackgroundPath()         // Rebuild the background rectangle
    setupColorPathsAndColors()    // Rebuild the colored bar paths and assign colors
  }

  /// Applies scaling, rotation, and translation to the fruit and leaf paths so they are
  /// centered and sized for the current view.
  private func setupFruitAndLeafTransforms() {
    let scale: CGFloat = 2.0
    let originX = originalFruit.bounds.size.width
    let originY = originalFruit.bounds.size.height
    // Center the fruit horizontally and vertically
    let middleX = bounds.size.width / 2 - originX * scale
    let middleY = bounds.size.height / 2 - originY * scale

    // Compose the transforms: rotate, scale, then translate
    let rotationTransform = TransformHelpers.rotationTransform(
      .pi,
      point: NSPoint(x: originX, y: originY)
    )
    let translationTransform = TransformHelpers.translationTransform(
      NSPoint(x: middleX, y: middleY)
    )
    let scaleTransform = TransformHelpers.scaleTransform(scale)

    // Apply transforms to a copy of the original fruit path
    let copyFruit = originalFruit.copy() as! NSBezierPath
    copyFruit.transform(using: rotationTransform as AffineTransform)
    copyFruit.transform(using: scaleTransform as AffineTransform)
    copyFruit.transform(using: translationTransform as AffineTransform)
    fruit = copyFruit

    // Apply transforms to a copy of the original leaf path
    let copyLeaf = originalLeaf.copy() as! NSBezierPath
    copyLeaf.transform(using: rotationTransform as AffineTransform)
    copyLeaf.transform(using: scaleTransform as AffineTransform)
    copyLeaf.transform(using: translationTransform as AffineTransform)
    leaf = copyLeaf
  }

  /// Creates a rectangular background path that fills the view.
  private func setupBackgroundPath() {
    background = NSBezierPath()
    background.move(to: NSPoint(x: 0, y: 0))
    background.line(to: NSPoint(x: bounds.size.width, y: 0))
    background.line(to: NSPoint(x: bounds.size.width, y: bounds.size.height))
    background.line(to: NSPoint(x: 0, y: bounds.size.height))
    background.close()
  }

  /// Creates the paths and assigns colors for each colored bar.
  /// Each bar is made of two triangles for performance.
  private func setupColorPathsAndColors() {
    let middleY = bounds.size.height / 2
    let width = bounds.size.width
    let originX = 0.0
    let originY = fruit.bounds.size.height

    heightOfBars = fruit.bounds.size.height / CGFloat(kBarCountPerCycle)
    visibleLinesCount = kVisibleLinesCount
    totalLines = visibleLinesCount * kTotalLinesMultiplier

    var lastY = middleY - originY
    lastY -= heightOfBars * CGFloat(kBarCountPerCycle)

    linePaths = []
    colorsForPath = []

    for index in 0...totalLines {
      // Each bar is a rectangle split into two triangles
      let path = NSBezierPath()
      // First triangle
      path.move(to: NSPoint(x: originX, y: lastY))
      path.line(to: NSPoint(x: originX + width, y: lastY))
      path.line(to: NSPoint(x: originX + width, y: lastY + heightOfBars + 1))
      path.close()
      // Second triangle
      path.move(to: NSPoint(x: originX, y: lastY))
      path.line(to: NSPoint(x: originX + width, y: lastY + heightOfBars + 1))
      path.line(to: NSPoint(x: originX, y: lastY + heightOfBars + 1))
      path.close()
      linePaths.append(path)
      // Assign color cycling through the palette
      colorsForPath.append(FruitView.colorArray[index % FruitView.colorArray.count])
      lastY += heightOfBars
    }
  }

  // MARK: - Drawing
  /// Draws the view. If the background layer is missing, sets up all layers 
  /// and animation.
  public override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    if maskBackgroundLayer == nil {
      updateFrame()    // Ensure geometry is up to date
      setupLayers()    // Build layers and start animation
    }
  }

  /// Sets up all Core Animation layers for the background, colored bars, and 
  /// fruit/leaf mask.
  private func setupLayers() {
    guard let layer = self.layer else { return }
    maskBackgroundLayer = createBackgroundLayer() // Black background
    lineLayers = createLineLayers()               // Colored bar layers
    if let maskBackgroundLayer = maskBackgroundLayer {
      // Mask with fruit+leaf
      maskBackgroundLayer.mask = createLeafAndFruitMask()
      layer.addSublayer(maskBackgroundLayer)
    }
  }

  /// Creates the black background layer.
  private func createBackgroundLayer() -> CAShapeLayer {
    let quartzBackgroundPath = background.quartzPath
    let bgLayer = CAShapeLayer()
    bgLayer.fillColor = NSColor.black.cgColor
    bgLayer.frame = self.frame
    bgLayer.path = quartzBackgroundPath
    return bgLayer
  }

  /// Creates a CAShapeLayer for each colored bar and adds it to the background layer.
  private func createLineLayers() -> [CAShapeLayer] {
    var layers: [CAShapeLayer] = []
    for index in 0...totalLines {
      let path = linePaths[index]
      let quartzLinePath = path.quartzPath
      let maskLineLayer = CAShapeLayer()
      maskLineLayer.fillColor = colorsForPath[index].cgColor
      maskLineLayer.frame = self.frame
      maskLineLayer.path = quartzLinePath
      maskBackgroundLayer?.addSublayer(maskLineLayer)
      layers.append(maskLineLayer)
    }
    return layers
  }

  /// Creates the mask layer for the fruit and leaf shapes.
  private func createLeafAndFruitMask() -> CAShapeLayer {
    let quartzLeafPath = leaf.quartzPath
    let maskLeafLayer = CAShapeLayer()
    maskLeafLayer.frame = self.frame
    maskLeafLayer.path = quartzLeafPath
    maskLeafLayer.allowsEdgeAntialiasing = true
    let quartzFruitPath = fruit.quartzPath
    let maskFruitLayer = CAShapeLayer()
    maskFruitLayer.frame = self.frame
    maskFruitLayer.path = quartzFruitPath
    maskFruitLayer.allowsEdgeAntialiasing = true
    maskFruitLayer.addSublayer(maskLeafLayer)
    return maskFruitLayer
  }

  /// Last frame timestamp for time-based animation
  private var lastFrameTimestamp: TimeInterval?
  /// Speed of the bar animation in points per second
  private let barSpeed: CGFloat = 3 // adjust as desired

  public func animateOneFrame(framesPerSecond: Int) {
    let deltaTime = calculateDeltaTime(framesPerSecond: framesPerSecond)
    ensureCurrentOffsetsInitialized()
    for index in 0...totalLines {
      updateLineLayer(at: index, deltaTime: deltaTime)
    }
  }

  private func calculateDeltaTime(framesPerSecond: Int) -> CGFloat {
    let now = CACurrentMediaTime()
    var deltaTime: CGFloat = 1.0 / CGFloat(framesPerSecond)
    if let last = lastFrameTimestamp {
      let realDeltaTime = CGFloat(now - last)
      if realDeltaTime > 0 && realDeltaTime < 1.0 {
        deltaTime = realDeltaTime
      }
    }
    lastFrameTimestamp = now
    return deltaTime
  }

  private func ensureCurrentOffsetsInitialized() {
    if currentLineOffsets.count != totalLines + 1 {
      currentLineOffsets = Array(repeating: 0, count: totalLines + 1)
    }
  }

  private func updateLineLayer(at index: Int, deltaTime: CGFloat) {
    let maskLineLayer: CAShapeLayer = lineLayers[index]
    let toPath = linePaths[index].copy() as! NSBezierPath

    let currentOffset = currentLineOffsets[index]
    let diff = barSpeed * deltaTime
    let newOffset = currentOffset + diff

    let maxOffset = heightOfBars * CGFloat(visibleLinesCount)
    let wrappedOffset = newOffset > maxOffset ? 0 : newOffset

    let transform = AffineTransform(translationByX: 0, byY: wrappedOffset)
    toPath.transform(using: transform)
    maskLineLayer.path = toPath.quartzPath
    currentLineOffsets[index] = wrappedOffset
  }

  // MARK: - Resizing
  /// Handles view resizing. Removes and rebuilds all layers and geometry on size change.
  public override func layout() {
    super.layout()
    maskBackgroundLayer?.removeFromSuperlayer()
    maskBackgroundLayer = nil
    setNeedsDisplay(bounds)
  }
}
