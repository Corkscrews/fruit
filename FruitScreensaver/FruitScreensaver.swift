import ScreenSaver
import FruitFarm

// MARK: - FruitView
class FruitScreensaver: ScreenSaverView {

  // MARK: Constant
  private enum Constant {
    static let secondPerFrame = 1.0 / 60.0
    static let backgroundColor = NSColor(red: 0.00, green: 0.01, blue: 0.00, alpha:1.0)
  }

  private var fruitView: FruitView!

  override init?(frame: NSRect, isPreview: Bool) {
    super.init(frame: frame, isPreview: isPreview)
    animationTimeInterval = Constant.secondPerFrame
    setupFruitView()
  }

  required init?(coder decoder: NSCoder) {
    super.init(coder: decoder)
    animationTimeInterval = Constant.secondPerFrame
    setupFruitView()
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

  private func addObserver() {
    DistributedNotificationCenter.default.addObserver(
      self,
      selector: #selector(FruitScreensaver.willStop(_:)),
      name: Notification.Name("com.apple.screensaver.willstop"),
      object: nil
    )
  }

  private func willStop(_ aNotification: Notification) {
    if (!isPreview) {
      NSApplication.shared.terminate(nil)
    }
  }

}
