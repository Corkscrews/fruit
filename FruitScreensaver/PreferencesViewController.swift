import Cocoa
import FruitFarm

// MARK: - PreferencesViewController
final class PreferencesViewController:
  NSViewController, NSTableViewDataSource, NSTableViewDelegate {

  private let items: [BackgroundTypes] = [
    BackgroundTypes.rainbow,
    BackgroundTypes.solid,
    BackgroundTypes.linearGradient,
    BackgroundTypes.circularGradient
  ]

  private let itemsText: [String] = [
    "Rainbow",
    "Solid",
    "Linear Gradient",
    "Circular Gradient"
  ]

  private let tableView = NSTableView()
  private let scrollView = NSScrollView()
  private let scrollContainer = NSView()
  private var fruitView: FruitView!

  private var displayLink: CVDisplayLink?

  deinit {
    if let displayLink = displayLink {
      CVDisplayLinkStop(displayLink)
    }
  }

  override func loadView() {
    self.view = NSView()
    self.view.frame = NSRect(x: 0, y: 0, width: 600, height: 600)
    self.view.wantsLayer = true // Ensure the view has a backing layer
    self.view.layer?.backgroundColor = NSColor.black.cgColor

    fruitView = FruitView(frame: self.view.bounds)
    fruitView.autoresizingMask = [.width, .height]
    self.view.addSubview(fruitView)

    setupLayoutWithFruitView()

    setupDisplayLink()
  }

  private func setupLayoutWithFruitView() {

    // Configure table column
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("MainColumn"))
    column.title = "Items"
//    column.width = 200 // Ensure column fills available width
    tableView.addTableColumn(column)
    tableView.headerView = nil

    // Set dataSource and delegate
    tableView.dataSource = self
    tableView.delegate = self
    tableView.gridStyleMask = [.solidHorizontalGridLineMask]
    tableView.gridColor = NSColor.separatorColor
    tableView.usesAlternatingRowBackgroundColors = false
    tableView.rowHeight = 32
    // Set the first item selected
    if tableView.numberOfRows > 0 {
      tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    }

    // Configure scroll view
    scrollView.documentView = tableView
    scrollView.hasVerticalScroller = false
    scrollView.hasHorizontalScroller = false
    scrollView.translatesAutoresizingMaskIntoConstraints = false

    // Configure scroll container with rounded borders
    scrollContainer.wantsLayer = true
    scrollContainer.layer?.cornerRadius = 6
    scrollContainer.layer?.masksToBounds = true
    scrollContainer.layer?.borderWidth = 1
    scrollContainer.layer?.borderColor = NSColor.separatorColor.cgColor
    scrollContainer.translatesAutoresizingMaskIntoConstraints = false
    scrollContainer.addSubview(scrollView)
    self.view.addSubview(scrollContainer)

    let scrollContainerHeight = (CGFloat(items.count) * tableView.rowHeight) + 16

    // Layout constraints
    NSLayoutConstraint.activate([

      // ScrollContainer at the right bottom, 30% of the screen width, pinned to bottom and trailing
      scrollContainer.widthAnchor.constraint(equalTo: self.view.widthAnchor, multiplier: 0.25),
      scrollContainer.trailingAnchor.constraint(equalTo: self.view.trailingAnchor, constant: -16),
      scrollContainer.heightAnchor.constraint(equalToConstant: scrollContainerHeight),
      scrollContainer.bottomAnchor.constraint(equalTo: self.view.bottomAnchor, constant: -16),

      // ScrollView fills the scrollContainer
      scrollView.topAnchor.constraint(equalTo: scrollContainer.topAnchor),
      scrollView.leadingAnchor.constraint(equalTo: scrollContainer.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: scrollContainer.trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: scrollContainer.bottomAnchor)
    ])

    fruitView.needsDisplay = true
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    fruitView.frame = self.view.bounds
  }

  // MARK: - NSTableViewDataSource

  func numberOfRows(in tableView: NSTableView) -> Int {
    return items.count
  }

  // MARK: - NSTableViewDelegate

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    let identifier = NSUserInterfaceItemIdentifier("Cell")
    var cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView

    if cell == nil {
      let newCell = NSTableCellView()
      newCell.identifier = identifier

      let textField = NSTextField(labelWithString: itemsText[row])
      textField.translatesAutoresizingMaskIntoConstraints = false
      textField.lineBreakMode = .byTruncatingTail
      newCell.addSubview(textField)
      newCell.textField = textField

      NSLayoutConstraint.activate([
        textField.leadingAnchor.constraint(equalTo: newCell.leadingAnchor, constant: 8),
        textField.trailingAnchor.constraint(equalTo: newCell.trailingAnchor, constant: -8),
        textField.centerYAnchor.constraint(equalTo: newCell.centerYAnchor)
      ])

      cell = newCell
    } else {
      cell?.textField?.stringValue = itemsText[row]
    }

    return cell
  }

  func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
    // When a row is selected, update the fruitView with the selected type
    let selectedType = items[row]
    fruitView.update(type: selectedType)
    return true
  }

  // MARK: - Display Link

  private func setupDisplayLink() {
    var link: CVDisplayLink?
    CVDisplayLinkCreateWithActiveCGDisplays(&link)
    guard let displayLink = link else { return }
    self.displayLink = displayLink

    CVDisplayLinkSetOutputCallback(displayLink, { (_, inNow, _, _, _, userInfo) -> CVReturn in
      let controller = Unmanaged<PreferencesViewController>.fromOpaque(userInfo!).takeUnretainedValue()
      // Get the display's refresh rate (frames per second)
      // CVTimeStamp does not have a 'timeScale' property; use 'videoTimeScale' instead
      let timeScale = Int64(inNow.pointee.videoTimeScale)
      let frameDuration = inNow.pointee.videoRefreshPeriod
      // Calculate FPS
      let fps: Int = frameDuration > 0 ? Int(timeScale / frameDuration) : 60

      DispatchQueue.main.async {
        controller.fruitView?.needsDisplay = true
        controller.fruitView?.animateOneFrame(framesPerSecond: fps)
      }
      return kCVReturnSuccess
    }, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))

    CVDisplayLinkStart(displayLink)
  }
}
