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
    preferencesRepository: self.preferencesRepository,
    onFruitModeChanged: { [weak self] mode in self?.fruitView.update(mode: mode) }
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
    // The host process is long-lived; pick up changes written by other instances.
    preferencesRepository.reload()
    fruitView.update(mode: preferencesRepository.defaultFruitMode())
    self.addSubview(fruitView)
  }

  private func setupDisplayLinkAnimator() {
    displayLinkAnimator.onFrame = { [weak self] fps in
      guard let self = self, !self.isPaused else { return }
      self.fruitView.animateOneFrame(framesPerSecond: fps)
      self.updateDebugStatsIfNeeded(fps: fps)
    }
    // Started in viewDidMoveToWindow, once the real screen is known.
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
    metalView!.isRenderingPaused = true // unpaused in viewDidMoveToWindow
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
    NotificationCenter.default.removeObserver(
      self, name: NSWindow.didChangeScreenNotification, object: nil
    )
    if let window = window {
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(screenDidChange),
        name: NSWindow.didChangeScreenNotification,
        object: window
      )
      isPaused = false
      metalView?.isRenderingPaused = false
      checkEDR()
      displayLinkAnimator.start(on: window.screen)
    } else {
      isPaused = true
      metalView?.isRenderingPaused = true
      displayLinkAnimator.stop()
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
    // The System Settings thumbnail must keep animating when the real saver stops.
    guard !isPreview else { return }
    isPaused = true
    metalView?.isRenderingPaused = true
    displayLinkAnimator.stop()
    NSApplication.shared.terminate(nil)
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
