import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
  var window: NSWindow?

  func applicationDidFinishLaunching(_ aNotification: Notification) {
    window = NSWindow(contentViewController: PreferencesViewController())
    window?.title = "FruitShop"
    window?.makeKeyAndOrderFront(self)
  }

}
