import Foundation
import Cocoa

protocol Background: AnyObject {
  func config(fruit: Fruit)
  func update(frame: NSRect, fruit: Fruit)
  func update(deltaTime: CGFloat)
}

extension Background where Self: CALayer {
  func config(fruit: Fruit) {
    fatalError("Must override config(fruit:)")
  }
  func update(frame: NSRect, fruit: Fruit) {
    fatalError("Must override update(frame:)")
  }
  func update(deltaTime: CGFloat) {
    fatalError("Must override update(deltaTime:)")
  }
}
