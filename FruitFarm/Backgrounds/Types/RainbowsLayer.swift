import Cocoa
import QuartzCore
import Foundation

/// Colored bars built once as solid-color sublayers; animation only moves their container,
/// so nothing is rasterized per frame.
final class RainbowsLayer: CALayer, Background {
  // MARK: - Constants
  private static let colorArray: [CGColor] = [
    NSColor(srgbRed: 67/255, green: 156/255, blue: 214/255, alpha: 1), // BLUE
    NSColor(srgbRed: 139/255, green: 69/255, blue: 147/255, alpha: 1), // PURPLE
    NSColor(srgbRed: 207/255, green: 72/255, blue: 69/255, alpha: 1), // RED
    NSColor(srgbRed: 231/255, green: 135/255, blue: 59/255, alpha: 1), // ORANGE
    NSColor(srgbRed: 243/255, green: 185/255, blue: 75/255, alpha: 1), // YELLOW
    NSColor(srgbRed: 120/255, green: 184/255, blue: 86/255, alpha: 1)  // GREEN
  ].map(\.cgColor)
  private static let cycleCount = 3
  private static let barSpeed: CGFloat = 3 // points per second

  // MARK: - Properties
  /// Zero-size container at the origin, so bars use this layer's coordinates.
  private let stripes = CALayer()
  /// Height of one full color cycle (six bars), equal to the fruit height.
  private var cycleHeight: CGFloat = 0
  private var offset: CGFloat = 0

  // MARK: - Init
  init(frame: NSRect, fruit: Fruit, leaf: Leaf, contentsScale: CGFloat) {
    super.init()
    self.frame = frame
    self.contentsScale = contentsScale
    for index in 0..<(Self.colorArray.count * Self.cycleCount) {
      let bar = CALayer()
      bar.backgroundColor = Self.colorArray[index % Self.colorArray.count]
      bar.allowsEdgeAntialiasing = true
      stripes.addSublayer(bar)
    }
    addSublayer(stripes)
    config(fruit: fruit, leaf: leaf)
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

  func update(frame: NSRect, fruit: Fruit, leaf: Leaf) {
    setFrameWithoutAnimation(frame)
    config(fruit: fruit, leaf: leaf)
  }

  /// Lays out the bars: three cycles starting two fruit-heights below the middle, so the
  /// band scrolling up by 0..<cycleHeight always covers the fruit.
  func config(fruit: Fruit, leaf: Leaf) {
    cycleHeight = fruit.bounds(including: leaf).height
    let barHeight = cycleHeight / CGFloat(Self.colorArray.count)
    let startY = bounds.midY - 2 * cycleHeight
    offset = cycleHeight > 0 ? offset.truncatingRemainder(dividingBy: cycleHeight) : 0

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for (index, bar) in (stripes.sublayers ?? []).enumerated() {
      // +1 overlaps the next bar to hide seams
      bar.frame = CGRect(
        x: 0,
        y: startY + CGFloat(index) * barHeight,
        width: bounds.width,
        height: barHeight + 1
      )
    }
    stripes.setAffineTransform(CGAffineTransform(translationX: 0, y: offset))
    CATransaction.commit()
  }

  /// Scrolls the bars up, wrapping every full color cycle.
  func update(deltaTime: CGFloat) {
    guard cycleHeight > 0 else { return }
    offset = (offset + Self.barSpeed * deltaTime).truncatingRemainder(dividingBy: cycleHeight)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    stripes.setAffineTransform(CGAffineTransform(translationX: 0, y: offset))
    CATransaction.commit()
  }
}
