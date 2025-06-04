import Cocoa
import FruitFarm

// MARK: - PreferencesWindowController

/// Creates and configures the preferences window with its view controller.
/// - Returns: A configured NSWindow instance containing the preferences interface.
func createPreferencesWindow(preferencesRepository: PreferencesRepository) -> NSWindow {
  let viewController = PreferencesViewController(preferencesRepository: preferencesRepository)
  let window = NSWindow(contentViewController: viewController)
  window.title = "Preferences"
  window.styleMask.insert(.resizable)
  window.center()
  window.makeKeyAndOrderFront(nil)
  viewController.window = window  // Store the window reference
  return window
}

// MARK: - PreferencesViewController

final class PreferencesViewController:
  NSViewController, NSTableViewDataSource, NSTableViewDelegate {

  // Store reference to the window
  weak var window: NSWindow?

  var preferencesRepository: PreferencesRepository?

  private var fruitMode: FruitMode?

  /// The main view displaying the fruit animation.
  /// This view is configured to automatically resize with its parent view.
  private lazy var fruitView: FruitView = {
    let fruitView = FruitView(frame: self.view.bounds, mode: .preferences)
    fruitView.autoresizingMask = [.width, .height]
    fruitView.update(mode: preferencesRepository!.defaultFruitMode())
    return fruitView
  }()

  private lazy var metalView: MetalView = {
    let metalView = MetalView(frame: view.bounds, frameRate: 1, contrast: 1.0, brightness: 1.0)
    metalView.autoresizingMask = [.width, .height]
    return metalView
  }()

  /// The view containing the controls for the preferences.
  private lazy var controlsView: PreferencesControlsView = {
    let controlsView = PreferencesControlsView(
      fruitMode: preferencesRepository!.defaultFruitMode()
    )
    controlsView.translatesAutoresizingMaskIntoConstraints = false
    controlsView.onDoneTapped = { [weak self] in
      guard let window = self?.window else {
        return
      }
      if let sheetParent = window.sheetParent {
        sheetParent.endSheet(window)
      }
      window.close()
    }
    controlsView.onBackgroundTypeChanged = { [weak self] selectedIndex in
      let fruitMode: FruitMode
      if selectedIndex == 0 {
        fruitMode = .random
      } else {
        let index = selectedIndex - 1
        guard index >= 0, index < FruitType.allCases.count else { return }
        fruitMode = .specific(FruitType.allCases[index])
      }
      self?.fruitMode = fruitMode
      self?.fruitView.update(mode: fruitMode)
      self?.preferencesRepository!.updateDefaultFruitMode(fruitMode)
    }
    return controlsView
  }()

  private lazy var versionLabel: NSTextField = {
    let bundle = Bundle(for: type(of: self))
    let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String
      ?? Bundle.main.infoDictionary?["CFBundleVersion"] as? String
      ?? "Unknown"
    let copyright = bundle.infoDictionary?["NSHumanReadableCopyright"] as? String ?? ""
    let labelText = "Version: \(version) - Thank you! 😊\n\(copyright)"
    let label = NSTextField(labelWithString: labelText)
    label.alignment = .center
    label.textColor = .secondaryLabelColor
    label.font = NSFont.systemFont(ofSize: 12)
    label.translatesAutoresizingMaskIntoConstraints = false
    label.lineBreakMode = .byWordWrapping
    label.maximumNumberOfLines = 2
    return label
  }()

  /// Display link for synchronizing animation with screen refresh rate.
  private var displayLink: CVDisplayLink?

  deinit {
    if let displayLink = displayLink {
      CVDisplayLinkStop(displayLink)
    }
    preferencesRepository = nil
    window = nil
    // Remove notification observer
    NotificationCenter.default.removeObserver(self)
  }

  init(preferencesRepository: PreferencesRepository) {
    self.preferencesRepository = preferencesRepository
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /// Sets up the view controller's view and subviews.
  /// Called automatically when the view controller is loaded.
  override func loadView() {
    configView()
    addSubviews()
    configConstraints()
    setupDisplayLink()
  }

  /// Configures the main view with a black background.
  private func configView() {
    self.view = NSView()
    self.view.frame = NSRect(x: 0, y: 0, width: 600, height: 600)
    self.view.wantsLayer = true // Ensure the view has a backing layer
    self.view.layer?.backgroundColor = NSColor.black.cgColor
  }

  /// Adds all subviews to the main view.
  private func addSubviews() {
    self.view.addSubview(fruitView)
    self.view.addSubview(metalView)
    self.view.addSubview(versionLabel)
    self.view.addSubview(controlsView)
  }

  /// Configures Auto Layout constraints for all subviews.
  /// Ensures proper positioning and sizing of UI elements.
  private func configConstraints() {
    NSLayoutConstraint.activate([
      versionLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      versionLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -24.0),
      versionLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16.0),
      versionLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16.0),

      controlsView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      controlsView.bottomAnchor.constraint(equalTo: versionLabel.topAnchor, constant: -24.0)
    ])
  }

  /// Called after the view is loaded.
  /// Sets up the initial frame for the fruit view.
  override func viewDidLoad() {
    super.viewDidLoad()
//    fruitView.frame = self.view.bounds
//    metalView.frame = self.view.bounds
    addScreenDidChangeNotification()
  }

  override func viewDidLayout() {
    super.viewDidLayout()
    fruitView.frame = self.view.bounds
    metalView.frame = self.view.bounds
  }

  // MARK: - Display Link

  /// Sets up the display link for smooth animation.
  /// Synchronizes the animation with the screen's refresh rate.
  private func setupDisplayLink() {
    var link: CVDisplayLink?
    CVDisplayLinkCreateWithActiveCGDisplays(&link)
    guard let displayLink = link else { return }
    self.displayLink = displayLink

    CVDisplayLinkSetOutputCallback(
      displayLink, { (_, inNow, _, _, _, userInfo) -> CVReturn in
      let controller = Unmanaged<PreferencesViewController>
        .fromOpaque(userInfo!).takeUnretainedValue()
      // Get the display's refresh rate (frames per second)
      // CVTimeStamp does not have a 'timeScale' property; use 'videoTimeScale' instead
      let timeScale = Int64(inNow.pointee.videoTimeScale)
      let frameDuration = inNow.pointee.videoRefreshPeriod
      // Calculate FPS
      let fps: Int = frameDuration > 0 ? Int(timeScale / frameDuration) : 60

      DispatchQueue.main.async {
        controller.fruitView.needsDisplay = true
        controller.fruitView.animateOneFrame(framesPerSecond: fps)
      }
      return kCVReturnSuccess
    }, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))

    CVDisplayLinkStart(displayLink)
  }

  // MARK: - EDR

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

}

// MARK: - PreferencesControlsView

/// A view that contains the controls for the preferences window.
/// Handles the combo box for background selection and the save button.
final class PreferencesControlsView: NSView {

  // MARK: - Properties

  private let fruitMode: FruitMode

  /// Callback for when the save button is tapped.
  var onDoneTapped: (() -> Void)?

  /// Callback for when the background type selection changes.
  var onBackgroundTypeChanged: ((Int) -> Void)?

  /// A combo box for selecting different background types.
  /// Includes options for all available background types plus a random option.
  private lazy var optionsComboBox: NSComboBox = {
    let comboBox = NSComboBox()
    comboBox.addItems(withObjectValues: buildMenuItems())

    let index: Int
    switch fruitMode {
    case .random:
      index = -1 // Default to random
    case .specific(let fruitType):
      index = FruitType.allCases.firstIndex(of: fruitType) ?? 0
    }
    comboBox.selectItem(at: index + 1)
    comboBox.isEditable = false
    comboBox.translatesAutoresizingMaskIntoConstraints = false

    // Add notification observer for selection changes
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(comboBoxSelectionDidChange(_:)),
      name: NSComboBox.selectionDidChangeNotification,
      object: comboBox
    )

    return comboBox
  }()

  /// Button to save the current preferences and close the window.
  private lazy var saveButton: NSButton = {
    let optionsButton = NSButton(
      title: "Done", target: self, action: #selector(doneButtonTapped)
    )
    optionsButton.bezelStyle = .rounded
    optionsButton.translatesAutoresizingMaskIntoConstraints = false
    return optionsButton
  }()

  deinit {
    NotificationCenter.default.removeObserver(self)
    onDoneTapped = nil
    onBackgroundTypeChanged = nil
  }

  // MARK: - Initialization

  init(fruitMode: FruitMode) {
    self.fruitMode = fruitMode
    super.init(frame: NSRect.zero)
    setupContainer()
    addSubviews()
    setupConstraints()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Setup

  private func setupContainer() {
    wantsLayer = true
    layer?.cornerRadius = 12
    layer?.masksToBounds = true
    layer?.borderWidth = 1
    layer?.borderColor = NSColor.separatorColor.cgColor
    layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.95).cgColor
  }

  private func addSubviews() {
    addSubview(optionsComboBox)
    addSubview(saveButton)
  }

  private func setupConstraints() {
    NSLayoutConstraint.activate([
      optionsComboBox.widthAnchor.constraint(equalToConstant: estimateComboBoxWidth()),
      optionsComboBox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16.0),
      optionsComboBox.topAnchor.constraint(equalTo: topAnchor, constant: 16.0),
      optionsComboBox.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16.0),

      saveButton.leadingAnchor.constraint(equalTo: optionsComboBox.trailingAnchor, constant: 8.0),
      saveButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16.0),
      saveButton.topAnchor.constraint(equalTo: topAnchor, constant: 16.0),
      saveButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16.0)
    ])
  }

  // MARK: - Actions

  @objc
  private func doneButtonTapped() {
    onDoneTapped?()
  }

  @objc
  private func comboBoxSelectionDidChange(_ notification: Notification) {
    guard let comboBox = notification.object as? NSComboBox else { return }
    let selectedIndex = comboBox.indexOfSelectedItem
    onBackgroundTypeChanged?(selectedIndex)
  }

  // MARK: - Helper Methods

  /// Estimates the required width for the combo box based on its content.
  /// Takes into account the font size and adds padding for the dropdown arrow.
  /// - Returns: The estimated width needed for the combo box, capped at 140 points.
  private func estimateComboBoxWidth() -> CGFloat {
    let menuItems = buildMenuItems()
    let font = optionsComboBox.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
    var maxWidth: CGFloat = 0
    for item in menuItems {
      let size = (item as NSString).size(withAttributes: [.font: font])
      if size.width > maxWidth {
        maxWidth = size.width
      }
    }
    return min(140, maxWidth + 40)
  }

  /// Builds the list of menu items for the combo box.
  /// Includes a "Random" option followed by all available background types.
  /// - Returns: An array of strings representing the menu items.
  private func buildMenuItems() -> [String] {
    var items: [String] = ["Random"]
    items.append(contentsOf: FruitType.allCases.map { type in
      switch type {
      case .rainbow:
        return "Rainbow Bars"
      case .solid:
        return "Solid"
      case .linearGradient:
        return "Linear Gradient"
      case .circularGradient:
        return "Circular Gradient"
      }
    })
    return items
  }
}
