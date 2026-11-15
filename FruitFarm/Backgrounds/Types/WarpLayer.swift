// swiftlint:disable file_length
import Cocoa
import QuartzCore
import Foundation
import MetalKit

private let warpLayerCount = 14
private let warpRenderScale: CGFloat = 1.0

private let metalWarpShaderSource = """
using namespace metal;

#define WARP_LAYER_COUNT \(warpLayerCount)

struct VertexData {
    float2 position;
};

struct VertexOut {
    float4 position [[position]];
};

vertex VertexOut vertex_shader_warp(
    const device VertexData* vertex_array [[buffer(0)]],
    unsigned int vid [[vertex_id]]) {
    VertexOut out;
    out.position = float4(vertex_array[vid].position, 0.0, 1.0);
    return out;
}

struct WarpUniforms {
    float2 resolution;
    float2 uvOffset;
    float time;
    float speed;
    float referenceSize;
    float warpFactor;
    float streakMix;
    float brightScaled;
    float tScroll;
    float cull;
    float dopplerMix;
    float beamingMix;
    float twinkleSolid;
    float glow;
    float vigRadius;
};

struct WarpLayerData {
    float scale;
    float inv_scale;
    float fade;
    float inv_ds2;
    float fi64;
    float fi27;
};

float warp_hash(float2 p) {
    float3 p3 = fract(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

float2 warp_hash2(float2 p) {
    float3 p3 = fract(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract(float2((p3.x + p3.y) * p3.z, (p3.x + p3.z) * p3.y));
}

fragment float4 fragment_shader_warp(
    VertexOut in [[stage_in]],
    constant WarpUniforms &u [[buffer(0)]],
    constant WarpLayerData *layers [[buffer(1)]]) {

    float2 uv = (in.position.xy - u.resolution * 0.5) / u.referenceSize + u.uvOffset;
    float2 warp_uv = uv * u.warpFactor;

    bool skip_twinkle = u.twinkleSolid > 0.99;
    float t = u.time;
    float streak_k = -u.speed * 0.15;

    float3 col = float3(0.0);

    for (int i = 0; i < WARP_LAYER_COUNT; i++) {
        constant WarpLayerData &ld = layers[i];
        if (ld.fade < 0.001) continue;

        float2 st = warp_uv * ld.scale;
        float2 gid = floor(st);

        // Skip neighbour cells that cannot reach this pixel. A star's visible
        // radius (b >= 0.0001 below) is at most ~0.30 cells, so a neighbour only
        // matters when the pixel is within 0.35 of that cell edge. Streaks run
        // from the star toward the origin, so with streaks on the outward
        // neighbour is always kept (both sides near the axes, where a streak
        // can cross the origin).
        float2 f = st - gid;
        float2 lo = -step(f, float2(0.35));
        float2 hi = step(float2(0.65), f);
        if (u.streakMix > 0.01) {
            float2 outward = step(float2(0.0), st);
            float2 near_axis = step(abs(st), float2(2.0));
            hi = max(hi, max(outward, near_axis));
            lo = min(lo, -max(1.0 - outward, near_axis));
        }
        int2 ilo = int2(lo);
        int2 ihi = int2(hi);

        for (int dy = ilo.y; dy <= ihi.y; dy++) {
            for (int dx = ilo.x; dx <= ihi.x; dx++) {
                float2 off = float2(float(dx), float(dy));
                float2 id = gid + off;

                float h1 = warp_hash(id + ld.fi64);
                if (h1 < u.cull) continue;

                float2 sp = warp_hash2(id * 3.14 + ld.fi27) - 0.5;

                float2 ss = (id + sp + 0.5) * ld.inv_scale;
                float2 delta = warp_uv - ss;

                float sr2 = dot(ss, ss);
                float dd2 = dot(delta, delta);

                float ratio = dd2 * ld.inv_ds2;
                float pb = 1.0 / (1.0 + ratio * ratio);

                float sb = 0.0;
                if (u.streakMix > 0.01) {
                    // inv_sr * sr cancels to 1, so sba = ss * (-speed * 0.15)
                    float2 sba = ss * streak_k;
                    float sba2 = dot(sba, sba);
                    float tp = sba2 > 0.0001
                        ? clamp(dot(delta, sba) / sba2, 0.0, 1.0) : 0.0;
                    float2 seg_v = delta - sba * tp;
                    float sw = 0.001 * (1.0 + tp * 0.8);
                    float sratio = dot(seg_v, seg_v) / (sw * sw);
                    sb = u.streakMix * (1.0 - tp * 0.6)
                       / (1.0 + sratio * sratio);
                }

                float b = max(pb, sb) * ld.fade * smoothstep(0.15, 0.8, h1);
                if (b < 0.0001) continue; // quartic falloff makes distant stars negligible

                float sr = 0.0;
                bool use_radial_effects = u.beamingMix > 0.01 || u.dopplerMix > 0.01;
                if (use_radial_effects) {
                    sr = sqrt(sr2);
                }

                if (!skip_twinkle) {
                    b *= mix(
                        0.5 + 0.5 * sin(t * 3.0 + warp_hash(id * 17.0) * 6.283),
                        1.0,
                        u.twinkleSolid
                    );
                }

                if (u.beamingMix > 0.01) {
                    b *= mix(1.0, 1.0 / (1.0 + sr * 4.0), u.beamingMix);
                }

                float cr = fract(sp.x * 7.77 + 0.5);
                float cr_s1 = smoothstep(0.3, 0.8, cr);
                float3 sc = float3(
                    0.5 + 0.45 * cr_s1,
                    0.6 + 0.37 * cr_s1,
                    1.0
                );
                sc = mix(sc, float3(1.0, 0.9, 0.75), smoothstep(0.85, 0.95, cr));

                if (u.dopplerMix > 0.01) {
                    float radial_factor = smoothstep(0.0, 0.6, sr);
                    sc *= mix(float3(1.0),
                              mix(float3(0.7, 0.8, 1.0), float3(1.0, 0.75, 0.5), radial_factor),
                              u.dopplerMix);
                }

                col += sc * (b * u.brightScaled);
            }
        }
    }

    float dist2 = dot(uv, uv);
    float dist = sqrt(dist2);

    if (u.glow > 0.001) {
        col += float3(0.15, 0.2, 0.45) * exp(-dist * 5.0) * u.glow;
        col += float3(0.3, 0.4, 0.65) * exp(-dist * 14.0) * u.glow * 0.5;
        col += float3(0.6, 0.65, 0.8) * exp(-dist * 30.0) * u.glow * 0.3;
    }

    col *= smoothstep(u.vigRadius, 0.5, dist);

    float3 mapped = col * 3.5;
    col = mapped / (1.0 + mapped);

    return float4(col, 1.0);
}
"""

private struct MetalWarpFragmentUniforms {
  var resolution: SIMD2<Float>
  var uvOffset: SIMD2<Float>
  var time: Float
  var speed: Float
  var referenceSize: Float
  var warpFactor: Float
  var streakMix: Float
  var brightScaled: Float
  var tScroll: Float
  var cull: Float
  var dopplerMix: Float
  var beamingMix: Float
  var twinkleSolid: Float
  var glow: Float
  var vigRadius: Float
}

private struct MetalWarpLayerData {
  var scale: Float
  var invScale: Float
  var fade: Float
  var invDs2: Float
  var fi64: Float
  var fi27: Float
}

// swiftlint:disable:next type_body_length
final class WarpLayer: CAMetalLayer, Background {

  // MARK: - Metal Objects
  private var metalDevice: MTLDevice?
  private var commandQueue: MTLCommandQueue?
  private var pipelineState: MTLRenderPipelineState?
  private var vertexBuffer: MTLBuffer?
  private var layerData = Array(
    repeating: MetalWarpLayerData(
      scale: 1.0,
      invScale: 1.0,
      fade: 0.0,
      invDs2: 0.0,
      fi64: 0.0,
      fi27: 0.0
    ),
    count: warpLayerCount
  )

  // MARK: - Animation
  private var totalElapsedTime: CGFloat = 0
  private var lastUpdateTime: CGFloat = 0
  private let minUpdateInterval: CGFloat = 1.0 / 30.0

  // MARK: - Rendering Area
  private weak var currentFruit: Fruit?
  private weak var currentLeaf: Leaf?

  // MARK: - Speed Variation
  private var currentSpeed: CGFloat = 0.1
  private var startSpeed: CGFloat = 0.1
  private var targetSpeed: CGFloat = 10.0
  private var speedTimer: CGFloat = 0
  private var phaseDuration: CGFloat = 15.0
  private var isWarpPhase: Bool = true

  deinit {
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
    self.magnificationFilter = .linear
    updateDrawableSize(for: frame)

    setupMetal()
    setupPipeline()
    createVertexBuffers()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override init(layer: Any) {
    super.init(layer: layer)
    guard let other = layer as? WarpLayer else { return }

    // Only copy plain Swift stored properties. Do NOT access any CAMetalLayer
    // properties (device, pixelFormat, etc.) — this runs inside
    // CA::Layer::presentation_copy where Metal state is not valid yet.
    self.totalElapsedTime = other.totalElapsedTime
    self.currentSpeed = other.currentSpeed
    self.startSpeed = other.startSpeed
    self.targetSpeed = other.targetSpeed
    self.speedTimer = other.speedTimer
    self.phaseDuration = other.phaseDuration
    self.isWarpPhase = other.isWarpPhase
  }

  private func setupMetal() {
    guard let device = MTLCreateSystemDefaultDevice() else { return }
    self.metalDevice = device
    self.device = device

    guard let commandQueue = device.makeCommandQueue() else { return }
    self.commandQueue = commandQueue
  }

  private func updateDrawableSize(for frame: CGRect) {
    drawableSize = CGSize(
      width: max(1, frame.width * contentsScale * warpRenderScale),
      height: max(1, frame.height * contentsScale * warpRenderScale)
    )
  }

  private func setupPipeline() {
    guard let metalDevice = metalDevice else { return }
    do {
      let library = try metalDevice.makeLibrary(source: metalWarpShaderSource, options: nil)
      guard let vertexFunction = library.makeFunction(name: "vertex_shader_warp"),
            let fragmentFunction = library.makeFunction(name: "fragment_shader_warp") else {
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
    updateDrawableSize(for: frame)
    setNeedsDisplay()
  }

  func config(fruit: Fruit, leaf: Leaf) {
    currentFruit = fruit
    currentLeaf = leaf
    setNeedsDisplay()
  }

  private func easeWarpEngage(_ progress: CGFloat) -> CGFloat {
    let overshoot: CGFloat = 3.0
    let doubled = progress * 2.0
    if doubled < 1.0 {
      return 0.5 * (doubled * doubled * ((overshoot + 1.0) * doubled - overshoot))
    }
    let shifted = doubled - 2.0
    return 0.5 * (shifted * shifted * ((overshoot + 1.0) * shifted + overshoot) + 2.0)
  }

  private func easeWarpDisengage(_ progress: CGFloat) -> CGFloat {
    let overshoot: CGFloat = 1.5
    let doubled = progress * 2.0
    if doubled < 1.0 {
      return 0.5 * (doubled * doubled * ((overshoot + 1.0) * doubled - overshoot))
    }
    let shifted = doubled - 2.0
    return 0.5 * (shifted * shifted * ((overshoot + 1.0) * shifted + overshoot) + 2.0)
  }

  func update(deltaTime: CGFloat) {
    speedTimer += deltaTime
    if speedTimer >= phaseDuration {
      speedTimer = 0
      startSpeed = currentSpeed
      isWarpPhase.toggle()
      if isWarpPhase {
        targetSpeed = CGFloat.random(in: 8.0...14.0)
        phaseDuration = CGFloat.random(in: 15.0...30.0)
      } else {
        targetSpeed = CGFloat.random(in: 0.05...0.15)
        phaseDuration = CGFloat.random(in: 25.0...45.0)
      }
    }

    let progress = min(speedTimer / phaseDuration, 1.0)
    let eased = isWarpPhase ? easeWarpEngage(progress) : easeWarpDisengage(progress)
    currentSpeed = max(0, startSpeed + (targetSpeed - startSpeed) * eased)

    totalElapsedTime += deltaTime
    lastUpdateTime += deltaTime

    if lastUpdateTime >= minUpdateInterval {
      lastUpdateTime = 0
      setNeedsDisplay()
    }
  }

  private static func glslSmoothstep(_ edge0: Float, _ edge1: Float, _ value: Float) -> Float {
    let normalized = min(max((value - edge0) / (edge1 - edge0), 0), 1)
    return normalized * normalized * (3 - 2 * normalized)
  }

  private static func glslFract(_ value: Float) -> Float {
    return value - floor(value)
  }

  private static func warpHash(_ point: SIMD2<Float>) -> Float {
    let pointX = point.x, pointY = point.y
    var p3x = glslFract(pointX * 0.1031)
    var p3y = glslFract(pointY * 0.1030)
    var p3z = glslFract(pointX * 0.0973)
    let dotTerm = p3x * (p3y + 33.33) + p3y * (p3z + 33.33) + p3z * (p3x + 33.33)
    p3x += dotTerm; p3y += dotTerm; p3z += dotTerm
    return glslFract((p3x + p3y) * p3z)
  }

  private static func makeFragmentUniforms(time: Float, speed: Float, resolution: SIMD2<Float>,
                                           referenceSize: Float) -> MetalWarpFragmentUniforms {
    let smooth = Self.glslSmoothstep
    let fruitScale = min(min(resolution.x, resolution.y) / referenceSize, 2.0)
    let vib = smooth(0.3, 1.5, speed) * (1.0 - smooth(8.0, 12.0, speed))
    let aberration = 1.0 / (1.0 + speed * 0.04)
    let scroll = 0.02 + (0.5 - 0.02) * smooth(0.1, 10.0, speed)
    return MetalWarpFragmentUniforms(
      resolution: resolution,
      uvOffset: SIMD2<Float>(
        fruitScale * 0.005 + sin(time * 130.0) * vib * 0.001,
        -fruitScale * 0.04 + cos(time * 110.0) * vib * 0.001
      ),
      time: time,
      speed: speed,
      referenceSize: referenceSize,
      warpFactor: 1.0 + (aberration - 1.0) * smooth(2.0, 8.0, speed),
      streakMix: smooth(0.3, 1.5, speed),
      brightScaled: (4.0 + (1.3 - 4.0) * smooth(0.5, 2.0, speed)) * 0.225,
      tScroll: time * scroll,
      cull: 0.12 + (0.28 - 0.12) * smooth(0.3, 2.0, speed),
      dopplerMix: smooth(3.0, 8.0, speed),
      beamingMix: smooth(2.0, 8.0, speed),
      twinkleSolid: smooth(0.3, 1.0, speed),
      glow: smooth(7.0, 12.0, speed) * 0.5,
      vigRadius: 2.0 + (1.2 - 2.0) * smooth(3.0, 10.0, speed)
    )
  }

  private func updateLayerData(tScroll: Float) {
    let smooth = Self.glslSmoothstep
    for index in 0..<warpLayerCount {
      let floatIndex = Float(index)
      let depth = Self.glslFract(
        floatIndex / Float(warpLayerCount) + tScroll + Self.warpHash(SIMD2<Float>(floatIndex, floatIndex * 0.7)) * 0.05
      )
      let scale = 18.0 + (0.8 - 18.0) * depth
      let fade = smooth(0.0, 0.1, depth) * smooth(1.0, 0.8, depth)
      let falloffSize: Float = 0.0018 + 0.0006 * depth
      layerData[index] = MetalWarpLayerData(
        scale: scale,
        invScale: 1.0 / scale,
        fade: fade,
        invDs2: 1.0 / (falloffSize * falloffSize),
        fi64: floatIndex * 64.0,
        fi27: floatIndex * 27.0
      )
    }
  }

  private func applyScissorRect(on encoder: MTLRenderCommandEncoder, resolution: SIMD2<Float>) {
    guard let fruit = currentFruit, let leaf = currentLeaf else { return }
    let body = fruit.bounds(including: leaf)
    let paddedBody = CGRect(x: body.minX - 4, y: body.minY - 4,
                            width: body.width + 8, height: body.height + 8)
    let scaleX = CGFloat(resolution.x) / max(bounds.width, 1)
    let scaleY = CGFloat(resolution.y) / max(bounds.height, 1)
    let scissorX = max(0, Int(paddedBody.minX * scaleX))
    let scissorY = max(0, Int((bounds.height - paddedBody.maxY) * scaleY))
    let scissorWidth = max(0, min(Int(ceil(paddedBody.width * scaleX)), Int(resolution.x) - scissorX))
    let scissorHeight = max(0, min(Int(ceil(paddedBody.height * scaleY)), Int(resolution.y) - scissorY))
    if scissorWidth > 0 && scissorHeight > 0 {
      encoder.setScissorRect(MTLScissorRect(x: scissorX, y: scissorY,
                                            width: scissorWidth, height: scissorHeight))
    }
  }

  // MARK: - Drawing
  override func display() {
    guard let pipelineState = pipelineState,
          let commandQueue = commandQueue,
          let vertexBuffer = vertexBuffer,
          let drawable = nextDrawable() else { return }
    let texture = drawable.texture

    let resolution = SIMD2<Float>(Float(texture.width), Float(texture.height))
    let referenceSize: Float = 300.0 * Float(contentsScale * warpRenderScale)
    var uniforms = Self.makeFragmentUniforms(
      time: Float(totalElapsedTime),
      speed: Float(currentSpeed),
      resolution: resolution,
      referenceSize: referenceSize
    )
    updateLayerData(tScroll: uniforms.tScroll)

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

    renderEncoder.setRenderPipelineState(pipelineState)
    applyScissorRect(on: renderEncoder, resolution: resolution)
    renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
    renderEncoder.setFragmentBytes(
      &uniforms,
      length: MemoryLayout<MetalWarpFragmentUniforms>.stride,
      index: 0
    )
    layerData.withUnsafeBytes { ptr in
      renderEncoder.setFragmentBytes(
        ptr.baseAddress!,
        length: ptr.count,
        index: 1
      )
    }
    renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

    renderEncoder.endEncoding()
    commandBuffer.present(drawable)
    commandBuffer.commit()
  }
}
// swiftlint:enable file_length
