import Cocoa
import FruitFarm

class AppDelegate: NSObject, NSApplicationDelegate {
  var window: NSWindow?

  func applicationDidFinishLaunching(_ aNotification: Notification) {
    window = NSWindow(contentViewController: FruitShopViewController())
    window?.title = "FruitShop"
    window?.makeKeyAndOrderFront(self)
  }
  
}
