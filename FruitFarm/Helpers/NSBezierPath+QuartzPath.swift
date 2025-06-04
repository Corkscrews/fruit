import Cocoa

extension NSBezierPath {
  public var quartzPath: CGPath {
    if #available(macOS 14.0, *) {
      return self.cgPath
    }
    // Improved performance: avoid unnecessary array allocations and .copy(),
    // and preallocate points buffer.
    let path = CGMutablePath()
    var didClosePath = true
    // Preallocate a single buffer for points, reused for each element
    let points = UnsafeMutablePointer<NSPoint>.allocate(capacity: 3)
    defer { points.deallocate() }
    for index in 0..<self.elementCount {
      let elementType = self.element(at: index, associatedPoints: points)
      switch elementType {
      case .moveTo:
        path.move(to: points[0])
        didClosePath = false
      case .lineTo:
        path.addLine(to: points[0])
        didClosePath = false
      case .curveTo:
        path.addCurve(to: points[2], control1: points[0], control2: points[1])
        didClosePath = false
      case .closePath:
        path.closeSubpath()
        didClosePath = true
      @unknown default:
        break
      }
    }
    if !didClosePath {
      path.closeSubpath()
    }
    return path
  }
}
