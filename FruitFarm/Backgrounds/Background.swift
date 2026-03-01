import Foundation
import Cocoa
import QuartzCore
import MetalKit

protocol Background: AnyObject {
  func config(fruit: Fruit)
  func update(frame: NSRect, fruit: Fruit)
  func update(deltaTime: CGFloat)
}

extension CALayer {
  func setFrameWithoutAnimation(_ frame: CGRect) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    self.frame = frame
    CATransaction.commit()
  }
}

extension CAMetalLayer {
  func setFrameAndDrawableSizeWithoutAnimation(_ frame: CGRect) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    self.frame = frame
    self.drawableSize = CGSize(
      width: frame.width * contentsScale,
      height: frame.height * contentsScale
    )
    CATransaction.commit()
  }
}
