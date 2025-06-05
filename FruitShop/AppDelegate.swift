import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
  var window: NSWindow?

  func applicationDidFinishLaunching(_ aNotification: Notification) {
    window = NSWindow(
      contentViewController: PreferencesViewController(
        preferencesRepository: PreferencesRepositoryImpl()
      )
    )
    window?.title = "FruitShop"
    window?.makeKeyAndOrderFront(self)
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

}
