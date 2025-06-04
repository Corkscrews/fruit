import Cocoa
import FruitFarm

final class FruitShopViewController: NSViewController {
  private lazy var fruitView: FruitView = {
    let fruitView = FruitView(frame: self.view.bounds)
    fruitView.autoresizingMask = [.width, .height]
    return fruitView
  }()
  private lazy var metalView: MetalView = {
    let metalView = MetalView(frame: view.bounds, frameRate: 1, contrast: 1.0, brightness: 1.0)
    metalView.autoresizingMask = [.width, .height]
    return metalView
  }()

  private var displayLink: CVDisplayLink?

  deinit {
    if let displayLink = displayLink {
      CVDisplayLinkStop(displayLink)
    }
  }

  override func loadView() {
    self.view = NSView()
    self.view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
    self.view.wantsLayer = true // Ensure the view has a backing layer
    self.view.layer?.backgroundColor = NSColor.black.cgColor

    self.view.addSubview(fruitView)
    view.addSubview(metalView)

    setupDisplayLink()
    addOptionsButton()
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
        controller.fruitView.animateOneFrame(framesPerSecond: fps)
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
    guard let screen = view.window?.screen else { return }
    let edrMax = screen.maximumPotentialExtendedDynamicRangeColorComponentValue
    metalView.isHidden = edrMax == 1.0
  }

  // MARK: - Options Button

  private func addOptionsButton() {
    let optionsButton = NSButton(title: "Options", target: self, action: #selector(optionsButtonTapped))
    optionsButton.bezelStyle = .rounded
    optionsButton.translatesAutoresizingMaskIntoConstraints = false
    self.view.addSubview(optionsButton)
    NSLayoutConstraint.activate([
      optionsButton.trailingAnchor.constraint(equalTo: self.view.trailingAnchor, constant: -20),
      optionsButton.bottomAnchor.constraint(equalTo: self.view.bottomAnchor, constant: -20)
    ])
  }

  @objc
  private func optionsButtonTapped() {
    let menuItems: [(title: String, selector: Selector)] = [
      ("Rainbow Bars", #selector(selectBackground(_:))),
      ("Solid", #selector(selectBackground(_:))),
      ("Linear Gradient", #selector(selectBackground(_:))),
      ("Circular Gradient", #selector(selectBackground(_:)))
    ]

    let menu = NSMenu()
    for (index, item) in menuItems.enumerated() {
      let menuItem = NSMenuItem(title: item.title, action: item.selector, keyEquivalent: "")
      menuItem.target = self
      menuItem.tag = index
      menu.addItem(menuItem)
    }

    let buttonOrigin = CGPoint(x: self.view.bounds.maxX - 100, y: 40)
    let menuOrigin = self.view.convert(buttonOrigin, to: nil)
    if let event = NSEvent.mouseEvent(
      with: .leftMouseDown,
      location: menuOrigin,
      modifierFlags: [],
      timestamp: 0,
      windowNumber: self.view.window?.windowNumber ?? 0,
      context: nil,
      eventNumber: 0,
      clickCount: 1,
      pressure: 1
    ) {
      NSMenu.popUpContextMenu(menu, with: event, for: self.view)
    }
  }

  @objc
  private func selectBackground(_ sender: NSMenuItem) {
    switch sender.tag {
    case 0:
      fruitView.update(type: .rainbow)
    case 1:
      fruitView.update(type: .solid)
    case 2:
      fruitView.update(type: .linearGradient)
    case 3:
      fruitView.update(type: .circularGradient)
    default:
      break
    }
  }

}
