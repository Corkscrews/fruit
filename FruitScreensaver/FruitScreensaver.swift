import ScreenSaver
import FruitFarm

// MARK: - FruitView
final class FruitScreensaver: ScreenSaverView {

  // MARK: Views

  private var fruitView: FruitView!
  private var metalView: MetalView?

  // MARK: Frame control

  private let displayLinkAnimator = DisplayLinkAnimator()
  private var isPaused: Bool = false

  // MARK: Debug

  private var debugStatsView: DebugStatsView?
  private var lastDebugUpdateTime: TimeInterval = 0

  // MARK: Preferences

  private let preferencesRepository: PreferencesRepository = PreferencesRepositoryImpl()
  private lazy var preferencesWindowController = createPreferencesWindow(
    preferencesRepository: self.preferencesRepository
  )

  deinit {
    displayLinkAnimator.stop()
    NotificationCenter.default.removeObserver(self)
    DistributedNotificationCenter.default.removeObserver(self)
  }

  override init?(frame: NSRect, isPreview: Bool) {
    super.init(frame: frame, isPreview: isPreview)
    animationTimeInterval = .infinity
    commonInit(isPreview: isPreview)
  }

  required init?(coder decoder: NSCoder) {
    super.init(coder: decoder)
    animationTimeInterval = .infinity
    commonInit(isPreview: isPreview)
  }

  private func commonInit(isPreview: Bool) {
    setupFruitView(isPreview: isPreview)
    setupDisplayLinkAnimator()
    if !isPreview {
      setupMetalView()
      addScreenDidChangeNotification()
    }
    addObserverWillStopNotification()
    if DebugStatsView.isEnabled {
      setupDebugView()
    }
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

  private func setupDisplayLinkAnimator() {
    displayLinkAnimator.onFrame = { [weak self] fps in
      guard let self = self, !self.isPaused else { return }
      self.fruitView.animateOneFrame(framesPerSecond: fps)
      self.updateDebugStatsIfNeeded(fps: fps)
    }
    displayLinkAnimator.start(on: window?.screen)
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

  private func setupDebugView() {
    let debugView = DebugStatsView(frame: .zero)
    self.addSubview(debugView)
    debugStatsView = debugView
    debugView.update(fps: 60)
    positionDebugView()
  }

  private func positionDebugView() {
    guard let debugView = debugStatsView else { return }
    let margin: CGFloat = 12
    debugView.frame.origin = CGPoint(
      x: margin,
      y: bounds.height - debugView.frame.height - margin
    )
  }

  override func layout() {
    super.layout()
    fruitView.frame = self.bounds
    metalView?.frame = self.bounds
    if DebugStatsView.isEnabled {
      positionDebugView()
    }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil {
      isPaused = true
      metalView?.isRenderingPaused = true
      displayLinkAnimator.stop()
    } else {
      isPaused = false
      metalView?.isRenderingPaused = false
      displayLinkAnimator.start(on: window?.screen)
    }
  }

  override func animateOneFrame() {
    // No-op: rendering is driven by DisplayLinkAnimator at vsync rate.
  }

  private func updateDebugStatsIfNeeded(fps: Int) {
    guard DebugStatsView.isEnabled else { return }
    let now = CACurrentMediaTime()
    if now - lastDebugUpdateTime >= 0.5 {
      lastDebugUpdateTime = now
      debugStatsView?.update(fps: fps)
      positionDebugView()
    }
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
    displayLinkAnimator.stop()

    if !isPreview {
      NSApplication.shared.terminate(nil)
    }
  }

  private func addScreenDidChangeNotification() {
    checkEDR()
    if let window = window {
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(screenDidChange),
        name: NSWindow.didChangeScreenNotification,
        object: window
      )
    }
  }

  @objc
  private func screenDidChange() {
    checkEDR()
    displayLinkAnimator.start(on: window?.screen)
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
