import Cocoa
import QuartzCore

// MARK: - FruitView
public class FruitView: NSView {
  private var background: NSBezierPath!
  private var fruit: NSBezierPath!
  private var originalFruit: NSBezierPath = BuildLogo.buildFruit()
  private var leaf: NSBezierPath!
  private var originalLeaf: NSBezierPath = BuildLogo.buildLeaf()
  private var colorsPath: [NSBezierPath] = []
  private var colorsForPath: [NSColor] = []
  private var maskBackgroundLayer: CAShapeLayer?
  private var heightOfBars: CGFloat = 0
  private var lineLayers: [CAShapeLayer] = []
  private var visibleLinesCount: Int = 6
  private var totalLines: Int = 18
  private var fruitAnimator: FruitAnimator?

  // MARK: - Constants
  private let kBarCountPerCycle = 6
  private let kVisibleLinesCount = 6
  private let kTotalLinesMultiplier = 3

  private static let colorArray: [NSColor] = [
    NSColor(srgbRed: 67/255, green: 156/255, blue: 214/255, alpha: 1), // BLUE
    NSColor(srgbRed: 139/255, green: 69/255, blue: 147/255, alpha: 1), // PURPLE
    NSColor(srgbRed: 207/255, green: 72/255, blue: 69/255, alpha: 1), // RED
    NSColor(srgbRed: 231/255, green: 135/255, blue: 59/255, alpha: 1), // ORANGE
    NSColor(srgbRed: 243/255, green: 185/255, blue: 75/255, alpha: 1), // YELLOW
    NSColor(srgbRed: 120/255, green: 184/255, blue: 86/255, alpha: 1), // GREEN
//    NSColor(srgbRed: 67/255, green: 156/255, blue: 214/255, alpha: 1)  // BLUE
  ]

  public override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    updateFrame()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    updateFrame()
  }

  private func updateFrame() {
    setupFruitAndLeafTransforms()
    setupBackgroundPath()
    setupColorPathsAndColors()
  }

  private func setupFruitAndLeafTransforms() {
    let scale: CGFloat = 2.0
    let x = originalFruit.bounds.size.width
    let y = originalFruit.bounds.size.height
    let middleX = bounds.size.width / 2 - x * scale
    let middleY = bounds.size.height / 2 - y * scale

    let xfm = TransformHelpers.rotationTransform(.pi, cp: NSPoint(x: x, y: y))
    let xm = TransformHelpers.translationTransform(NSPoint(x: middleX, y: middleY))
    let sm = TransformHelpers.scaleTransform(scale)

    let copyFruit = originalFruit.copy() as! NSBezierPath
    copyFruit.transform(using: xfm as AffineTransform)
    copyFruit.transform(using: sm as AffineTransform)
    copyFruit.transform(using: xm as AffineTransform)
    fruit = copyFruit

    let copyLeaf = originalLeaf.copy() as! NSBezierPath
    copyLeaf.transform(using: xfm as AffineTransform)
    copyLeaf.transform(using: sm as AffineTransform)
    copyLeaf.transform(using: xm as AffineTransform)
    leaf = copyLeaf
  }

  private func setupBackgroundPath() {
    background = NSBezierPath()
    background.move(to: NSPoint(x: 0, y: 0))
    background.line(to: NSPoint(x: bounds.size.width, y: 0))
    background.line(to: NSPoint(x: bounds.size.width, y: bounds.size.height))
    background.line(to: NSPoint(x: 0, y: bounds.size.height))
    background.close()
  }

  private func setupColorPathsAndColors() {
    let middleY = bounds.size.height / 2
    let width = bounds.size.width
    let x = 0.0
    let y = fruit.bounds.size.height

    heightOfBars = fruit.bounds.size.height / CGFloat(kBarCountPerCycle)
    visibleLinesCount = kVisibleLinesCount
    totalLines = visibleLinesCount * kTotalLinesMultiplier
    var lastY = middleY - y
    lastY -= heightOfBars * CGFloat(kBarCountPerCycle)

    colorsPath = []
    colorsForPath = []

    for i in 0...totalLines {
      // Use two triangles instead of a rectangle for better performance
      let path = NSBezierPath()
      // First triangle
      path.move(to: NSPoint(x: x, y: lastY))
      path.line(to: NSPoint(x: x + width, y: lastY))
      path.line(to: NSPoint(x: x + width, y: lastY + heightOfBars + 1))
      path.close()
      // Second triangle
      path.move(to: NSPoint(x: x, y: lastY))
      path.line(to: NSPoint(x: x + width, y: lastY + heightOfBars + 1))
      path.line(to: NSPoint(x: x, y: lastY + heightOfBars + 1))
      path.close()
      colorsPath.append(path)
      colorsForPath.append(FruitView.colorArray[i % FruitView.colorArray.count])
      lastY += heightOfBars
    }
  }

  // MARK: - Drawing
  public override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    if maskBackgroundLayer == nil {
      updateFrame()
      setupLayers()
    }
  }

  private func setupLayers() {
    guard let layer = self.layer else { return }
    maskBackgroundLayer = createBackgroundLayer()
    lineLayers = createLineLayers()
    if let maskBackgroundLayer = maskBackgroundLayer {
      maskBackgroundLayer.mask = createLeafAndFruitMask()
      layer.addSublayer(maskBackgroundLayer)
    }
    startAnimation()
  }

  private func createBackgroundLayer() -> CAShapeLayer {
    let quartzBackgroundPath = background.quartzPath
    let bgLayer = CAShapeLayer()
    bgLayer.fillColor = NSColor.black.cgColor
    bgLayer.frame = self.frame
    bgLayer.path = quartzBackgroundPath
    return bgLayer
  }

  private func createLineLayers() -> [CAShapeLayer] {
    var layers: [CAShapeLayer] = []
    for i in 0...totalLines {
      let path = colorsPath[i]
      let quartzLinePath = path.quartzPath
      let maskLineLayer = CAShapeLayer()
      maskLineLayer.fillColor = colorsForPath[i].cgColor
      maskLineLayer.frame = self.frame
      maskLineLayer.path = quartzLinePath
      maskBackgroundLayer?.addSublayer(maskLineLayer)
      layers.append(maskLineLayer)
    }
    return layers
  }

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

  private func startAnimation() {
    fruitAnimator = FruitAnimator(
      lineLayers: lineLayers,
      colorsPath: colorsPath,
      visibleLinesCount: visibleLinesCount,
      heightOfBars: heightOfBars,
      totalLines: totalLines,
      onLoop: { [weak self] in self?.fruitAnimator?.add() }
    )
    fruitAnimator?.add()
  }

  // MARK: - Resizing
  public override func layout() {
    super.layout()
    maskBackgroundLayer?.removeFromSuperlayer()
    maskBackgroundLayer = nil
    setNeedsDisplay(bounds)
  }
}
