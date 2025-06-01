import Cocoa
import FruitFarm

class AppDelegate: NSObject, NSApplicationDelegate {
  var window: NSWindow?

  func applicationDidFinishLaunching(_ aNotification: Notification) {
    window = NSWindow(contentViewController: RootViewController())
    window?.title = "FruitShop"
    window?.makeKeyAndOrderFront(self)
  }

}

class RootViewController: NSViewController {
  private var fruitView: FruitView!

  override func loadView() {
    self.view = NSView()
    // Debug
//    self.view.wantsLayer = true
//    self.view.layer?.backgroundColor = NSColor.red.cgColor
    self.view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
    fruitView = FruitView(frame: self.view.bounds)
    fruitView.autoresizingMask = [.width, .height]
    self.view.addSubview(fruitView)
  }

  override func viewDidLayout() {
    super.viewDidLayout()
    fruitView.frame = self.view.bounds
  }
}
