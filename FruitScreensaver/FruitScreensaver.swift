import ScreenSaver
import FruitFarm

// MARK: - FruitView
class FruitScreensaver: ScreenSaverView {

  // MARK: Constant
  private enum Constant {
    static let secondPerFrame = 1.0 / 60.0
    static let backgroundColor = NSColor(
      red: 0.00,
      green: 0.01,
      blue: 0.00,
      alpha: 1.0
    )
  }

  private var fruitView: FruitView!

  private var lastFrameTime: TimeInterval?
  private var lastFps: Int = 60

  override init?(frame: NSRect, isPreview: Bool) {
    super.init(frame: frame, isPreview: isPreview)
    animationTimeInterval = Constant.secondPerFrame
    setupFruitView()
    addObserver()
  }

  required init?(coder decoder: NSCoder) {
    super.init(coder: decoder)
    animationTimeInterval = Constant.secondPerFrame
    setupFruitView()
    addObserver()
  }

  private func setupFruitView() {
    fruitView = FruitView(frame: self.bounds)
    fruitView.autoresizingMask = [.width, .height]
    self.addSubview(fruitView)
  }

  override func layout() {
    super.layout()
    fruitView.frame = self.bounds
  }

  override func animateOneFrame() {
    super.animateOneFrame()
    fruitView.animateOneFrame(framesPerSecond: calculateFps())
  }

  private func calculateFps() -> Int {
    let currentTime = CACurrentMediaTime()
    var fps = lastFps
    if let lastTime = lastFrameTime {
      let delta = currentTime - lastTime
      if delta > 0 {
        fps = Int(round(1.0 / delta))
        lastFps = fps
      }
    }
    lastFrameTime = currentTime
    return fps
  }

  private func addObserver() {
    DistributedNotificationCenter.default.addObserver(
      self,
      selector: #selector(FruitScreensaver.willStop(_:)),
      name: Notification.Name("com.apple.screensaver.willstop"),
      object: nil
    )
  }

  @objc
  private func willStop(_ aNotification: Notification) {
    if !isPreview {
      NSApplication.shared.terminate(nil)
    }
  }

}
