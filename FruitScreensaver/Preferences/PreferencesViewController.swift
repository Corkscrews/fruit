import Cocoa
import FruitFarm

// MARK: - PreferencesWindowController

/// Creates and configures the preferences window with its view controller.
/// - Returns: A configured NSWindow instance containing the preferences interface.
func createPreferencesWindow() -> NSWindow {
  let viewController = PreferencesViewController()
  let window = NSWindow(contentViewController: viewController)
  window.title = "Preferences"
  window.styleMask.insert(.titled)
  window.styleMask.insert(.closable)
  window.styleMask.insert(.miniaturizable)
  window.styleMask.insert(.resizable)
  window.setFrameAutosaveName("PreferencesWindow")
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

  /// The main view displaying the fruit animation.
  /// This view is configured to automatically resize with its parent view.
  private lazy var fruitView: FruitView = {
    let fruitView = FruitView(frame: self.view.bounds)
    fruitView.autoresizingMask = [.width, .height]
    return fruitView
  }()

  /// The view containing the controls for the preferences.
  private lazy var controlsView: PreferencesControlsView = {
    let controlsView = PreferencesControlsView()
    controlsView.translatesAutoresizingMaskIntoConstraints = false
    controlsView.onSaveTapped = { [weak self] in
      self?.window?.close()
    }
    controlsView.onBackgroundTypeChanged = { [weak self] selectedIndex in
      if selectedIndex == 0 {
        // TODO: Set random background type mode
        return
      }
      
      // Adjust index to account for "Random" option
      let backgroundTypeIndex = selectedIndex - 1
      if backgroundTypeIndex >= 0 && backgroundTypeIndex < FruitType.allCases.count {
        self?.fruitView.update(type: FruitType.allCases[backgroundTypeIndex])
      }
    }
    return controlsView
  }()

  private lazy var versionLabel: NSTextField = {
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    let copyright = Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String ?? ""
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
    window = nil
    // Remove notification observer
    NotificationCenter.default.removeObserver(self)
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
      controlsView.bottomAnchor.constraint(equalTo: versionLabel.topAnchor, constant: -24.0),
    ])
  }

  /// Called after the view is loaded.
  /// Sets up the initial frame for the fruit view.
  override func viewDidLoad() {
    super.viewDidLoad()
    fruitView.frame = self.view.bounds
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
}

// MARK: - PreferencesControlsView

/// A view that contains the controls for the preferences window.
/// Handles the combo box for background selection and the save button.
final class PreferencesControlsView: NSView {
  // MARK: - Properties
  
  /// Callback for when the save button is tapped.
  var onSaveTapped: (() -> Void)?
  
  /// Callback for when the background type selection changes.
  var onBackgroundTypeChanged: ((Int) -> Void)?
  
  /// A combo box for selecting different background types.
  /// Includes options for all available background types plus a random option.
  private lazy var optionsComboBox: NSComboBox = {
    let comboBox = NSComboBox()
    comboBox.addItems(withObjectValues: buildMenuItems())
    comboBox.selectItem(at: 1)
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
      title: "Save", target: self, action: #selector(saveButtonTapped)
    )
    optionsButton.bezelStyle = .rounded
    optionsButton.translatesAutoresizingMaskIntoConstraints = false
    return optionsButton
  }()

  deinit {
    NotificationCenter.default.removeObserver(self)
    onSaveTapped = nil
    onBackgroundTypeChanged = nil
  }

  // MARK: - Initialization
  
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
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
//      saveButton.centerYAnchor
//        .constraint(equalTo: optionsComboBox.centerYAnchor)
    ])
  }
  
  // MARK: - Actions
  
  @objc
  private func saveButtonTapped() {
    onSaveTapped?()
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
      default:
        fatalError("FruitType not implemented")
      }
    })
    return items
  }
}
