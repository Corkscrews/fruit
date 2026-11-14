import Cocoa
import QuartzCore
import Foundation
import MetalKit

private let metalPuppyShaderSource = """
using namespace metal;

struct VertexData {
    float2 position;
};

struct VertexOut {
    float4 position [[position]];
};

vertex VertexOut vertex_shader_puppy(
    const device VertexData* vertex_array [[buffer(0)]],
    unsigned int vid [[vertex_id]]) {
    VertexOut out;
    out.position = float4(vertex_array[vid].position, 0.0, 1.0);
    return out;
}

struct PuppyUniforms {
    float2 body_origin_px;
    float2 body_size_px;
    float time;
};

// Height of the logo slab. R = distance inward from the outline as a 0..1 ramp
// across the bevel, G = wide blur of the silhouette (slight crown on the face).
float puppy_height(texture2d<float> tex, float2 uv) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 b = tex.sample(s, uv).rgb;
    float k = 1.0 - clamp(b.r, 0.0, 1.0);
    // Body (B = 0): cubic, so curvature fades to zero where the bevel meets the face (no ring line).
    // Leaf (B = 1): the original quarter circle.
    float bevel = sqrt(1.0 - k * k * mix(k, 1.0, b.b));
    return 0.55 * bevel + 0.45 * b.g;
}

// Distant round lamp: a soft disc with a wide glow around it.
float puppy_lamp(float2 q, float2 center, float radius) {
    float d = length(q - center) / radius;
    return 1.0 - smoothstep(0.0, 1.0, d) + 0.25 * exp(-d * d * 0.8);
}

float3 puppy_shade(float2 pos, constant PuppyUniforms &uniforms, texture2d<float> height_map) {
    float2 uv = (pos - uniforms.body_origin_px) / uniforms.body_size_px;
    float2 tx = 1.5 / uniforms.body_size_px;
    float hx = puppy_height(height_map, uv + float2(tx.x, 0.0))
             - puppy_height(height_map, uv - float2(tx.x, 0.0));
    float hy = puppy_height(height_map, uv + float2(0.0, tx.y))
             - puppy_height(height_map, uv - float2(0.0, tx.y));

    // Relief depth as a fraction of the logo width; y flips to point up.
    float relief = 0.32 * uniforms.body_size_px.x / 3.0;
    float3 n = normalize(float3(-hx * relief, hy * relief, 1.0));

    float t = uniforms.time;
    float3 V = float3(0.0, 0.0, 1.0);
    // Light orbits the logo in a full circle
    float orbit = t * 0.35;
    float3 L = normalize(float3(0.75 * cos(orbit), 0.75 * sin(orbit), 0.66));

    // Key light slowly cycles through hues; the white body takes on its colour
    float hue = t * 0.04;
    float3 light_color = mix(float3(1.0), 0.5 + 0.5 * cos(6.2832 * (hue + float3(0.0, 0.33, 0.67))), 0.85);

    // Lacquer painted the light's colour, so the hue reads strongly on both lit and shadow sides
    float diff = max(dot(n, L), 0.0);
    float3 color = light_color * light_color * (0.12 + 0.88 * diff);
    // Global light wraps the whole object, a bit stronger on the side away from the key
    float3 fill_dir = normalize(float3(-L.xy, 0.6));
    color += light_color * (0.08 + 0.14 * max(dot(n, fill_dir), 0.0));

    // Clear coat: mirror a studio (sky over a dark room) off the surface
    float3 R = reflect(-V, n);
    // Bright side of the room faces the orbiting light, so no reflection stays fixed
    float3 env = mix(float3(0.02, 0.02, 0.03), float3(0.55, 0.62, 0.75),
                     smoothstep(-0.3, 1.0, dot(R.xy, normalize(L.xy))));
    // Round lamps far away, mirrored off the surface; the key sits along L so it matches the shading
    env += 14.0 * light_color * puppy_lamp(R.xy, L.xy, 0.32);
    env += 5.5 * light_color * puppy_lamp(R.xy, -L.xy * float2(1.0, 0.9), 0.12);
    // Soft horizon: a hard step here drew a band along the outline where the tilt passes 45°
    env *= smoothstep(-0.6, 0.6, R.z) * 0.85 + 0.15;

    float fresnel = 0.06 + 0.94 * pow(1.0 - clamp(n.z, 0.0, 1.0), 5.0);
    color = color * (1.0 - fresnel) + env * fresnel;

    return clamp(color, 0.0, 1.0);
}

uint puppy_hash(uint h) {
    h = (h ^ (h >> 16)) * 0x7feb352du;
    h = (h ^ (h >> 15)) * 0x846ca68bu;
    return h ^ (h >> 16);
}

// Camera grain: one fixed value per screen pixel, triangular like real sensor noise.
float puppy_grain(float2 pixel) {
    uint h = puppy_hash(uint(pixel.x) + puppy_hash(uint(pixel.y)));
    return float(h & 0xffffu) / 65535.0 + float(h >> 16) / 65535.0 - 1.0;
}

fragment float4 fragment_shader_puppy(
    VertexOut in [[stage_in]],
    constant PuppyUniforms &uniforms [[buffer(0)]],
    texture2d<float> height_map [[texture(0)]]) {
    // 4x rotated-grid supersampling: the HDR reflections flip on within a pixel
    // and alias badly; each sample is clamped before averaging so they resolve smoothly.
    float3 color = puppy_shade(in.position.xy + float2(-0.125, -0.375), uniforms, height_map)
                 + puppy_shade(in.position.xy + float2( 0.375, -0.125), uniforms, height_map)
                 + puppy_shade(in.position.xy + float2( 0.125,  0.375), uniforms, height_map)
                 + puppy_shade(in.position.xy + float2(-0.375,  0.125), uniforms, height_map);
    color *= 0.25;
    // Faint grain, applied after the AA average so it stays one pixel fine. Scaling the colour
    // (not adding to it) only varies brightness, so the grain stays monochrome on any hue.
    color *= 1.0 + 0.06 * puppy_grain(in.position.xy);
    return float4(clamp(color, 0.0, 1.0), 1.0);
}
"""

private struct MetalPuppyFragmentUniforms {
  // swiftlint:disable identifier_name
  var body_origin_px: SIMD2<Float>
  var body_size_px: SIMD2<Float>
  // swiftlint:enable identifier_name
  var time: Float
}

final class PuppyLayer: CAMetalLayer, Background {

  // MARK: - Metal Objects
  private var metalDevice: MTLDevice?
  private var commandQueue: MTLCommandQueue?
  private var pipelineState: MTLRenderPipelineState?
  private var vertexBuffer: MTLBuffer?
  private var heightTexture: MTLTexture?
  /// Logo rect (points) the height texture was baked for; rebaked when it changes.
  private var bakedRect = CGRect.null

  // MARK: - Animation
  private var totalElapsedTime: CGFloat = 0
  private var lastUpdateTime: CGFloat = 0
  private let minUpdateInterval: CGFloat = 1.0 / 30.0

  deinit {
    heightTexture = nil
    vertexBuffer = nil
    pipelineState = nil
    commandQueue = nil
    metalDevice = nil
  }

  // MARK: - Initialization
  init(frame: CGRect, fruit: Fruit, leaf: Leaf, contentsScale: CGFloat) {
    super.init()
    self.frame = frame
    self.contentsScale = contentsScale
    self.currentFruit = fruit
    self.currentLeaf = leaf
    self.pixelFormat = .bgra8Unorm
    self.isOpaque = true
    self.framebufferOnly = true

    setupMetal()
    setupPipeline()
    createVertexBuffers()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override init(layer: Any) {
    super.init(layer: layer)
    guard let other = layer as? PuppyLayer else { return }
    self.totalElapsedTime = other.totalElapsedTime
  }

  private func setupMetal() {
    guard let device = MTLCreateSystemDefaultDevice() else { return }
    self.metalDevice = device
    self.device = device

    guard let commandQueue = device.makeCommandQueue() else { return }
    self.commandQueue = commandQueue
  }

  private func setupPipeline() {
    guard let metalDevice = metalDevice else { return }
    do {
      let library = try metalDevice.makeLibrary(source: metalPuppyShaderSource, options: nil)
      guard let vertexFunction = library.makeFunction(name: "vertex_shader_puppy"),
            let fragmentFunction = library.makeFunction(name: "fragment_shader_puppy") else {
        return
      }

      let pipelineDescriptor = MTLRenderPipelineDescriptor()
      pipelineDescriptor.vertexFunction = vertexFunction
      pipelineDescriptor.fragmentFunction = fragmentFunction
      pipelineDescriptor.colorAttachments[0].pixelFormat = self.pixelFormat

      pipelineState = try metalDevice.makeRenderPipelineState(descriptor: pipelineDescriptor)
    } catch {
      return
    }
  }

  private func createVertexBuffers() {
    let vertices: [SIMD2<Float>] = [
      SIMD2<Float>(-1.0, -1.0), SIMD2<Float>( 1.0, -1.0), SIMD2<Float>(-1.0, 1.0),
      SIMD2<Float>( 1.0, -1.0), SIMD2<Float>( 1.0, 1.0), SIMD2<Float>(-1.0, 1.0)
    ]
    vertexBuffer = metalDevice?.makeBuffer(
      bytes: vertices,
      length: MemoryLayout<SIMD2<Float>>.stride * vertices.count,
      options: .storageModeShared
    )
  }

  /// Rasterises the fruit and leaf vector paths into the two height channels the
  /// shader reads: R = bevel ramp from an exact distance transform (so the round-over
  /// starts right on the outline), G = wide blur for the crown.
  /// Static and non-private: GlassLayer bakes the same map.
  static func bakeHeightTexture(
    device: MTLDevice?, rect: CGRect, contentsScale cs: CGFloat, fruit: Fruit, leaf: Leaf
  ) -> MTLTexture? {
    let width = Int(rect.width * cs)
    let height = Int(rect.height * cs)
    // Baked at 2x and averaged down so the bevel isn't built on the mask's pixel staircase.
    let ss = 2
    let bigW = width * ss, bigH = height * ss
    let bigScale = cs * CGFloat(ss)
    guard let device = device, width > 0, height > 0,
          let context = CGContext(
            data: nil, width: bigW, height: bigH, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
          ) else { return nil }
    // CGContext memory already starts at the top row, matching Metal's texture rows.
    context.scaleBy(x: bigScale, y: bigScale)
    context.translateBy(x: -rect.minX, y: -rect.minY)
    context.setFillColor(gray: 1, alpha: 1)
    context.addPath(fruit.transformedPath.quartzPath)
    context.addPath(leaf.transformedPath.quartzPath)
    context.fillPath()
    guard let maskData = context.data else { return nil }

    let logoWidth = Float(fruit.transformedPath.bounds.width * bigScale)
    let maskBytes = maskData.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * bigH)
    var ramp = [Float](repeating: 0, count: bigW * bigH)
    var crown = [Float](repeating: 0, count: bigW * bigH)
    for y in 0..<bigH {
      for x in 0..<bigW where maskBytes[y * context.bytesPerRow + x] > 127 {
        ramp[y * bigW + x] = 1e20
        crown[y * bigW + x] = 1
      }
    }
    PuppyLayer.squaredDistanceTransform(&ramp, width: bigW, height: bigH)
    let bevelPx = logoWidth * 0.16
    for index in ramp.indices {
      ramp[index] = min(max(ramp[index].squareRoot() - 0.5, 0) / bevelPx, 1)
    }
    // Exact float blurs: Core Image's large Gaussian approximates and striped the face.
    PuppyLayer.gaussianBlur(&ramp, width: bigW, height: bigH, sigma: logoWidth * 0.008)

    // Wide dome for the body only, so its centre isn't flat. Re-fill the mask with just the leaf.
    context.clear(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height))
    context.addPath(leaf.transformedPath.quartzPath)
    context.fillPath()
    var dome = [Float](repeating: 0, count: bigW * bigH)
    var leafDistance = [Float](repeating: 1e20, count: bigW * bigH)
    for y in 0..<bigH {
      for x in 0..<bigW {
        let index = y * bigW + x
        if maskBytes[y * context.bytesPerRow + x] > 127 {
          leafDistance[index] = 0
        } else {
          dome[index] = crown[index]
        }
      }
    }
    PuppyLayer.squaredDistanceTransform(&leafDistance, width: bigW, height: bigH)
    PuppyLayer.gaussianBlur(&dome, width: bigW, height: bigH, sigma: logoWidth * 0.35)
    PuppyLayer.gaussianBlur(&crown, width: bigW, height: bigH, sigma: logoWidth * 0.16)
    let domePeak = max(dome.max() ?? 1, 1e-6)
    let leafFade = logoWidth * 0.03
    for index in crown.indices {
      // Zero on the leaf (plus the 2 texels the shader's normals sample), full strength across the gap.
      let weight = min(max(leafDistance[index].squareRoot() - Float(ss * 3), 0) / leafFade, 1)
      crown[index] += 0.8 * weight * dome[index] / domePeak
      leafDistance[index] = 1 - weight  // now "leafness", 1 on the leaf
    }

    // R = bevel ramp, G = crown, B = leafness, each the average of its 2x2 block.
    var packed = [Float](repeating: 0, count: width * height * 4)
    let area = Float(ss * ss)
    for y in 0..<height {
      for x in 0..<width {
        var rSum: Float = 0, gSum: Float = 0, bSum: Float = 0
        for dy in 0..<ss {
          for dx in 0..<ss {
            let index = (y * ss + dy) * bigW + x * ss + dx
            rSum += ramp[index]
            gSum += crown[index]
            bSum += leafDistance[index]
          }
        }
        packed[(y * width + x) * 4] = rSum / area
        packed[(y * width + x) * 4 + 1] = gSum / area
        packed[(y * width + x) * 4 + 2] = bSum / area
      }
    }

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
    let norm = 1 / Double(2 * radius + 1)
    var src = [Double](repeating: 0, count: max(width, height) + 2 * pad)
    var dst = src
    func blurLine(start: Int, step: Int, count: Int) {
      let total = count + 2 * pad
      for q in 0..<total { src[q] = 0 }
      for q in 0..<count { src[pad + q] = Double(grid[start + q * step]) }
      for _ in 0..<passes {
        var sum: Double = 0
        for q in 0..<radius { sum += src[q] }
        for q in 0..<total {
          if q + radius < total { sum += src[q + radius] }
          dst[q] = sum * norm
          if q >= radius { sum -= src[q - radius] }
        }
        swap(&src, &dst)
      }
      for q in 0..<count { grid[start + q * step] = Float(src[pad + q]) }
    }
    for y in 0..<height { blurLine(start: y * width, step: 1, count: width) }
    for x in 0..<width { blurLine(start: x, step: width, count: height) }
  }

  /// Felzenszwalb–Huttenlocher squared Euclidean distance transform, in place.
  /// Input: 0 at outside pixels, a huge value inside. Rows first, then columns.
  private static func squaredDistanceTransform(_ grid: inout [Float], width: Int, height: Int) {
    let longest = max(width, height)
    var sites = [Int](repeating: 0, count: longest)
    var breaks = [Float](repeating: 0, count: longest + 1)
    var line = [Float](repeating: 0, count: longest)
    func pass(start: Int, step: Int, count: Int) {
      for q in 0..<count { line[q] = grid[start + q * step] }
      var k = 0
      sites[0] = 0
      breaks[0] = -.infinity
      breaks[1] = .infinity
      for q in 1..<count {
        var s: Float
        repeat {
          let p = sites[k]
          s = ((line[q] + Float(q * q)) - (line[p] + Float(p * p))) / Float(2 * (q - p))
          k -= 1
        } while s <= breaks[k + 1]
        k += 2
        sites[k] = q
        breaks[k] = s
        breaks[k + 1] = .infinity
      }
      k = 0
      for q in 0..<count {
        while breaks[k + 1] < Float(q) { k += 1 }
        let p = sites[k]
        grid[start + q * step] = Float((q - p) * (q - p)) + line[p]
      }
    }
    for y in 0..<height { pass(start: y * width, step: 1, count: width) }
    for x in 0..<width { pass(start: x, step: width, count: height) }
  }

  private weak var currentFruit: Fruit?
  private weak var currentLeaf: Leaf?

  // MARK: - Background Protocol
  func update(frame: NSRect, fruit: Fruit, leaf: Leaf) {
    currentFruit = fruit
    currentLeaf = leaf
    setFrameAndDrawableSizeWithoutAnimation(frame)
    setNeedsDisplay()
  }

  func config(fruit: Fruit, leaf: Leaf) {
    currentFruit = fruit
    currentLeaf = leaf
    setNeedsDisplay()
  }

  func update(deltaTime: CGFloat) {
    totalElapsedTime += deltaTime
    lastUpdateTime += deltaTime

    if lastUpdateTime >= minUpdateInterval {
      lastUpdateTime = 0
      setNeedsDisplay()
    }
  }

  // MARK: - Drawing
  override func display() {
    guard let pipelineState = pipelineState,
          let commandQueue = commandQueue,
          let vertexBuffer = vertexBuffer,
          let fruit = currentFruit,
          let leaf = currentLeaf,
          let drawable = nextDrawable() else { return }
    let texture = drawable.texture

    // The paths are re-transformed after layout, so check here rather than in update(frame:).
    let rect = fruit.bounds(including: leaf).insetBy(dx: -4, dy: -4)
    if rect != bakedRect {
      bakedRect = rect
      heightTexture = PuppyLayer.bakeHeightTexture(
        device: metalDevice, rect: rect, contentsScale: contentsScale, fruit: fruit, leaf: leaf
      )
    }

    let cs = contentsScale
    var uniforms = MetalPuppyFragmentUniforms(
      body_origin_px: SIMD2<Float>(Float(rect.minX * cs), Float((bounds.height - rect.maxY) * cs)),
      body_size_px: SIMD2<Float>(Float(rect.width * cs), Float(rect.height * cs)),
      time: Float(totalElapsedTime)
    )

    let renderPassDescriptor = MTLRenderPassDescriptor()
    renderPassDescriptor.colorAttachments[0].texture = texture
    renderPassDescriptor.colorAttachments[0].loadAction = .clear
    renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(
      red: 0, green: 0, blue: 0, alpha: 1
    )

    guard let commandBuffer = commandQueue.makeCommandBuffer(),
          let renderEncoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: renderPassDescriptor
          ) else {
      return
    }

    if let heightTexture = heightTexture {
      renderEncoder.setRenderPipelineState(pipelineState)
      let sx = max(0, Int(rect.minX * cs))
      let sy = max(0, Int((bounds.height - rect.maxY) * cs))
      let sw = min(Int(rect.width * cs), texture.width - sx)
      let sh = min(Int(rect.height * cs), texture.height - sy)
      if sw > 0 && sh > 0 {
        renderEncoder.setScissorRect(MTLScissorRect(x: sx, y: sy, width: sw, height: sh))
      }
      renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
      renderEncoder.setFragmentBytes(
        &uniforms,
        length: MemoryLayout<MetalPuppyFragmentUniforms>.stride,
        index: 0
      )
      renderEncoder.setFragmentTexture(heightTexture, index: 0)
      renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    renderEncoder.endEncoding()
    commandBuffer.present(drawable)
    commandBuffer.commit()
  }
}
