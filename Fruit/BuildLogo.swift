//
//  BuildLogo.swift
//  Fruit
//
//  Created by Pedro Paulo de Amorim on 17/02/2020.
//  Copyright © 2020 Pedro Paulo de Amorim. All rights reserved.
//

import Foundation
import Cocoa

@objc
class BuildLogo: NSObject {

  @objc
  static func buildFruit() -> NSBezierPath {

    let path = NSBezierPath()
    path.move(to: CGPoint(x: 110.89, y: 99.2))
    path.curve(to: CGPoint(x: 105.97, y: 108.09), controlPoint1: CGPoint(x: 109.5, y: 102.41), controlPoint2: CGPoint(x: 107.87, y: 105.37))
    path.curve(to: CGPoint(x: 99.64, y: 115.79), controlPoint1: CGPoint(x: 103.39, y: 111.8), controlPoint2: CGPoint(x: 101.27, y: 114.37))
    path.curve(to: CGPoint(x: 91.5, y: 119.4), controlPoint1: CGPoint(x: 97.11, y: 118.13), controlPoint2: CGPoint(x: 94.4, y: 119.33))
    path.curve(to: CGPoint(x: 83.99, y: 117.59), controlPoint1: CGPoint(x: 89.42, y: 119.4), controlPoint2: CGPoint(x: 86.91, y: 118.8))
    path.curve(to: CGPoint(x: 75.9, y: 115.79), controlPoint1: CGPoint(x: 81.06, y: 116.39), controlPoint2: CGPoint(x: 78.36, y: 115.79))
    path.curve(to: CGPoint(x: 67.58, y: 117.59), controlPoint1: CGPoint(x: 73.31, y: 115.79), controlPoint2: CGPoint(x: 70.54, y: 116.39))
    path.curve(to: CGPoint(x: 60.39, y: 119.49), controlPoint1: CGPoint(x: 64.61, y: 118.8), controlPoint2: CGPoint(x: 62.21, y: 119.43))
    path.curve(to: CGPoint(x: 52.07, y: 115.79), controlPoint1: CGPoint(x: 57.6, y: 119.61), controlPoint2: CGPoint(x: 54.83, y: 118.38))
    path.curve(to: CGPoint(x: 45.44, y: 107.82), controlPoint1: CGPoint(x: 50.3, y: 114.24), controlPoint2: CGPoint(x: 48.09, y: 111.58))
    path.curve(to: CGPoint(x: 38.44, y: 93.82), controlPoint1: CGPoint(x: 42.6, y: 103.8), controlPoint2: CGPoint(x: 40.27, y: 99.14))
    path.curve(to: CGPoint(x: 35.5, y: 77.15), controlPoint1: CGPoint(x: 36.48, y: 88.09), controlPoint2: CGPoint(x: 35.5, y: 82.53))
    path.curve(to: CGPoint(x: 39.48, y: 61.21), controlPoint1: CGPoint(x: 35.5, y: 70.98), controlPoint2: CGPoint(x: 36.82, y: 65.67))
    path.curve(to: CGPoint(x: 47.8, y: 52.74), controlPoint1: CGPoint(x: 41.56, y: 57.63), controlPoint2: CGPoint(x: 44.33, y: 54.81))
    path.curve(to: CGPoint(x: 59.06, y: 49.54), controlPoint1: CGPoint(x: 51.27, y: 50.67), controlPoint2: CGPoint(x: 55.02, y: 49.61))
    path.curve(to: CGPoint(x: 67.76, y: 51.58), controlPoint1: CGPoint(x: 61.27, y: 49.54), controlPoint2: CGPoint(x: 64.16, y: 50.23))
    path.curve(to: CGPoint(x: 74.67, y: 53.62), controlPoint1: CGPoint(x: 71.35, y: 52.94), controlPoint2: CGPoint(x: 73.66, y: 53.62))
    path.curve(to: CGPoint(x: 82.33, y: 51.22), controlPoint1: CGPoint(x: 75.42, y: 53.62), controlPoint2: CGPoint(x: 77.98, y: 52.82))
    path.curve(to: CGPoint(x: 92.73, y: 49.36), controlPoint1: CGPoint(x: 86.43, y: 49.73), controlPoint2: CGPoint(x: 89.9, y: 49.12))
    path.curve(to: CGPoint(x: 110.05, y: 58.53), controlPoint1: CGPoint(x: 100.43, y: 49.98), controlPoint2: CGPoint(x: 106.2, y: 53.03))
    path.curve(to: CGPoint(x: 99.83, y: 76.13), controlPoint1: CGPoint(x: 103.17, y: 62.72), controlPoint2: CGPoint(x: 99.77, y: 68.59))
    path.curve(to: CGPoint(x: 106.17, y: 90.76), controlPoint1: CGPoint(x: 99.89, y: 82), controlPoint2: CGPoint(x: 102.01, y: 86.88))
    path.curve(to: CGPoint(x: 112.5, y: 94.94), controlPoint1: CGPoint(x: 108.05, y: 92.56), controlPoint2: CGPoint(x: 110.16, y: 93.95))
    path.curve(to: CGPoint(x: 110.89, y: 99.2), controlPoint1: CGPoint(x: 111.99, y: 96.42), controlPoint2: CGPoint(x: 111.46, y: 97.84))
    path.close()

    

    return path

  }

  @objc
  static func buildLeaf() -> NSBezierPath {

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
  }

}
