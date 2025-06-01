import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
  var window: NSWindow?

  func applicationDidFinishLaunching(_ aNotification: Notification) {
    window = NSWindow(contentViewController: FruitShopViewController())
    window?.title = "FruitShop"
    window?.makeKeyAndOrderFront(self)
  }

//  private var preferencesWindowController: PreferencesViewController?
//
//  func launchPreferencesWindow() {
//    if preferencesWindowController == nil {
//      preferencesWindowController = PreferencesViewController()
//    }
//    guard let preferencesWindowController = preferencesWindowController else { return }
//
//    if preferencesWindowController.view.window == nil {
//      let window = NSWindow(contentViewController: preferencesWindowController)
//      window.title = "Preferences"
//      window.styleMask.insert(.titled)
//      window.styleMask.insert(.closable)
//      window.styleMask.insert(.miniaturizable)
//      window.styleMask.insert(.resizable)
//      window.setFrameAutosaveName("PreferencesWindow")
////      preferencesWindowController.view.window?.delegate = preferencesWindowController
//      window.center()
//      window.makeKeyAndOrderFront(self)
//    } else {
//      preferencesWindowController.view.window?.makeKeyAndOrderFront(self)
//    }
//    NSApp.activate(ignoringOtherApps: true)
//  }

}
