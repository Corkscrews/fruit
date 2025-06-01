import Cocoa

extension NSBezierPath {
  var quartzPath: CGPath {
    if #available(macOS 14.0, *) {
      return self.cgPath
    }
    let path = CGMutablePath()
    var didClosePath = true
    for i in 0..<self.elementCount {
      var points = [NSPoint](repeating: .zero, count: 3)
      switch self.element(at: i, associatedPoints: &points) {
      case .moveTo:
        path.move(to: points[0])
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
    return path.copy()!
  }
}
