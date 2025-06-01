import Cocoa
import FruitFarm

final class FruitShopViewController: NSViewController {
  private var fruitView: FruitView!
  private var metalView: MetalView!

  private var displayLink: CVDisplayLink?

  override func loadView() {
    self.view = NSView()
    self.view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
    self.view.wantsLayer = true // Ensure the view has a backing layer
    self.view.layer?.backgroundColor = NSColor.black.cgColor
    
    fruitView = FruitView(frame: self.view.bounds)
    fruitView.autoresizingMask = [.width, .height]
    self.view.addSubview(fruitView)

    metalView = MetalView(frame: view.bounds, frameRate: 3, contrast: 1.0, brightness: 1.0)
    metalView.autoresizingMask = [.width, .height]
    view.addSubview(metalView)

    setupDisplayLink()
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    addScreenDidChangeNotification()
  }

  override func viewDidLayout() {
    super.viewDidLayout()
    fruitView.frame = self.view.bounds
    metalView.frame = self.view.bounds
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

  private func addScreenDidChangeNotification() {
    checkEDR()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(checkEDR),
      name: NSWindow.didChangeScreenNotification,
      object: view.window
    )
  }

  @objc
  private func checkEDR() {
    if let screen = view.window?.screen {
      let edrMax = screen.maximumPotentialExtendedDynamicRangeColorComponentValue
      metalView.isHidden = edrMax == 1.0
    }
  }

}
