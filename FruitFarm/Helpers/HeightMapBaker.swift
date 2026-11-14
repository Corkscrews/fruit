import Cocoa
import Foundation
import MetalKit
import Accelerate

// Baked at 2x and averaged down so the bevel isn't built on the mask's pixel staircase.
private let heightSupersampling = 2

enum HeightMapBaker {

  /// Rasterises the fruit and leaf vector paths into the two height channels the
  /// shader reads: R = bevel ramp from an exact distance transform (so the round-over
  /// starts right on the outline), G = wide blur for the crown.
  /// Takes path copies, not Fruit/Leaf, so it can run off the main thread.
  static func bake(
    device: MTLDevice?, rect: CGRect, contentsScale: CGFloat, fruitPath: CGPath, leafPath: CGPath
  ) -> MTLTexture? {
    let width = Int(rect.width * contentsScale)
    let height = Int(rect.height * contentsScale)
    let bigWidth = width * heightSupersampling, bigHeight = height * heightSupersampling
    let bigScale = contentsScale * CGFloat(heightSupersampling)
    guard let device = device, width > 0, height > 0,
          let context = CGContext(
            data: nil, width: bigWidth, height: bigHeight, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
          ) else { return nil }
    // CGContext memory already starts at the top row, matching Metal's texture rows.
    context.scaleBy(x: bigScale, y: bigScale)
    context.translateBy(x: -rect.minX, y: -rect.minY)
    context.setFillColor(gray: 1, alpha: 1)
    context.addPath(fruitPath)
    context.addPath(leafPath)
    context.fillPath()
    guard let maskData = context.data else { return nil }

    let logoWidth = Float(fruitPath.boundingBoxOfPath.width * bigScale)
    let mask = maskData.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * bigHeight)
    let (ramp, initialCrown) = bevelAndCrown(
      mask: mask, stride: context.bytesPerRow, width: bigWidth, height: bigHeight, logoWidth: logoWidth
    )

    // Wide dome for the body only, so its centre isn't flat. Re-fill the mask with just the leaf.
    context.clear(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height))
    context.addPath(leafPath)
    context.fillPath()
    var crown = initialCrown
    let leafness = addDome(
      to: &crown, mask: (bytes: mask, stride: context.bytesPerRow), width: bigWidth, height: bigHeight,
      logoWidth: logoWidth
    )

    let packed = packHeights(
      ramp: ramp, crown: crown, leafness: leafness, width: width, height: height
    )
    return makeTexture(device: device, packed: packed, width: width, height: height)
  }

  /// Bevel ramp (distance from the outline, 0 at the edge) and the unblurred crown of the fruit and leaf mask.
  private static func bevelAndCrown(
    mask: UnsafePointer<UInt8>, stride: Int, width: Int, height: Int, logoWidth: Float
  ) -> (ramp: [Float], crown: [Float]) {
    var ramp = [Float](repeating: 0, count: width * height)
    var crown = [Float](repeating: 0, count: width * height)
    for row in 0..<height {
      for column in 0..<width where mask[row * stride + column] > 127 {
        ramp[row * width + column] = 1e20
        crown[row * width + column] = 1
      }
    }
    squaredDistanceTransform(&ramp, width: width, height: height)
    let bevelPx = logoWidth * 0.16
    for index in ramp.indices {
      ramp[index] = min(max(ramp[index].squareRoot() - 0.5, 0) / bevelPx, 1)
    }
    // Exact float blurs: Core Image's large Gaussian approximates and striped the face.
    gaussianBlur(&ramp, width: width, height: height, sigma: logoWidth * 0.008)
    return (ramp, crown)
  }

  /// Adds a wide dome to the crown on the body (not on the leaf) and returns the leafness field.
  private static func addDome(
    to crown: inout [Float], mask: (bytes: UnsafeMutablePointer<UInt8>, stride: Int), width: Int, height: Int,
    logoWidth: Float
  ) -> [Float] {
    var dome = [Float](repeating: 0, count: width * height)
    var leafDistance = [Float](repeating: 1e20, count: width * height)
    for row in 0..<height {
      for column in 0..<width {
        let index = row * width + column
        if mask.bytes[row * mask.stride + column] > 127 {
          leafDistance[index] = 0
        } else {
          dome[index] = crown[index]
        }
      }
    }
    squaredDistanceTransform(&leafDistance, width: width, height: height)
    gaussianBlur(&dome, width: width, height: height, sigma: logoWidth * 0.35)
    gaussianBlur(&crown, width: width, height: height, sigma: logoWidth * 0.16)
    let domePeak = max(dome.max() ?? 1, 1e-6)
    let leafFade = logoWidth * 0.03
    for index in crown.indices {
      // Zero on the leaf (plus the 2 texels the shader's normals sample), full strength across the gap.
      let weight = min(max(leafDistance[index].squareRoot() - Float(heightSupersampling * 3), 0) / leafFade, 1)
      crown[index] += 0.8 * weight * dome[index] / domePeak
      leafDistance[index] = 1 - weight  // now "leafness", 1 on the leaf
    }
    return leafDistance
  }

  /// Averages each supersampled block down to one texel of (ramp, crown, leafness, unused).
  private static func packHeights(
    ramp: [Float], crown: [Float], leafness: [Float], width: Int, height: Int
  ) -> [Float] {
    var packed = [Float](repeating: 0, count: width * height * 4)
    let bigWidth = width * heightSupersampling
    let area = Float(heightSupersampling * heightSupersampling)
    for row in 0..<height {
      for column in 0..<width {
        var rSum: Float = 0, gSum: Float = 0, bSum: Float = 0
        for subRow in 0..<heightSupersampling {
          for subColumn in 0..<heightSupersampling {
            let index = (row * heightSupersampling + subRow) * bigWidth + column * heightSupersampling + subColumn
            rSum += ramp[index]
            gSum += crown[index]
            bSum += leafness[index]
          }
        }
        let base = (row * width + column) * 4
        packed[base] = rSum / area
        packed[base + 1] = gSum / area
        packed[base + 2] = bSum / area
      }
    }
    return packed
  }

  private static func makeTexture(device: MTLDevice, packed: [Float], width: Int, height: Int) -> MTLTexture? {
    // 32-bit float: 8-bit or half-float heights stair-step the mirrored highlights.
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false
    )
    descriptor.usage = [.shaderRead]
    guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
    packed.withUnsafeBytes { bytes in
      texture.replace(
        region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
        withBytes: bytes.baseAddress!, bytesPerRow: width * 4 * MemoryLayout<Float>.stride
      )
    }
    return texture
  }

  /// Gaussian approximated by three box blurs per axis (running sums, zero outside).
  private static func gaussianBlur(_ grid: inout [Float], width: Int, height: Int, sigma: Float) {
    // 6 box passes: 3 left curvature kinks the glossy shading showed as straight lines.
    let passes = 6
    let radius = Int((((1 + 12 * sigma * sigma / Float(passes)).squareRoot()) - 1) / 2 + 0.5)
    guard radius > 0 else { return }
    // All passes run in a padded line so the spill past the edge is kept; cropping it
    // between passes left straight creases. Exact, since rows outside the grid are empty.
    let pad = passes * radius
    let window = vDSP_Length(2 * radius + 1)
    var norm = 1 / Double(window)
    // vDSP, not Swift loops: this is most of the bake and a debug build ran it ~50x slower.
    // `radius` extra zeros on each side keep the sliding window inside the buffer.
    var src = [Double](repeating: 0, count: max(width, height) + 2 * pad + 2 * radius)
    var dst = src
    grid.withUnsafeMutableBufferPointer { cells in
      src.withUnsafeMutableBufferPointer { srcBuffer in
        dst.withUnsafeMutableBufferPointer { dstBuffer in
          guard let cells = cells.baseAddress, var from = srcBuffer.baseAddress,
                var destination = dstBuffer.baseAddress else { return }
          func blurLine(start: Int, step: Int, count: Int) {
            let total = vDSP_Length(count + 2 * pad)
            vDSP_vclrD(from, 1, total + 2 * vDSP_Length(radius))
            vDSP_vspdp(cells + start, step, from + radius + pad, 1, vDSP_Length(count))
            for _ in 0..<passes {
              vDSP_vswsumD(from, 1, destination + radius, 1, total, window)
              vDSP_vsmulD(destination + radius, 1, &norm, destination + radius, 1, total)
              swap(&from, &destination)
            }
            vDSP_vdpsp(from + radius + pad, 1, cells + start, step, vDSP_Length(count))
          }
          for row in 0..<height { blurLine(start: row * width, step: 1, count: width) }
          for column in 0..<width { blurLine(start: column, step: width, count: height) }
        }
      }
    }
  }

  /// Felzenszwalb–Huttenlocher squared Euclidean distance transform, in place.
  /// Input: 0 at outside pixels, a huge value inside. Rows first, then columns.
  private static func squaredDistanceTransform(_ grid: inout [Float], width: Int, height: Int) {
    let longest = max(width, height)
    var sites = [Int](repeating: 0, count: longest)
    var breaks = [Float](repeating: 0, count: longest + 1)
    var line = [Float](repeating: 0, count: longest)
    func pass(start: Int, step: Int, count: Int) {
      for position in 0..<count { line[position] = grid[start + position * step] }
      var envelope = 0
      sites[0] = 0
      breaks[0] = -.infinity
      breaks[1] = .infinity
      for position in 1..<count {
        var boundary: Float
        repeat {
          let previous = sites[envelope]
          boundary = ((line[position] + Float(position * position))
                      - (line[previous] + Float(previous * previous)))
            / Float(2 * (position - previous))
          envelope -= 1
        } while boundary <= breaks[envelope + 1]
        envelope += 2
        sites[envelope] = position
        breaks[envelope] = boundary
        breaks[envelope + 1] = .infinity
      }
      envelope = 0
      for position in 0..<count {
        while breaks[envelope + 1] < Float(position) { envelope += 1 }
        let site = sites[envelope]
        grid[start + position * step] = Float((position - site) * (position - site)) + line[site]
      }
    }
    for row in 0..<height { pass(start: row * width, step: 1, count: width) }
    for column in 0..<width { pass(start: column, step: width, count: height) }
  }
}
