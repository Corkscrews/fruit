import Cocoa

struct TransformHelpers {
  static func rotationTransform(_ angle: CGFloat, cp: NSPoint) -> NSAffineTransform {
    let xfm = NSAffineTransform()
    xfm.translateX(by: cp.x, yBy: cp.y)
    xfm.rotate(byRadians: angle)
    xfm.scaleX(by: -1.0, yBy: 1.0)
    xfm.translateX(by: -cp.x, yBy: -cp.y)
    return xfm
  }
  static func translationTransform(_ cp: NSPoint) -> NSAffineTransform {
    let xfm = NSAffineTransform()
    xfm.translateX(by: cp.x, yBy: cp.y)
    return xfm
  }
  static func scaleTransform(_ scale: CGFloat) -> NSAffineTransform {
    let xfm = NSAffineTransform()
    xfm.scaleX(by: scale, yBy: scale)
    return xfm
  }
}
