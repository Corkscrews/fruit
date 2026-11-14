import Cocoa
import QuartzCore
import Foundation
import MetalKit

private let metalGlassShaderSource = """
using namespace metal;

struct VertexData {
    float2 position;
};

struct VertexOut {
    float4 position [[position]];
};

vertex VertexOut vertex_shader_glass(
    const device VertexData* vertex_array [[buffer(0)]],
    unsigned int vid [[vertex_id]]) {
    VertexOut out;
    out.position = float4(vertex_array[vid].position, 0.0, 1.0);
    return out;
}

struct GlassUniforms {
    float2 body_origin_px;
    float2 body_size_px;
    float time;
};

// Same slab profile as PuppyLayer: R = bevel ramp, G = crown, B = leafness.
float glass_height(texture2d<float> tex, float2 uv) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 b = tex.sample(s, uv).rgb;
    float k = 1.0 - clamp(b.r, 0.0, 1.0);
    float bevel = sqrt(1.0 - k * k * mix(k, 1.0, b.b));
    return 0.55 * bevel + 0.45 * b.g;
}

// Rotates a colour's hue by `a` radians around the grey axis (Rodrigues).
float3 glass_hue_rotate(float3 c, float a) {
    float3 k = float3(0.57735);
    return c * cos(a) + cross(k, c) * sin(a) + k * dot(k, c) * (1.0 - cos(a));
}

// What sits behind the glass: a polarised-light (photoelastic) sheet with narrow
// fringes. Its hue travels over time and across the logo so no colour settles.
float3 glass_backdrop(float2 p, float t) {
    float2 w = p * 1.6;
    w += 0.55 * float2(sin(w.y * 1.5 + t * 0.21), cos(w.x * 1.2 - t * 0.17));
    w += 0.30 * float2(sin(w.y * 2.9 - t * 0.13 + 1.3), cos(w.x * 2.5 + t * 0.19 + 0.7));
    float f = w.x * 0.8 + w.y * 0.55 + 0.8 * sin(w.x * 1.1 - w.y * 0.7 + t * 0.1) + t * 0.03;

    float3 color = mix(float3(1.0, 0.92, 0.22), float3(1.0, 0.76, 0.10),
                       0.5 + 0.5 * sin(f * 1.7 + w.y * 1.3));
    // Each period gets its own fringe width (x in 0..1 is the fringe, the rest is plain).
    // Seamless: x is 0 at a period's start and past 1 at its end, both outside the band.
    float period = floor(f * 2.1);
    float x = fract(f * 2.1) * mix(1.6, 9.0, fract(sin(period * 12.9898) * 43758.5453));
    float3 fringe = mix(float3(1.0, 0.10, 0.62), float3(0.22, 0.28, 1.0), smoothstep(0.20, 0.45, x));
    fringe = mix(fringe, float3(0.15, 0.92, 1.0), smoothstep(0.42, 0.62, x));
    fringe = mix(fringe, float3(1.0, 1.0, 0.72), smoothstep(0.62, 0.85, x));
    float band = smoothstep(0.0, 0.16, x) * (1.0 - smoothstep(0.84, 1.0, x));
    color = mix(color, fringe, band);
    // About half the hue wheel across the logo at once, a full turn every ~40 s.
    float hue = t * 0.025 + 0.28 * sin(w.x * 0.55 + w.y * 0.4 + t * 0.07);
    return clamp(glass_hue_rotate(color, 6.2832 * hue), 0.0, 1.0);
}

// Distant round lamp, as in PuppyLayer: a soft disc with a wide glow around it.
float glass_lamp(float2 q, float2 center, float radius) {
    float d = length(q - center) / radius;
    return 1.0 - smoothstep(0.0, 1.0, d) + 0.25 * exp(-d * d * 0.8);
}

float3 glass_shade(float2 pos, constant GlassUniforms &uniforms, texture2d<float> height_map) {
    float2 uv = (pos - uniforms.body_origin_px) / uniforms.body_size_px;
    float2 tx = 1.5 / uniforms.body_size_px;
    float hx = glass_height(height_map, uv + float2(tx.x, 0.0))
             - glass_height(height_map, uv - float2(tx.x, 0.0));
    float hy = glass_height(height_map, uv + float2(0.0, tx.y))
             - glass_height(height_map, uv - float2(0.0, tx.y));
    float relief = 0.32 * uniforms.body_size_px.x / 3.0;
    // y flips to point up.
    float3 n = normalize(float3(-hx * relief, hy * relief, 1.0));
    float thickness = 0.25 + glass_height(height_map, uv);

    float t = uniforms.time;
    // Isotropic logo-relative coordinates, y down like the framebuffer.
    float2 p = (uv - 0.5) * uniforms.body_size_px / uniforms.body_size_px.x * 2.0;

    // Refraction: each colour bends by its own index (spread exaggerated so the
    // fringes show at logo size), then travels through the slab to the backdrop.
    float3 iors = float3(1.40, 1.48, 1.57);
    float3 color;
    for (int c = 0; c < 3; c++) {
        float3 r = refract(float3(0.0, 0.0, -1.0), n, 1.0 / iors[c]);
        float2 shift = float2(r.x, -r.y) / max(-r.z, 0.25) * thickness * 1.5;
        color[c] = glass_backdrop(p + shift, t)[c];
    }
    // Steep walls throw the view sideways into the dark room: the dark outline of real glass.
    float wall = 1.0 - smoothstep(0.25, 0.85, n.z);
    color *= mix(1.0, 0.12, wall);
    // Thick glass looks slightly milky and cool, so the backdrop reads as behind something.
    color = mix(color, float3(0.92, 0.96, 1.0), 0.12) * float3(0.98, 0.98, 1.0);

    // Surface reflection of a dim room with two softboxes that sway slowly.
    float3 R = reflect(float3(0.0, 0.0, -1.0), n);
    float2 sway = float2(0.10 * sin(t * 0.33), 0.06 * cos(t * 0.27));
    float3 env = mix(float3(0.03, 0.03, 0.04), float3(0.75, 0.80, 0.90),
                     smoothstep(-0.4, 1.0, R.y));
    env += 12.0 * glass_lamp(R.xy, float2(-0.38, 0.46) + sway, 0.26);
    env += float3(5.0, 5.5, 6.5) * glass_lamp(R.xy, float2(0.60, -0.42) - sway, 0.10);
    env *= smoothstep(-0.6, 0.6, R.z) * 0.85 + 0.15;

    float fresnel = 0.04 + 0.96 * pow(1.0 - clamp(n.z, 0.0, 1.0), 5.0);
    color = color * (1.0 - fresnel) + env * fresnel;
    // Thin bright line just inside the outline: light trapped in the edge by internal reflection.
    // Measured in pixels from the outline (R is distance / bevel width, bevel = 0.16 of the logo),
    // so the leaf, whose edge turns steep within a pixel, gets the same line as the body.
    constexpr sampler rs(filter::linear, address::clamp_to_edge);
    float edge_px = height_map.sample(rs, uv).r * 0.16 * uniforms.body_size_px.x;
    float rim = smoothstep(0.2, 0.9, edge_px) * (1.0 - smoothstep(1.3, 2.4, edge_px));
    color += float3(0.9, 0.95, 1.0) * rim * 1.8;
    return clamp(color, 0.0, 1.0);
}

fragment float4 fragment_shader_glass(
    VertexOut in [[stage_in]],
    constant GlassUniforms &uniforms [[buffer(0)]],
    texture2d<float> height_map [[texture(0)]]) {
    // 4x rotated-grid supersampling, as in PuppyLayer: the highlights alias otherwise.
    float3 color = glass_shade(in.position.xy + float2(-0.125, -0.375), uniforms, height_map)
                 + glass_shade(in.position.xy + float2( 0.375, -0.125), uniforms, height_map)
                 + glass_shade(in.position.xy + float2( 0.125,  0.375), uniforms, height_map)
                 + glass_shade(in.position.xy + float2(-0.375,  0.125), uniforms, height_map);
    return float4(color * 0.25, 1.0);
}
"""

private struct MetalGlassFragmentUniforms {
  // swiftlint:disable identifier_name
  var body_origin_px: SIMD2<Float>
  var body_size_px: SIMD2<Float>
  // swiftlint:enable identifier_name
  var time: Float
}

final class GlassLayer: CAMetalLayer, Background {

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
    guard let other = layer as? GlassLayer else { return }

    // Only copy plain Swift state; presentation copies cannot touch Metal layer state safely.
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
      let library = try metalDevice.makeLibrary(source: metalGlassShaderSource, options: nil)
      guard let vertexFunction = library.makeFunction(name: "vertex_shader_glass"),
            let fragmentFunction = library.makeFunction(name: "fragment_shader_glass") else {
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
    var uniforms = MetalGlassFragmentUniforms(
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
        length: MemoryLayout<MetalGlassFragmentUniforms>.stride,
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
