import Cocoa

final class Leaf {
  let originalPath: NSBezierPath
  private(set) var transformedPath: NSBezierPath

  init() {
    self.originalPath = {
      let path = NSBezierPath()
      path.move(to: CGPoint(x: 93.25, y: 29.36))
      path.curve(to: CGPoint(x: 88.25, y: 42.23), controlPoint1: CGPoint(x: 93.25, y: 33.96), controlPoint2: CGPoint(x: 91.58, y: 38.26))
      path.curve(to: CGPoint(x: 74.1, y: 49.26), controlPoint1: CGPoint(x: 84.23, y: 46.96), controlPoint2: CGPoint(x: 79.37, y: 49.69))
      path.curve(to: CGPoint(x: 74, y: 47.52), controlPoint1: CGPoint(x: 74.03, y: 48.71), controlPoint2: CGPoint(x: 74, y: 48.13))
      path.curve(to: CGPoint(x: 79.3, y: 34.51), controlPoint1: CGPoint(x: 74, y: 43.1), controlPoint2: CGPoint(x: 75.91, y: 38.38))
      path.curve(to: CGPoint(x: 85.76, y: 29.63), controlPoint1: CGPoint(x: 80.99, y: 32.55), controlPoint2: CGPoint(x: 83.15, y: 30.93))
      path.curve(to: CGPoint(x: 93.15, y: 27.52), controlPoint1: CGPoint(x: 88.37, y: 28.35), controlPoint2: CGPoint(x: 90.83, y: 27.65))
      path.curve(to: CGPoint(x: 93.25, y: 29.36), controlPoint1: CGPoint(x: 93.22, y: 28.14), controlPoint2: CGPoint(x: 93.25, y: 28.75))
      path.line(to: CGPoint(x: 93.25, y: 29.36))
      path.close()
      return path
    }()
    self.transformedPath = self.originalPath.copy() as! NSBezierPath
  }

  func applyTransforms(transform: Transform) {
    let path = originalPath.copy() as! NSBezierPath
    path.transform(using: transform.rotation as AffineTransform)
    path.transform(using: transform.scale as AffineTransform)
    path.transform(using: transform.translation as AffineTransform)
    self.transformedPath = path
  }
}
