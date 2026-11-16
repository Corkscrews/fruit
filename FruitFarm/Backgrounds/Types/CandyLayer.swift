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
    float grown_px;  // how far the rope's front has come out of the centre, along the rope
    float crawl_px;  // the same distance, wrapped at the sugar pattern's period
    float bevel_px;
    float leaf_radius_px;
};

// Distance from the centre that bends from circles into the apple outline as it grows:
// 0 at the centre, 1 on the outline. Same field as PsyLayer's swirl.
float bands_rho(float2 pos, constant BandsUniforms &uniforms, float4 hm) {
    float2 v = pos - uniforms.center_px;
    float k = 1.0 - clamp(hm.r, 0.0, 1.0);
    // Crown (G): ~1.79 in the middle, ~0.92 on the outline, contours = the outline smoothed.
    float deep = clamp((1.79 - hm.g) / 0.87, 0.0, 1.0);
    // Only 0.6 of the pull into the exact outline near the edge, so the outer laps stay rounder
    // (the mask trims them where they cross it).
    float pull = mix(0.9 * pow(deep, 0.75), 1.0, 0.6 * k * k * (3.0 - 2.0 * k));
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
    // Laps from the centre to the outline; about the same rope thickness on both.
    float count = on_leaf ? 2.5 : 7.0;

    // One arm: the phase climbs a whole turn per lap around the centre, so the rings join into
    // a single spiral. The jump at atan2's cut is exactly 1, which sin() doesn't see.
    float2 v = in.position.xy - (on_leaf ? uniforms.leaf_center_px : uniforms.center_px);
    float a = atan2(v.y, v.x) / 6.2831853 + 0.5;
    float x = count * r - a;
    float band = sin(6.2831853 * x);

    // Distance along the rope, in laps: whole laps out from the centre (each starting at the
    // seam with the previous lap, x = 0.75) plus the angle. Continuous along the rope, -1 at the
    // centre, count + 1 at the rim.
    float along = floor(x + 0.25) + a;
    // Arc length along the spiral is about pi * lap * (along + 1)^2, in pixels.
    float lap_px = (on_leaf ? uniforms.leaf_radius_px : 0.57 * uniforms.body_size_px.x) / count;
    float head = sqrt(uniforms.grown_px / (3.1415927 * lap_px)) - 1.0;
    // The front is a flat cut across the rope, antialiased over a pixel's worth of angle.
    float ws = min(0.5, 1.0 / (6.2831853 * length(v) + 1e-3));
    float alive = clamp((head - along) / ws + 0.5, 0.0, 1.0);
    float w = fwidth(band) + 1e-4;
    // Where turns crowd below a pixel (the bite) settle to their average instead of aliasing.
    float crowd = smoothstep(0.6, 1.4, w);

    // Sour licorice: a round red rope, lit from the top left across its width.
    // t runs 0 to 1 from the lap's inner edge to its outer one; the rope's surface normal tilts
    // inward at t = 0 and outward at t = 1, outward being up the field (across the laps).
    float t = fract(x + 0.25);
    float tilt = 2.0 * t - 1.0;
    float2 g = float2(dfdx(r), dfdy(r));
    float2 outward = length(g) > 1e-6 ? normalize(g) : normalize(v + 1e-3);
    float3 normal = float3(outward * tilt, sqrt(max(0.0, 1.0 - tilt * tilt)));
    const float3 light = normalize(float3(-0.45, -0.6, 0.65));  // y grows downward
    float diffuse = max(dot(normal, light), 0.0);
    float spec = pow(max(reflect(-light, normal).z, 0.0), 20.0);
    const float3 red = float3(214.0, 38.0, 62.0) / 255.0;
    float3 color = red * (0.65 + 0.45 * diffuse);
    // Contact shadow: a little darker where a lap presses against its neighbours.
    color *= mix(0.6, 1.0, smoothstep(0.0, 0.18, min(t, 1.0 - t)));

    // Sugar coating: 2px grains of varying brightness, a few catching the light as crystals.
    // Stuck to the rope: laid out along it and across it, then slid back by how far the rope has
    // crawled, so grains ride the coil. The pattern repeats every 65536 grains (& 0xFFFF), the
    // period crawl_px wraps at, so the crawl can run forever without losing float precision.
    float2 rope = float2(3.1415927 * lap_px * (along + 1.0) * (along + 1.0) - uniforms.crawl_px,
                         t * lap_px);
    uint2 cell = as_type<uint2>(int2(floor(rope * 0.5))) & uint2(0xFFFFu, 0xFFFFFFFFu);
    // PCG hash: the cheaper polynomial one left a bright streak along one pixel column.
    uint n = (cell.x + cell.y * 65536u) * 747796405u + 2891336453u;
    n = ((n >> ((n >> 28u) + 4u)) ^ n) * 277803737u;
    n = (n >> 22u) ^ n;
    float h = float(n) / 4294967295.0;
    color *= 0.88 + 0.24 * h;
    color = mix(color, float3(1.0, 0.86, 0.88), (0.3 + 0.5 * diffuse) * smoothstep(0.84, 0.98, h));
    color += 0.35 * spec;

    color = mix(color, float3(175.0, 31.0, 51.0) / 255.0, crowd);  // the lit rope averaged
    // The rope comes up from behind the centre: dark there, lit after about a lap and a half.
    color *= smoothstep(-1.0, 0.5, along);
    return float4(color * alive, 1.0);
}
"""

private struct MetalBandsFragmentUniforms {
  // swiftlint:disable identifier_name
  var body_origin_px: SIMD2<Float>
  var body_size_px: SIMD2<Float>
  var center_px: SIMD2<Float>
  var leaf_center_px: SIMD2<Float>
  var grown_px: Float
  var crawl_px: Float
  var bevel_px: Float
  var leaf_radius_px: Float
  // swiftlint:enable identifier_name
}

/// A sour-licorice rope coiling out from the middle of the apple and of the leaf, bending into their outlines.
final class CandyLayer: CAMetalLayer, Background {

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
  /// How far the rope has come out of the centre, in body widths. It grows until the logo is
  /// full, then keeps crawling forever; its other end stays hidden behind the centre.
  private var crawled: CGFloat = 0
  /// Body widths per second.
  private let crawlRate: CGFloat = 0.3
  /// The shader's sugar pattern repeats every 65536 grains of 2 px.
  private let sugarPeriodPx: CGFloat = 131072
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
    guard let other = layer as? CandyLayer else { return }
    // Only plain Swift state: Metal state isn't valid inside presentation_copy.
    self.crawled = other.crawled
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
    crawled += deltaTime * crawlRate  // Double: precise for centuries of runtime
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
    let crawledPx = crawled * body.width * scale
    var uniforms = MetalBandsFragmentUniforms(
      body_origin_px: SIMD2<Float>(Float(rect.minX * scale), Float((bounds.height - rect.maxY) * scale)),
      body_size_px: SIMD2<Float>(Float(rect.width * scale), Float(rect.height * scale)),
      center_px: SIMD2<Float>(Float(body.midX * scale), Float((bounds.height - body.midY) * scale)),
      leaf_center_px: SIMD2<Float>(Float(leafBox.midX * scale), Float((bounds.height - leafBox.midY) * scale)),
      // Capped well past the length of rope the logo holds, to stay a sane Float.
      grown_px: Float(min(crawledPx, 1e6)),
      crawl_px: Float(crawledPx.truncatingRemainder(dividingBy: sugarPeriodPx)),
      // HeightMapBaker's bevel width: R = distance to the outline over this.
      bevel_px: Float(0.16 * body.width * scale),
      // Rough centre-to-outline distance, to size the leaf's sugar grains like the body's.
      leaf_radius_px: Float((leafBox.width + leafBox.height) / 4 * scale)
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
