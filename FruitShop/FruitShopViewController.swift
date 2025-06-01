import Cocoa
import FruitFarm

final class FruitShopViewController: NSViewController {
  private var fruitView: FruitView!
  private var displayLink: CVDisplayLink?

  override func loadView() {
    self.view = NSView()
    // Debug
//    self.view.wantsLayer = true
//    self.view.layer?.backgroundColor = NSColor.red.cgColor
    self.view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
    fruitView = FruitView(frame: self.view.bounds)
    fruitView.autoresizingMask = [.width, .height]
    self.view.addSubview(fruitView)
    setupDisplayLink()
  }

  override func viewDidLayout() {
    super.viewDidLayout()
    fruitView.frame = self.view.bounds
  }

  deinit {
    if let displayLink = displayLink {
      CVDisplayLinkStop(displayLink)
    }
  }

  private func setupDisplayLink() {
    var link: CVDisplayLink?
    CVDisplayLinkCreateWithActiveCGDisplays(&link)
    guard let displayLink = link else { return }
    self.displayLink = displayLink

    CVDisplayLinkSetOutputCallback(displayLink, { (_, inNow, _, _, _, userInfo) -> CVReturn in
      let controller = Unmanaged<FruitShopViewController>.fromOpaque(userInfo!).takeUnretainedValue()
      // Get the display's refresh rate (frames per second)
      // CVTimeStamp does not have a 'timeScale' property; use 'videoTimeScale' instead
      let timeScale = Int64(inNow.pointee.videoTimeScale)
//      let timeValue = inNow.pointee.videoTime
      let frameDuration = inNow.pointee.videoRefreshPeriod
      // Calculate FPS
      let fps: Int = frameDuration > 0 ? Int(timeScale / frameDuration) : 60

      DispatchQueue.main.async {
        controller.fruitView?.animateOneFrame(framesPerSecond: fps)
      }
      return kCVReturnSuccess
    }, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))

    CVDisplayLinkStart(displayLink)
  }
}
