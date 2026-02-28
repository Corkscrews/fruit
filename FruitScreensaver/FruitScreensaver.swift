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
  private var isPaused: Bool = false
  private var lameDuck: Bool = false

  // MARK: Preview detection

  // FB7486243: On Sonoma, legacyScreenSaver.appex always passes true for
  // isPreview. On Tahoe it is inverted. We detect the real state from the
  // frame size — the preview thumbnail is always small (~296x184).
  private let actualIsPreview: Bool

  // MARK: Preferences

  private let preferencesRepository: PreferencesRepository = PreferencesRepositoryImpl()
  private lazy var preferencesWindowController = createPreferencesWindow(
    preferencesRepository: self.preferencesRepository
  )

  deinit {
    NotificationCenter.default.removeObserver(self)
    DistributedNotificationCenter.default.removeObserver(self)
  }

  private static let newInstanceNotification = Notification.Name(
    "com.corkscrews.fruit.NewInstance"
  )

  override init?(frame: NSRect, isPreview: Bool) {
    actualIsPreview = frame.width <= 400 || frame.height <= 300
    super.init(frame: frame, isPreview: actualIsPreview)
    animationTimeInterval = Constant.secondPerFrame
    addNewInstanceObserver()
    setupFruitView()
    if !actualIsPreview {
      setupMetalView()
      addScreenDidChangeNotification()
    }
    addObserverWillStopNotification()
  }

  required init?(coder decoder: NSCoder) {
    actualIsPreview = false
    super.init(coder: decoder)
    animationTimeInterval = Constant.secondPerFrame
    addNewInstanceObserver()
    setupFruitView()
    if !actualIsPreview {
      setupMetalView()
      addScreenDidChangeNotification()
    }
    addObserverWillStopNotification()
  }

  // FB19204084: legacyScreenSaver.appex creates new ScreenSaverView instances
  // on every activation without destroying old ones. Each new instance
  // notifies older ones to stop animating and release resources.
  private func addNewInstanceObserver() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(neuterOldInstance(_:)),
      name: Self.newInstanceNotification,
      object: nil
    )
    NotificationCenter.default.post(
      name: Self.newInstanceNotification,
      object: self
    )
  }

  @objc
  private func neuterOldInstance(_ notification: Notification) {
    guard let newInstance = notification.object as? FruitScreensaver,
          newInstance !== self,
          newInstance.actualIsPreview == self.actualIsPreview else { return }
    lameDuck = true
    isPaused = true
    metalView?.isRenderingPaused = true
    removeFromSuperview()
    // swiftlint:disable:next notification_center_detachment
    NotificationCenter.default.removeObserver(self)
    DistributedNotificationCenter.default.removeObserver(self)
  }

  private func setupFruitView() {
    fruitView = FruitView(
      frame: self.bounds,
      mode: actualIsPreview ? .preview : .default
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

  override func startAnimation() {
    super.startAnimation()
    guard !lameDuck else { return }

    // Flush the ScreenSaverDefaults cache so we pick up preference
    // changes made in System Settings while the process was alive.
    preferencesRepository.reload()
    fruitView.update(mode: preferencesRepository.defaultFruitMode())

    isPaused = false
    metalView?.isRenderingPaused = false
  }

  // Only called for the System Settings live preview (broken in Sonoma
  // for normal operation), but still worth handling.
  override func stopAnimation() {
    isPaused = true
    metalView?.isRenderingPaused = true
    super.stopAnimation()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil {
      isPaused = true
      metalView?.isRenderingPaused = true
    } else {
      isPaused = false
      metalView?.isRenderingPaused = false
    }
  }

  override func animateOneFrame() {
    super.animateOneFrame()
    guard !isPaused, !lameDuck else { return }
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
    isPaused = true
    metalView?.isRenderingPaused = true

    // Delay exit to avoid a race condition with rapid lock/unlock cycles
    // that can leave a black screen. Using exit(0) instead of terminate(_:)
    // to skip AppKit delegate callbacks inside legacyScreenSaver.appex.
    if !actualIsPreview {
      DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
        exit(0)
      }
    }
  }

  private func addScreenDidChangeNotification() {
    checkEDR()
    // Only observe screen changes for this specific window
    // Passing nil would observe ALL windows, causing excessive callbacks
    if let window = window {
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(checkEDR),
        name: NSWindow.didChangeScreenNotification,
        object: window
      )
    }
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
