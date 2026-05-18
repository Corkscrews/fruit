import Foundation
import Cocoa
import QuartzCore
import MetalKit

protocol Background: AnyObject {
  func config(fruit: Fruit, leaf: Leaf)
  func update(frame: NSRect, fruit: Fruit, leaf: Leaf)
  func update(deltaTime: CGFloat)
}

extension Fruit {
  func bounds(including leaf: Leaf) -> CGRect {
    transformedPath.bounds.union(leaf.transformedPath.bounds)
  }

  func maxDimen(including leaf: Leaf) -> CGFloat {
    let bounds = bounds(including: leaf)
    return max(bounds.width, bounds.height)
  }
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
