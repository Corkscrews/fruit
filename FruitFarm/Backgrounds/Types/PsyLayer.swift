// swiftlint:disable file_length
import Cocoa
import QuartzCore
import Foundation
import MetalKit

private let metalPsyShaderSource = """
using namespace metal;

struct VertexData {
    float2 position;
};

struct VertexOut {
    float4 position [[position]];
};

vertex VertexOut vertex_shader_psy(
    const device VertexData* vertex_array [[buffer(0)]],
    unsigned int vid [[vertex_id]]) {
    VertexOut out;
    out.position = float4(vertex_array[vid].position, 0.0, 1.0);
    return out;
}

struct PsyUniforms {
    float2 resolution;
    float time;
    float color_phase;
    float referenceSize;
    float swirl;
    float2 body_origin_px;
    float2 body_size_px;
    float2 swirl_center_px;
};

float3 hsv2rgb(float3 c) {
    float3 p = abs(fract(float3(c.x) + float3(0.0, 2.0/3.0, 1.0/3.0)) * 6.0 - 3.0);
    return c.z * mix(float3(1.0), clamp(p - 1.0, 0.0, 1.0), c.y);
}

float2 domain_warp(float2 p, float t, float seed) {
    return float2(
        sin(p.y * 3.7 + t * 0.73 + seed) + cos(p.x * 2.3 - t * 0.51),
        cos(p.x * 3.3 - t * 0.67 + seed) + sin(p.y * 2.7 + t * 0.43)
    );
}

float plasma(float2 p, float t) {
    float v = 0.0;
    v += sin(p.x * 10.0 + t);
    v += sin((p.y * 10.0 + t) * 0.5);
    v += sin((p.x * 10.0 + p.y * 10.0 + t) * 0.33);
    float cx = p.x + 0.5 * sin(t * 0.33);
    float cy = p.y + 0.5 * cos(t * 0.5);
    v += sin(sqrt(cx * cx + cy * cy + 1.0) * 10.0 + t);
    return v * 0.25;
}

// Same slab profile as GlassLayer: R = bevel ramp, G = crown, B = leafness.
float psy_height(texture2d<float> tex, float2 uv) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 b = tex.sample(s, uv).rgb;
    float k = 1.0 - clamp(b.r, 0.0, 1.0);
    float bevel = sqrt(1.0 - k * k * mix(k, 1.0, b.b));
    return 0.55 * bevel + 0.45 * b.g;
}

// Distant round lamp, as in GlassLayer.
float psy_lamp(float2 q, float2 center, float radius) {
    float d = length(q - center) / radius;
    return 1.0 - smoothstep(0.0, 1.0, d) + 0.25 * exp(-d * d * 0.8);
}

// The studio mirrored by the apple: dim room, sky above, two lamps and a strip light.
float3 psy_env(float3 R, float t) {
    float2 sway = float2(0.10 * sin(t * 0.33), 0.06 * cos(t * 0.27));
    float3 env = mix(float3(0.03, 0.03, 0.04), float3(0.75, 0.80, 0.90),
                     smoothstep(-0.4, 1.0, R.y));
    env += 5.5 * psy_lamp(R.xy, float2(-0.38, 0.46) + sway, 0.50);
    env += float3(3.0, 3.3, 3.7) * psy_lamp(R.xy, float2(0.60, -0.42) - sway, 0.24);
    float2 sd = R.xy - float2(0.22 + 0.10 * sin(t * 0.19), 0.05);
    float strip = exp(-pow(dot(sd, float2(0.94, 0.34)) / 0.14, 2.0))
                * (1.0 - smoothstep(0.30, 0.90, abs(dot(sd, float2(-0.34, 0.94)))));
    env += 2.0 * strip;
    return env * (smoothstep(-0.6, 0.6, R.z) * 0.85 + 0.15);
}

// Lights the psychedelic surface as a bevelled apple: normals from the height map
// and a studio reflection on the front.
float3 psy_object(float2 pos, constant PsyUniforms &uniforms, texture2d<float> height_map, float3 surface) {
    float2 uv = (pos - uniforms.body_origin_px) / uniforms.body_size_px;
    float2 tx = 1.5 / uniforms.body_size_px;
    float hx = psy_height(height_map, uv + float2(tx.x, 0.0)) - psy_height(height_map, uv - float2(tx.x, 0.0));
    float hy = psy_height(height_map, uv + float2(0.0, tx.y)) - psy_height(height_map, uv - float2(0.0, tx.y));
    float relief = 0.32 * uniforms.body_size_px.x / 3.0;
    // y flips to point up.
    float3 n = normalize(float3(-hx * relief, hy * relief, 1.0));
    float t = uniforms.time;

    float3 color = surface;

    float3 R = reflect(float3(0.0, 0.0, -1.0), n);
    float fresnel = 0.08 + 0.92 * pow(1.0 - clamp(n.z, 0.0, 1.0), 4.0);
    color = color * (1.0 - fresnel) + psy_env(R, t) * fresnel;

    return clamp(color, 0.0, 1.0);
}

// Pattern coordinates for a liquid stirred in an apple-shaped cup. The liquid travels
// along the level sets of `rho`: circles only right at the body centre, taking the
// apple's shape from about a quarter of the way out and matching the outline exactly
// at the edge (rho is one constant on the outline).
// Turning the angle moves everything along those curves; the log twist winds it into
// spiral arms that trail the rotation, tighter toward the centre.
float2 psy_swirl(float2 pos, constant PsyUniforms &uniforms, texture2d<float> height_map) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 v = pos - uniforms.swirl_center_px;
    // 0 deep inside, 1 on the outline (R = distance from the outline over the bevel width).
    float2 uv = (pos - uniforms.body_origin_px) / uniforms.body_size_px;
    float4 hm = height_map.sample(s, uv);
    float k = 1.0 - clamp(hm.r, 0.0, 1.0);
    // The crown (G) is a wide blur of the logo: ~1.79 in the middle, ~0.92 on the outline,
    // and its contours are the outline smoothed. It carries the apple's shape deep into
    // the body, so the circles start bending long before the bevel band takes over.
    float deep = clamp((1.79 - hm.g) / 0.87, 0.0, 1.0);
    float pull = mix(0.9 * pow(deep, 0.75), 1.0, k * k * (3.0 - 2.0 * k));
    // Just past the farthest point of the body from its centre, so rho only grows outward.
    float rim = 0.57 * uniforms.body_size_px.x;
    // The last factor keeps rho climbing right up to the outline (it is 1 there, and flat
    // where the band ends); without it rho levels off at the edge and the pattern smears.
    float rho = mix(length(v), rim, pull) * (1.0 - 0.11 * hm.r * (2.0 - hm.r));
    float a = atan2(v.y, v.x) + uniforms.swirl - 1.3 * log(rho / rim + 0.08);
    // 0.65: coarser pattern, to make up for rho reaching `rim` on every part of the outline
    // (the bite is far closer than that), which would otherwise squeeze stripes below a pixel.
    return 0.65 * rho * float2(cos(a), sin(a)) / uniforms.referenceSize;
}

fragment float4 fragment_shader_psy(
    VertexOut in [[stage_in]],
    constant PsyUniforms &uniforms [[buffer(0)]],
    texture2d<float> height_map [[texture(0)]]) {

    float2 vigUV = (in.position.xy * 2.0 - uniforms.resolution) /
                    min(uniforms.resolution.x, uniforms.resolution.y);
    float origR = length(vigUV);

    float2 uv = psy_swirl(in.position.xy, uniforms, height_map);
    float t = uniforms.time;

    // Heavy domain warping - high amplitude, fast
    float2 p = uv;
    float amp = 0.9;
    for (int i = 0; i < 7; i++) {
        p = domain_warp(p, t * 1.4 + float(i) * 1.13, float(i) * 1.87) * amp;
        amp *= 0.78;
    }

    float2 q = uv * 1.4;
    amp = 0.75;
    for (int i = 0; i < 5; i++) {
        q = domain_warp(q, t * 1.0 + float(i) * 2.71, float(i) * 3.14 + 5.5) * amp;
        amp *= 0.8;
    }

    float2 r = uv * 0.7;
    amp = 0.6;
    for (int i = 0; i < 4; i++) {
        r = domain_warp(r, t * 0.7 + float(i) * 3.33, float(i) * 2.22 + 9.0) * amp;
        amp *= 0.82;
    }

    float pl1 = plasma(uv * 0.9 + p * 0.5, t * 1.6);
    float pl2 = plasma(uv * 0.6 + q * 0.4 + r * 0.2, t * 1.1 + 3.0);

    // Aggressive interference - high amplitudes, high frequencies, fast
    float psy = 0.0;
    psy += sin(p.x * 18.0 + q.y * 12.0 + t * 3.2) * 0.35;
    psy += cos(p.y * 15.0 - q.x * 13.0 - t * 2.6) * 0.35;
    psy += sin(length(p) * 24.0 + length(q) * 18.0 - t * 4.5) * 0.3;
    psy += cos((p.x - q.y) * 20.0 + t * 1.8)
         * sin((p.y + q.x) * 17.0 - t * 2.2) * 0.25;
    psy += sin(r.x * 22.0 + p.y * 10.0 + t * 3.8) * 0.2;
    psy += cos(r.y * 19.0 - q.x * 14.0 + t * 2.9) * 0.2;

    // Harsh color banding - fewer bands = chunkier steps
    float bands = floor(psy * 3.0) / 3.0;
    psy = mix(psy, bands, 0.5);

    // Fast ripples
    float ripples = sin(length(p * 1.5 + q * 0.9) * 30.0 - t * 5.5) * 0.5 + 0.5;
    float ripples2 = sin(length(q * 1.3 - r * 1.1) * 25.0 + t * 4.0) * 0.5 + 0.5;

    // Fast hue cycling
    float hue = fract(
        (p.x + q.y) * 0.25
        + (r.x - r.y) * 0.15
        + t * 0.12
        + pl1 * 0.3
        + pl2 * 0.2
        + psy * 0.3
        + uniforms.color_phase
    );

    float sat = 1.0;

    float val = 0.35
        + 0.25 * ripples
        + 0.15 * ripples2
        + 0.15 * (psy * 0.5 + 0.5)
        + 0.1 * pl1
        + 0.08 * pl2;

    val *= 0.9 + 0.1 * sin(t * 1.5 + pl1 * 3.0);

    val = pow(clamp(val, 0.0, 1.0), 0.75);

    val = clamp(val, 0.3, 1.0);

    float3 color = hsv2rgb(float3(hue, sat, val));

    float vignette = 1.0 - smoothstep(0.7, 1.8, origR);
    color *= mix(0.5, 1.0, vignette);

    return float4(psy_object(in.position.xy, uniforms, height_map, color), 1.0);
}
"""

private struct MetalPsyFragmentUniforms {
  var resolution: SIMD2<Float>
  var time: Float
  // swiftlint:disable:next identifier_name
  var color_phase: Float
  var referenceSize: Float
  var swirl: Float
  // swiftlint:disable identifier_name
  var body_origin_px: SIMD2<Float>
  var body_size_px: SIMD2<Float>
  var swirl_center_px: SIMD2<Float>
  // swiftlint:enable identifier_name
}

final class PsyLayer: CAMetalLayer, Background {

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
  private var colorPhase: CGFloat = 0
  /// Angle (radians) the liquid has turned around the body centre.
  private var swirlAngle: CGFloat = 0
  private var lastUpdateTime: CGFloat = 0
  private let minUpdateInterval: CGFloat = 1.0 / 30.0

  // MARK: - Speed Variation
  private var currentSpeed: CGFloat = 1.0
  private var startSpeed: CGFloat = 1.0
  private var targetSpeed: CGFloat = 1.0
  private var speedTimer: CGFloat = 0
  private var phaseDuration: CGFloat = 2.0
  private var isFastPhase: Bool = false

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
    guard let other = layer as? PsyLayer else { return }

    // Only copy plain Swift stored properties. Do NOT access any CAMetalLayer
    // properties (device, pixelFormat, etc.) — this runs inside
    // CA::Layer::presentation_copy where Metal state is not valid yet.
    self.totalElapsedTime = other.totalElapsedTime
    self.colorPhase = other.colorPhase
    self.swirlAngle = other.swirlAngle
    self.currentSpeed = other.currentSpeed
    self.startSpeed = other.startSpeed
    self.targetSpeed = other.targetSpeed
    self.speedTimer = other.speedTimer
    self.phaseDuration = other.phaseDuration
    self.isFastPhase = other.isFastPhase
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
      let library = try metalDevice.makeLibrary(source: metalPsyShaderSource, options: nil)
      guard let vertexFunction = library.makeFunction(name: "vertex_shader_psy"),
            let fragmentFunction = library.makeFunction(name: "fragment_shader_psy") else {
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

  private func easeInOut(_ progress: CGFloat) -> CGFloat {
    let exponent: CGFloat = 4.0
    if progress < 0.5 {
      return 0.5 * pow(2.0 * progress, exponent)
    } else {
      return 1.0 - 0.5 * pow(2.0 * (1.0 - progress), exponent)
    }
  }

  func update(deltaTime: CGFloat) {
    speedTimer += deltaTime
    if speedTimer >= phaseDuration {
      speedTimer = 0
      startSpeed = currentSpeed
      isFastPhase.toggle()
      if isFastPhase {
        targetSpeed = CGFloat.random(in: 0.8...1.0)
        phaseDuration = CGFloat.random(in: 1.5...3.0)
      } else {
        targetSpeed = CGFloat.random(in: 0.02...0.12)
        phaseDuration = CGFloat.random(in: 20.0...40.0)
      }
    }

    let progress = min(speedTimer / phaseDuration, 1.0)
    currentSpeed = startSpeed + (targetSpeed - startSpeed) * easeInOut(progress)

    totalElapsedTime += deltaTime * currentSpeed
    colorPhase = (totalElapsedTime * 0.02).truncatingRemainder(dividingBy: 1.0)
    // Always coasting round, with a kick during the fast phases, like a stir.
    swirlAngle = (swirlAngle + deltaTime * (0.12 + 0.6 * currentSpeed)).truncatingRemainder(dividingBy: 2 * .pi)
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

    // Same padded logo rect as GlassLayer: it is both the height-map bake area and the scissor.
    let rect = fruit.bounds(including: leaf).insetBy(dx: -4, dy: -4)
    bakeHeightIfNeeded(rect: rect, fruit: fruit, leaf: leaf)

    let referenceSize: Float = 200.0 * Float(contentsScale)
    let pixelScale = contentsScale
    // The liquid turns around the middle of the body, not of the body plus leaf.
    let body = fruit.transformedPath.bounds

    var uniforms = MetalPsyFragmentUniforms(
      resolution: SIMD2<Float>(Float(texture.width), Float(texture.height)),
      time: Float(totalElapsedTime),
      color_phase: Float(colorPhase),
      referenceSize: referenceSize,
      swirl: Float(swirlAngle),
      body_origin_px: SIMD2<Float>(Float(rect.minX * pixelScale), Float((bounds.height - rect.maxY) * pixelScale)),
      body_size_px: SIMD2<Float>(Float(rect.width * pixelScale), Float(rect.height * pixelScale)),
      swirl_center_px: SIMD2<Float>(Float(body.midX * pixelScale), Float((bounds.height - body.midY) * pixelScale))
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

    // Black until the height map lands, as in GlassLayer.
    if let heightTexture = heightTexture {
      renderEncoder.setRenderPipelineState(pipelineState)
      applyScissorRect(on: renderEncoder, texture: texture, rect: rect)
      renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
      renderEncoder.setFragmentBytes(
        &uniforms,
        length: MemoryLayout<MetalPsyFragmentUniforms>.stride,
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
