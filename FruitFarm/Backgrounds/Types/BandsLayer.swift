import Cocoa
import QuartzCore
import Foundation
import MetalKit

private let metalBandsShaderSource = """
using namespace metal;

struct VertexData {
    float2 position;
};

struct VertexOut {
    float4 position [[position]];
};

vertex VertexOut vertex_shader_bands(
    const device VertexData* vertex_array [[buffer(0)]],
    unsigned int vid [[vertex_id]]) {
    VertexOut out;
    out.position = float4(vertex_array[vid].position, 0.0, 1.0);
    return out;
}

struct BandsUniforms {
    float2 body_origin_px;
    float2 body_size_px;
    float2 center_px;
    float2 leaf_center_px;
    float rings;
    float bevel_px;
};

// Distance from the centre that bends from circles into the apple outline as it grows:
// 0 at the centre, 1 on the outline. Same field as PsyLayer's swirl.
float bands_rho(float2 pos, constant BandsUniforms &uniforms, float4 hm) {
    float2 v = pos - uniforms.center_px;
    float k = 1.0 - clamp(hm.r, 0.0, 1.0);
    // Crown (G): ~1.79 in the middle, ~0.92 on the outline, contours = the outline smoothed.
    float deep = clamp((1.79 - hm.g) / 0.87, 0.0, 1.0);
    float pull = mix(0.9 * pow(deep, 0.75), 1.0, k * k * (3.0 - 2.0 * k));
    float rim = 0.57 * uniforms.body_size_px.x;
    float rho = mix(length(v), rim, pull) * (1.0 - 0.11 * hm.r * (2.0 - hm.r));
    return rho / rim;
}

// The leaf's own field: 0 at its centre, 1 on its outline. R is the distance to the outline
// over the bevel width (the leaf is too narrow for it to clamp). Near the centre the outline
// is about equally far everywhere, so rings start round; near the edge they follow it.
// Keeps growing outward on a convex shape, so rings never fold back.
float leaf_rho(float2 pos, constant BandsUniforms &uniforms, float4 hm) {
    float a = length(pos - uniforms.leaf_center_px);
    float b = clamp(hm.r, 0.0, 1.0) * uniforms.bevel_px;
    return a / (a + b + 1e-3);
}

fragment float4 fragment_shader_bands(
    VertexOut in [[stage_in]],
    constant BandsUniforms &uniforms [[buffer(0)]],
    texture2d<float> height_map [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 uv = (in.position.xy - uniforms.body_origin_px) / uniforms.body_size_px;
    float4 hm = height_map.sample(s, uv);
    // Body and leaf never touch, so leafness (B) picks the field outright.
    bool on_leaf = hm.b > 0.5;
    float r = on_leaf ? leaf_rho(in.position.xy, uniforms, hm) : bands_rho(in.position.xy, uniforms, hm);
    // About the same ring spacing on both; they share `rings`, so both emit in step.
    float count = on_leaf ? 4.0 : 12.0;

    // Soft wave along each ring, drifting around the centre: at most ~8% of a ring's size, so
    // it bends rather than kinks. Integer lobes keep it seamless around the angle, and whole
    // turns per 36 rings keep the loop seamless. It fades out at the centre and on the outline,
    // so rings still start round and end on the edge.
    float2 v = in.position.xy - (on_leaf ? uniforms.leaf_center_px : uniforms.center_px);
    float theta = atan2(v.y, v.x);
    float turn = 6.2831853 * uniforms.rings / 6.0;
    float wobble = 0.32 * count * r * r * (1.0 - min(r, 1.0))
                 * (0.6 * sin(3.0 * theta + turn) + 0.4 * sin(2.0 * theta - 2.0 * turn + 1.3));

    // Rings are born at the centre and travel outward; `rings` counts them from the centre.
    float x = count * r + wobble - uniforms.rings;
    float band = sin(6.2831853 * x);
    float w = fwidth(band) + 1e-4;
    float stripe = smoothstep(-w, w, band);
    // Where rings crowd below a pixel (the bite) settle to their average instead of aliasing.
    float crowd = smoothstep(0.6, 1.4, w);
    stripe = mix(stripe, 0.5, crowd);

    // RainbowsLayer's bars, outward from the centre as theirs go upward. Each colour spans
    // half the rings, so two show at a time, and eases into the next across that span.
    // Keyed to the ring (x), not the position, so a ring keeps its colour as it grows.
    const float3 rainbow[6] = {
        float3(67.0, 156.0, 214.0) / 255.0,   // blue
        float3(139.0, 69.0, 147.0) / 255.0,   // purple
        float3(207.0, 72.0, 69.0) / 255.0,    // red
        float3(231.0, 135.0, 59.0) / 255.0,   // orange
        float3(243.0, 185.0, 75.0) / 255.0,   // yellow
        float3(120.0, 184.0, 86.0) / 255.0    // green
    };
    float span = x / (0.5 * count);
    int index = int(floor(span)) % 6;
    index = index < 0 ? index + 6 : index;
    float3 color = mix(rainbow[index], rainbow[(index + 1) % 6], smoothstep(0.0, 1.0, fract(span)));
    color = mix(color, float3(168.0, 134.0, 108.0) / 255.0, crowd);  // the six averaged
    return float4(color * stripe, 1.0);
}
"""

private struct MetalBandsFragmentUniforms {
  // swiftlint:disable identifier_name
  var body_origin_px: SIMD2<Float>
  var body_size_px: SIMD2<Float>
  var center_px: SIMD2<Float>
  var leaf_center_px: SIMD2<Float>
  var rings: Float
  var bevel_px: Float
  // swiftlint:enable identifier_name
}

/// Rings that grow from the middle of the apple and of the leaf, turning from circles into their outlines.
final class BandsLayer: CAMetalLayer, Background {

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
  /// How many rings have left the centre, wrapped at one colour cycle: 6 colours of 6 body
  /// rings (the leaf's 2 per colour divides it too).
  private var rings: CGFloat = 0
  /// New rings per second.
  private let ringRate: CGFloat = 0.4
  private var lastUpdateTime: CGFloat = 0
  private let minUpdateInterval: CGFloat = 1.0 / 30.0

  private weak var currentFruit: Fruit?
  private weak var currentLeaf: Leaf?

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
    guard let other = layer as? BandsLayer else { return }
    // Only plain Swift state: Metal state isn't valid inside presentation_copy.
    self.rings = other.rings
  }

  private func setupMetal() {
    guard let device = MTLCreateSystemDefaultDevice() else { return }
    self.metalDevice = device
    self.device = device
    self.commandQueue = device.makeCommandQueue()
  }

  private func setupPipeline() {
    guard let metalDevice = metalDevice else { return }
    do {
      let library = try metalDevice.makeLibrary(source: metalBandsShaderSource, options: nil)
      guard let vertexFunction = library.makeFunction(name: "vertex_shader_bands"),
            let fragmentFunction = library.makeFunction(name: "fragment_shader_bands") else {
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
    rings = (rings + deltaTime * ringRate).truncatingRemainder(dividingBy: 36)
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

    // Padded logo rect, as in GlassLayer: the height-map bake area and the scissor.
    let rect = fruit.bounds(including: leaf).insetBy(dx: -4, dy: -4)
    bakeHeightIfNeeded(rect: rect, fruit: fruit, leaf: leaf)

    let scale = contentsScale
    // Rings start from the middle of the body's box, which sits off the visual centre
    // (the bite pulls it right), so they look organic rather than compass-drawn.
    let body = fruit.transformedPath.bounds
    let leafBox = leaf.transformedPath.bounds
    var uniforms = MetalBandsFragmentUniforms(
      body_origin_px: SIMD2<Float>(Float(rect.minX * scale), Float((bounds.height - rect.maxY) * scale)),
      body_size_px: SIMD2<Float>(Float(rect.width * scale), Float(rect.height * scale)),
      center_px: SIMD2<Float>(Float(body.midX * scale), Float((bounds.height - body.midY) * scale)),
      leaf_center_px: SIMD2<Float>(Float(leafBox.midX * scale), Float((bounds.height - leafBox.midY) * scale)),
      rings: Float(rings),
      // HeightMapBaker's bevel width: R = distance to the outline over this.
      bevel_px: Float(0.16 * body.width * scale)
    )

    let renderPassDescriptor = MTLRenderPassDescriptor()
    renderPassDescriptor.colorAttachments[0].texture = texture
    renderPassDescriptor.colorAttachments[0].loadAction = .clear
    renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

    guard let commandBuffer = commandQueue.makeCommandBuffer(),
          let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
      return
    }

    // Black until the height map lands.
    if let heightTexture = heightTexture {
      renderEncoder.setRenderPipelineState(pipelineState)
      applyScissorRect(on: renderEncoder, texture: texture, rect: rect)
      renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
      renderEncoder.setFragmentBytes(&uniforms, length: MemoryLayout<MetalBandsFragmentUniforms>.stride, index: 0)
      renderEncoder.setFragmentTexture(heightTexture, index: 0)
      renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    renderEncoder.endEncoding()
    commandBuffer.present(drawable)
    commandBuffer.commit()
  }

  private func bakeHeightIfNeeded(rect: CGRect, fruit: Fruit, leaf: Leaf) {
    guard rect != bakedRect && !isBaking else { return }
    // Baked off the main thread so the app doesn't freeze.
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
    let scale = contentsScale
    let scissorX = max(0, Int(rect.minX * scale))
    let scissorY = max(0, Int((bounds.height - rect.maxY) * scale))
    let scissorWidth = min(Int(rect.width * scale), texture.width - scissorX)
    let scissorHeight = min(Int(rect.height * scale), texture.height - scissorY)
    if scissorWidth > 0 && scissorHeight > 0 {
      encoder.setScissorRect(MTLScissorRect(x: scissorX, y: scissorY, width: scissorWidth, height: scissorHeight))
    }
  }
}
