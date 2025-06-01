import Cocoa

struct TransformHelpers {
  static func rotationTransform(_ angle: CGFloat, point: NSPoint) -> NSAffineTransform {
    let xfm = translationTransform(point)
    xfm.rotate(byRadians: angle)
    xfm.scaleX(by: -1.0, yBy: 1.0)
    xfm.translateX(by: -point.x, yBy: -point.y)
    return xfm
  }
  static func translationTransform(_ point: NSPoint) -> NSAffineTransform {
    let xfm = NSAffineTransform()
    xfm.translateX(by: point.x, yBy: point.y)
    return xfm
  }
  static func scaleTransform(_ scale: CGFloat) -> NSAffineTransform {
    let xfm = NSAffineTransform()
    xfm.scaleX(by: scale, yBy: scale)
    return xfm
  }
}
