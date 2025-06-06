import ScreenSaver
import FruitFarm

// MARK: - FruitView
final class FruitScreensaver: ScreenSaverView {

  // MARK: Constant

  private enum Constant {
    static let secondPerFrame = 1.0 / 60.0
  }

  // MARK: Views

  private var fruitView: FruitView!
  private var metalView: MetalView?

  // MARK: Frame control

  private var lastFrameTime: TimeInterval?
  private var lastFps: Int = 60

  // MARK: Preferences

  private let preferencesRepository: PreferencesRepository = PreferencesRepositoryImpl()
  private lazy var preferencesWindowController = createPreferencesWindow(
    preferencesRepository: self.preferencesRepository
  )

  override init?(frame: NSRect, isPreview: Bool) {
    super.init(frame: frame, isPreview: isPreview)
    animationTimeInterval = Constant.secondPerFrame
    setupFruitView(isPreview: isPreview)
    if !isPreview {
      setupMetalView()
      addScreenDidChangeNotification()
    }
    addObserverWillStopNotification()
  }

  required init?(coder decoder: NSCoder) {
    super.init(coder: decoder)
    animationTimeInterval = Constant.secondPerFrame
    setupFruitView(isPreview: false)
    if !isPreview {
      setupMetalView()
      addScreenDidChangeNotification()
    }
    addObserverWillStopNotification()
  }

  private func setupFruitView(isPreview: Bool) {
    fruitView = FruitView(
      frame: self.bounds,
      mode: isPreview ? .preview : .default
    )
    fruitView.autoresizingMask = [.width, .height]
    fruitView.update(mode: preferencesRepository.defaultFruitMode())
    self.addSubview(fruitView)
  }

  private func setupMetalView() {
    metalView = MetalView(
      frame: self.bounds,
      frameRate: 3,
      contrast: 1.0,
      brightness: 1.0
    )
    metalView!.alphaValue = 0.01
    metalView!.autoresizingMask = [.width, .height]
    metalView!.onReady = { [weak self] in
      guard let self = self, let metalView = self.metalView else { return }
      DispatchQueue.main.async {
        NSAnimationContext.runAnimationGroup({ context in
          context.duration = 1.0
          metalView.animator().alphaValue = 1.0
        }, completionHandler: nil)
      }
    }
    self.addSubview(metalView!)
  }

  override func layout() {
    super.layout()
    fruitView.frame = self.bounds
    metalView?.frame = self.bounds
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

  private func addObserverWillStopNotification() {
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

  private func addScreenDidChangeNotification() {
    checkEDR()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(checkEDR),
      name: NSWindow.didChangeScreenNotification,
      object: window
    )
  }

  @objc
  private func checkEDR() {
    guard let screen = window?.screen else { return }
    let edrMax = screen.maximumPotentialExtendedDynamicRangeColorComponentValue
    metalView?.isHidden = edrMax == 1.0
  }

}

// MARK: - Preferences
extension FruitScreensaver {
  override var hasConfigureSheet: Bool {
    true
  }
  override var configureSheet: NSWindow? {
    preferencesWindowController
  }
}
