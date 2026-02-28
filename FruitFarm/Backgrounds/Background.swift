import Foundation
import Cocoa

protocol Background: AnyObject {
  func config(fruit: Fruit)
  func update(frame: NSRect, fruit: Fruit)
  func update(deltaTime: CGFloat)
}
