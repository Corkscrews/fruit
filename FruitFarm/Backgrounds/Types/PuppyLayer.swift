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
// Returns (full height, crown only); the crown is the soft shape the subsurface light sees.
float2 puppy_height(texture2d<float> tex, float2 uv) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 b = tex.sample(s, uv).rgb;
    float k = 1.0 - clamp(b.r, 0.0, 1.0);
    // Body (B = 0): cubic, so curvature fades to zero where the bevel meets the face (no ring line).
    // Leaf (B = 1): the original quarter circle.
    float bevel = sqrt(1.0 - k * k * mix(k, 1.0, b.b));
    return float2(0.55 * bevel + 0.45 * b.g, 0.45 * b.g);
}

// Distant round lamp: a soft disc with a wide glow around it.
float puppy_lamp(float2 q, float2 center, float radius) {
    float d = length(q - center) / radius;
    return 1.0 - smoothstep(0.0, 1.0, d) + 0.25 * exp(-d * d * 0.8);
}

float3 puppy_shade(float2 pos, constant PuppyUniforms &uniforms, texture2d<float> height_map) {
    float2 uv = (pos - uniforms.body_origin_px) / uniforms.body_size_px;
    float2 tx = 1.5 / uniforms.body_size_px;
    float2 h_right = puppy_height(height_map, uv + float2(tx.x, 0.0));
    float2 h_left = puppy_height(height_map, uv - float2(tx.x, 0.0));
    float2 h_up = puppy_height(height_map, uv + float2(0.0, tx.y));
    float2 h_down = puppy_height(height_map, uv - float2(0.0, tx.y));
    float2 hx = h_right - h_left;
    float2 hy = h_up - h_down;

    // Relief depth as a fraction of the logo width; y flips to point up.
    float relief = 0.32 * uniforms.body_size_px.x / 3.0;
    float3 n = normalize(float3(-hx.x * relief, hy.x * relief, 1.0));
    // Normal of the crown alone: light scattered inside the body ignores the sharp bevel.
    float3 n_soft = normalize(float3(-hx.y * relief, hy.y * relief, 1.0));
    // Thin near the outline and on the leaf, thick in the middle of the body.
    float thickness = 0.25 * (h_right.x + h_left.x + h_up.x + h_down.x);

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
    float3 color = light_color * light_color * (0.20 + 0.80 * diff);
    // Global light wraps the whole object, a bit stronger on the side away from the key
    float3 fill_dir = normalize(float3(-L.xy, 0.6));
    color += light_color * (0.08 + 0.14 * max(dot(n, fill_dir), 0.0));

    // Pseudo subsurface scattering: wrapped diffuse on the soft normal bleeds light past the
    // terminator, tinted deeper (absorbed along the path) and stronger where the material is thin.
    float scatter = max(dot(n_soft, L) + 0.8, 0.0) / 1.8;
    color += light_color * light_color * light_color * scatter * (0.18 + 0.55 * (1.0 - thickness));
    // Faint self-glow so the shadow side never goes fully dark.
    color += 0.12 * light_color;

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
    // One sample per pixel: supersampling was dropped for speed.
    float3 color = puppy_shade(in.position.xy, uniforms, height_map);
    // Faint grain, one value per pixel. Scaling the colour
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
  private var isBaking = false

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
    bakeHeightIfNeeded(rect: rect, fruit: fruit, leaf: leaf)

    let pixelScale = contentsScale
    var uniforms = MetalPuppyFragmentUniforms(
      body_origin_px: SIMD2<Float>(Float(rect.minX * pixelScale), Float((bounds.height - rect.maxY) * pixelScale)),
      body_size_px: SIMD2<Float>(Float(rect.width * pixelScale), Float(rect.height * pixelScale)),
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
      applyScissorRect(on: renderEncoder, texture: texture, rect: rect)
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

  private func bakeHeightIfNeeded(rect: CGRect, fruit: Fruit, leaf: Leaf) {
    guard rect != bakedRect && !isBaking else { return }
    // Baked off the main thread so the app doesn't freeze; the logo stays black until it lands.
    isBaking = true
    let device = metalDevice, scale = contentsScale
    let fruitPath = fruit.transformedPath.quartzPath, leafPath = leaf.transformedPath.quartzPath
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let baked = HeightMapBaker.bake(
        device: device, rect: rect, contentsScale: scale, fruitPath: fruitPath, leafPath: leafPath
      )
      DispatchQueue.main.async {
        guard let self = self else { return }
        self.heightTexture = baked
        self.bakedRect = rect
        self.isBaking = false
        self.setNeedsDisplay()  // re-checks the rect, in case it changed meanwhile
      }
    }
  }

  private func applyScissorRect(on encoder: MTLRenderCommandEncoder, texture: MTLTexture, rect: CGRect) {
    let pixelScale = contentsScale
    let scissorX = max(0, Int(rect.minX * pixelScale))
    let scissorY = max(0, Int((bounds.height - rect.maxY) * pixelScale))
    let scissorWidth = min(Int(rect.width * pixelScale), texture.width - scissorX)
    let scissorHeight = min(Int(rect.height * pixelScale), texture.height - scissorY)
    if scissorWidth > 0 && scissorHeight > 0 {
      encoder.setScissorRect(MTLScissorRect(x: scissorX, y: scissorY,
                                            width: scissorWidth, height: scissorHeight))
    }
  }
}
