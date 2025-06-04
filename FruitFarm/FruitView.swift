import Cocoa
import QuartzCore
import Foundation

@frozen
public enum FruitViewMode {
  case preview
  case preferences
  case `default`
}

// MARK: - FruitView
/// FruitView is a custom NSView that draws and animates a stylized fruit logo with
/// colored bars, similar to the vintage Apple logo.
/// It uses Core Animation layers for efficient rendering and smooth animation.
public final class FruitView: NSView {

  public let mode: FruitViewMode

  // MARK: - Core Paths and Layers
  /// The transformed fruit path (logo body).
  private let fruit = Fruit()
  /// The transformed leaf path (logo leaf).
  private let leaf = Leaf()
  /// The main background layer that holds all bar layers.
  private var backgroundLayer: BackgroundLayer?
  /// The single layer that draws the background layer inside the fruit.
  private var fruitBackground: (CALayer & Background)?
  /// The type of background
  public private(set) var fruitMode: FruitMode = FruitMode.specific(.rainbow)
  /// Timer to randomly change the fruit type, only used when random mode is selected.
  private var fruitChangeTimer: Timer?

  deinit {
    fruitChangeTimer?.invalidate()
    fruitChangeTimer = nil
  }

  /// Initializes the view and sets up the initial geometry and animation.
  public init(frame frameRect: NSRect, mode: FruitViewMode) {
    self.mode = mode
    super.init(frame: frameRect)
    setupFruitAndLeafObjects()
  }

  @available(*, unavailable, message: "Use init(frame:isPreview:) instead")
  public override convenience init(frame frameRect: NSRect) {
    self.init(frame: frameRect, mode: FruitViewMode.default)
  }

  required init?(coder: NSCoder) {
    self.mode = FruitViewMode.default
    super.init(coder: coder)
    setupFruitAndLeafObjects()
  }

  public func update(mode fruitMode: FruitMode) {
    if self.fruitMode == fruitMode {
      return
    }
    self.fruitMode = fruitMode
    self.fruitBackground?.removeFromSuperlayer()
    self.fruitBackground = nil
    self.needsDisplay = true
    // Specific case when random mode is selected, we need to toggle the mode to
    // a random fruit type. When the user selects a specific fruit type, we need to 
    // display the specific fruit type and disable the random mode.
    toggleRandomMode(enabled: self.fruitMode == FruitMode.random)
  }

  private func toggleRandomMode(enabled: Bool) {
    fruitChangeTimer?.invalidate()
    if !enabled {
      fruitChangeTimer = nil
      return
    }
    fruitChangeTimer = Timer.scheduledTimer(
      withTimeInterval: mode == .preferences ? 8.0 : 60.0,
      repeats: true
    ) { [weak self] _ in
      self?.randomlyChangeFruitType()
    }
  }

  private func randomlyChangeFruitType() {
    // Fade out fruitView over 0.5s, then change, then fade back in.
    NSAnimationContext.runAnimationGroup({ context in
      context.duration = 1.0
      self.animator().alphaValue = 0.0
    }, completionHandler: { [weak self] in

      // This will force a random fruit to be loaded.
      self?.fruitBackground?.removeFromSuperlayer()
      self?.fruitBackground = nil
      self?.needsDisplay = true

      // Now fade back in.
      NSAnimationContext.runAnimationGroup({ context in
        context.duration = 1.0
        self?.animator().alphaValue = 1.0
      }, completionHandler: nil)
    })
  }

  /// Applies scaling, rotation, and translation to the fruit and leaf paths so they are
  /// centered and sized for the current view.
  private func setupFruitAndLeafObjects() {
    let scale: CGFloat = scale()
    let originX = fruit.originalPath.bounds.size.width
    let originY = fruit.originalPath.bounds.size.height
    let middleX = bounds.size.width / 2 - originX * scale
    let middleY = bounds.size.height / 2 - originY * scale

    // Compose the transforms: rotate, scale, then translate
    let transform = Transform(
      scale: TransformHelpers.scaleTransform(scale) as AffineTransform,
      rotation: TransformHelpers.rotationTransform(
        Double.pi,
        point: NSPoint(x: originX, y: originY)
      ) as AffineTransform,
      translation: TransformHelpers.translationTransform(
        NSPoint(x: middleX, y: middleY)
      ) as AffineTransform
    )

    fruit.applyTransforms(transform: transform)
    leaf.applyTransforms(transform: transform)
  }

  private func scale() -> CGFloat {
    if self.mode == FruitViewMode.preview {
      return ((self.frame.width / 1728) + (self.frame.height / 1117)) * 1.5
    }
    let finalWidth = fruit.originalPath.bounds.size.width * 2.0
    let finalHeight = fruit.originalPath.bounds.size.height * 2.0
    let widthScale = bounds.size.width / finalWidth
    let heightScale = bounds.size.height / finalHeight
    return min(2.0, widthScale, heightScale)
  }

  // MARK: - Drawing
  /// Draws the view. If the background layer is missing, sets up all layers
  /// and animation.
  public override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    setupLayersOrUpdate()
  }

  /// Sets up all Core Animation layers for the background, colored bars, and
  /// fruit/leaf mask.
  private func setupLayersOrUpdate() {
    guard let layer = self.layer else { return }

    if let fruitBackground = self.fruitBackground {
      fruitBackground.config(fruit: fruit)
    } else {
      // Necessary otherwise the sublayer is not recovered.
      self.backgroundLayer = nil
      switch self.fruitMode {
      case .random:
        self.fruitBackground = buildFruitBackground(FruitType.allCases.randomElement()!)
      case .specific(let fruitType):
        self.fruitBackground = buildFruitBackground(fruitType)
      }
    }

    let needsAddBackgroundLayer = self.backgroundLayer == nil

    if let backgroundLayer = self.backgroundLayer {
      backgroundLayer.config(fruit: fruit)
    } else {
      backgroundLayer = BackgroundLayer(frame: self.frame)
      backgroundLayer?.addSublayer(fruitBackground!)
    }

    // Required to rebuild the leaf and fruit paths, otherwise
    // the elements won't change in size.
    setupFruitAndLeafObjects()

    backgroundLayer!.mask = createLeafAndFruitMask()
    if needsAddBackgroundLayer {
      layer.addSublayer(backgroundLayer!)
    }
  }

  private func buildFruitBackground(_ fruitType: FruitType) -> (CALayer & Background)? {
    switch fruitType {
    case .rainbow:
      return RainbowsLayer(frame: self.frame, fruit: fruit)
    case .solid:
      return SolidLayer(frame: self.frame, fruit: fruit)
    case .linearGradient:
      return LinearGradientLayer(frame: self.frame, fruit: fruit)
    case .circularGradient:
      return CircularGradientLayer(frame: self.frame, fruit: fruit)
    }
  }

  /// Creates the mask layer for the fruit and leaf shapes.
  private func createLeafAndFruitMask() -> CAShapeLayer {
    let maskLeafLayer = CAShapeLayer()
    maskLeafLayer.frame = self.frame
    maskLeafLayer.path = leaf.transformedPath.quartzPath
    maskLeafLayer.allowsEdgeAntialiasing = true
    let maskFruitLayer = CAShapeLayer()
    maskFruitLayer.frame = self.frame
    maskFruitLayer.path = fruit.transformedPath.quartzPath
    maskFruitLayer.allowsEdgeAntialiasing = true
    maskFruitLayer.addSublayer(maskLeafLayer)
    return maskFruitLayer
  }

  public func animateOneFrame(framesPerSecond: Int) {
    fruitBackground?.update(
      deltaTime: calculateDeltaTime(framesPerSecond: framesPerSecond)
    )
  }

  /// Last frame timestamp for time-based animation
  private var lastFrameTimestamp: TimeInterval?

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

  // MARK: - Resizing
  /// Handles view resizing. Updates all layers and geometry on size change.
  public override func layout() {
    super.layout()
    backgroundLayer?.update(frame: self.frame, fruit: self.fruit)
    fruitBackground?.update(frame: self.frame, fruit: self.fruit)
    setNeedsDisplay(bounds)
  }
}
