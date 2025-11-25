import Cocoa
import QuartzCore
import Foundation

/// Custom CALayer to draw all colored bars in one pass
final class RainbowsLayer: CALayer, Background {
  // MARK: - Constants
  private static let colorArray: [NSColor] = [
    NSColor(srgbRed: 67/255, green: 156/255, blue: 214/255, alpha: 1), // BLUE
    NSColor(srgbRed: 139/255, green: 69/255, blue: 147/255, alpha: 1), // PURPLE
    NSColor(srgbRed: 207/255, green: 72/255, blue: 69/255, alpha: 1), // RED
    NSColor(srgbRed: 231/255, green: 135/255, blue: 59/255, alpha: 1), // ORANGE
    NSColor(srgbRed: 243/255, green: 185/255, blue: 75/255, alpha: 1), // YELLOW
    NSColor(srgbRed: 120/255, green: 184/255, blue: 86/255, alpha: 1)  // GREEN
  ]
  private static let barCountPerCycle = 6
  private static let visibleLinesCount = 6
  private static let totalLinesMultiplier = 3
  private static let barSpeed: CGFloat = 3 // points per second

  // MARK: - Properties
  private var linePaths: [NSBezierPath] = []
  private var colorsForPath: [NSColor] = []
  private var currentLineOffsets: [CGFloat] = []
  private var heightOfBars: CGFloat = 0
  private var lastUpdateTime: CGFloat = 0
  private let minUpdateInterval: CGFloat = 1.0 / 30.0 // Throttle to 30 FPS max

  private var totalLines: Int {
    Self.visibleLinesCount * Self.totalLinesMultiplier
  }

  // MARK: - Init
  init(frame: NSRect, fruit: Fruit, contentsScale: CGFloat) {
    super.init()
    self.frame = frame
    self.contentsScale = contentsScale
    config(fruit: fruit)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override init(layer: Any) {
    super.init(layer: layer)
    // Inherit contentsScale from the layer being copied
    if let otherLayer = layer as? CALayer {
      self.contentsScale = otherLayer.contentsScale
    }
  }

  func update(frame: NSRect, fruit: Fruit) {
    self.frame = frame
    config(fruit: fruit)
  }

  /// Creates the paths and assigns colors for each colored bar.
  func config(fruit: Fruit) {
    let fruitPath = fruit.transformedPath
    let width = bounds.size.width
    let originX: CGFloat = 0.0
    let originY = fruitPath.bounds.size.height
    let middleY = bounds.size.height / 2

    heightOfBars = fruitPath.bounds.size.height / CGFloat(Self.barCountPerCycle)

    var lastY = middleY - originY
    lastY -= heightOfBars * CGFloat(Self.barCountPerCycle)

    linePaths = []
    colorsForPath = []
    currentLineOffsets = Array(repeating: 0, count: totalLines)

    for index in 0..<totalLines {
      let path = NSBezierPath()
      path.move(to: NSPoint(x: originX, y: lastY))
      path.line(to: NSPoint(x: originX + width, y: lastY))
      path.line(to: NSPoint(x: originX + width, y: lastY + heightOfBars + 1))
      path.line(to: NSPoint(x: originX, y: lastY + heightOfBars + 1))
      linePaths.append(path)
      colorsForPath.append(Self.colorArray[index % Self.colorArray.count])
      lastY += heightOfBars
    }
  }

  /// Update the animation state for all bars.
  func update(deltaTime: CGFloat) {
    lastUpdateTime += deltaTime

    for index in 0..<totalLines {
      let currentOffset = currentLineOffsets[index]
      let diff = Self.barSpeed * deltaTime
      let maxOffset = heightOfBars * CGFloat(Self.visibleLinesCount)
      let newOffset = currentOffset + diff
      currentLineOffsets[index] = newOffset > maxOffset ? 0 : newOffset
    }

    // Throttle display updates to reduce CPU usage
    if lastUpdateTime >= minUpdateInterval {
      lastUpdateTime = 0
      setNeedsDisplay()
    }
  }

  // MARK: - Drawing
  override func draw(in ctx: CGContext) {
    guard !linePaths.isEmpty, !colorsForPath.isEmpty, !currentLineOffsets.isEmpty else { return }
    for index in 0..<min(linePaths.count, colorsForPath.count, currentLineOffsets.count) {
      let path = linePaths[index]
      let color = colorsForPath[index]
      let offset = currentLineOffsets[index]
      ctx.saveGState()
      ctx.translateBy(x: 0, y: offset)
      ctx.addPath(path.quartzPath)
      ctx.setFillColor(color.cgColor)
      ctx.fillPath()
      ctx.restoreGState()
    }
  }
}
