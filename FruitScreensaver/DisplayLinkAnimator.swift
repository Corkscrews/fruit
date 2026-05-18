import Cocoa
import QuartzCore

/// Drives animation in sync with the display's hardware refresh rate,
/// avoiding the throttling and imprecision of NSTimer-based approaches.
///
/// Uses `CADisplayLink` on macOS 14+ and falls back to `CVDisplayLink` on older versions.
final class DisplayLinkAnimator {

  /// Called on the main thread for each vsync. Parameter is the display's native refresh rate.
  var onFrame: ((_ fps: Int) -> Void)?

  private var modernLink: AnyObject?
  private var legacyLink: CVDisplayLink?
  private var legacyContext: LegacyContext?

  deinit {
    stop()
  }

  /// Starts (or restarts) the display link bound to the given screen.
  /// Falls back to the main display when `screen` is nil.
  func start(on screen: NSScreen?) {
    stop()
    if #available(macOS 14.0, *) {
      startModernLink(on: screen)
    } else {
      startLegacyLink(on: screen)
    }
  }

  func stop() {
    if #available(macOS 14.0, *) {
      (modernLink as? CADisplayLink)?.invalidate()
      modernLink = nil
    }
    if let link = legacyLink {
      CVDisplayLinkStop(link)
    }
    legacyLink = nil
    legacyContext = nil
  }

  // MARK: - macOS 14+ (CADisplayLink)

  @available(macOS 14.0, *)
  private func startModernLink(on screen: NSScreen?) {
    guard let screen = screen ?? NSScreen.main else { return }
    let link = screen.displayLink(target: self, selector: #selector(handleFrame(_:)))
    link.add(to: .main, forMode: .common)
    modernLink = link
  }

  @available(macOS 14.0, *)
  @objc private func handleFrame(_ link: CADisplayLink) {
    let fps = link.duration > 0 ? Int(round(1.0 / link.duration)) : 60
    onFrame?(fps)
  }

  // MARK: - macOS < 14 (CVDisplayLink)

  private func startLegacyLink(on screen: NSScreen?) {
    var link: CVDisplayLink?
    if let screen = screen {
      let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
        as? CGDirectDisplayID ?? CGMainDisplayID()
      CVDisplayLinkCreateWithCGDisplay(displayID, &link)
    } else {
      CVDisplayLinkCreateWithCGDisplay(CGMainDisplayID(), &link)
    }

    guard let displayLink = link else { return }
    self.legacyLink = displayLink

    let ctx = LegacyContext(self)
    self.legacyContext = ctx

    CVDisplayLinkSetOutputCallback(
      displayLink, { (_, inNow, _, _, _, userInfo) -> CVReturn in
        let ctx = Unmanaged<LegacyContext>.fromOpaque(userInfo!).takeUnretainedValue()
        guard let animator = ctx.animator else { return kCVReturnSuccess }

        let timeScale = Int64(inNow.pointee.videoTimeScale)
        let frameDuration = inNow.pointee.videoRefreshPeriod
        let fps: Int = frameDuration > 0 ? Int(timeScale / frameDuration) : 60

        DispatchQueue.main.async { [weak animator] in
          animator?.onFrame?(fps)
        }
        return kCVReturnSuccess
      }, Unmanaged.passUnretained(ctx).toOpaque())

    CVDisplayLinkStart(displayLink)
  }

  private final class LegacyContext {
    weak var animator: DisplayLinkAnimator?
    init(_ animator: DisplayLinkAnimator) { self.animator = animator }
  }
}
