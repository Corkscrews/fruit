// swiftlint:disable file_length
import Cocoa
import QuartzCore
import Foundation
import MetalKit

private let metalWarpShaderSource = """
using namespace metal;

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

    for (int i = 0; i < 20; i++) {
        constant WarpLayerData &ld = layers[i];
        if (ld.fade < 0.001) continue;

        float2 st = warp_uv * ld.scale;
        float2 gid = floor(st);

        for (int dy = -1; dy <= 1; dy++) {
            for (int dx = -1; dx <= 1; dx++) {
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

                float inv_sr = rsqrt(max(sr2, 1e-6));
                float sr = sr2 * inv_sr;

                if (!skip_twinkle) {
                    b *= mix(
                        0.5 + 0.5 * sin(t * 3.0 + warp_hash(id * 17.0) * 6.283),
                        1.0,
                        u.twinkleSolid
                    );
                }

                b *= mix(1.0, 1.0 / (1.0 + sr * 4.0), u.beamingMix);

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
  var inv_scale: Float
  var fade: Float
  var inv_ds2: Float
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

  // MARK: - Animation
  private var totalElapsedTime: CGFloat = 0
  private var lastUpdateTime: CGFloat = 0
  private let minUpdateInterval: CGFloat = 1.0 / 30.0

  // MARK: - Rendering Area
  private weak var currentFruit: Fruit?

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
  init(frame: CGRect, fruit: Fruit, contentsScale: CGFloat) {
    super.init()
    self.frame = frame
    self.contentsScale = contentsScale
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
  func update(frame: NSRect, fruit: Fruit) {
    currentFruit = fruit
    setFrameAndDrawableSizeWithoutAnimation(frame)
    setNeedsDisplay()
  }

  func config(fruit: Fruit) {
    currentFruit = fruit
    setNeedsDisplay()
  }

  private func easeWarpEngage(_ t: CGFloat) -> CGFloat {
    let s: CGFloat = 3.0
    let t2 = t * 2.0
    if t2 < 1.0 {
      return 0.5 * (t2 * t2 * ((s + 1.0) * t2 - s))
    }
    let p = t2 - 2.0
    return 0.5 * (p * p * ((s + 1.0) * p + s) + 2.0)
  }

  private func easeWarpDisengage(_ t: CGFloat) -> CGFloat {
    let s: CGFloat = 1.5
    let t2 = t * 2.0
    if t2 < 1.0 {
      return 0.5 * (t2 * t2 * ((s + 1.0) * t2 - s))
    }
    let p = t2 - 2.0
    return 0.5 * (p * p * ((s + 1.0) * p + s) + 2.0)
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

  private static func glslSmoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
    let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
    return t * t * (3 - 2 * t)
  }

  private static func glslFract(_ x: Float) -> Float {
    return x - floor(x)
  }

  private static func warpHash(_ p: SIMD2<Float>) -> Float {
    let px = p.x, py = p.y
    var p3x = glslFract(px * 0.1031)
    var p3y = glslFract(py * 0.1030)
    var p3z = glslFract(px * 0.0973)
    let d = p3x * (p3y + 33.33) + p3y * (p3z + 33.33) + p3z * (p3x + 33.33)
    p3x += d; p3y += d; p3z += d
    return glslFract((p3x + p3y) * p3z)
  }

  // MARK: - Drawing
  override func display() {
    guard let pipelineState = pipelineState,
          let commandQueue = commandQueue,
          let vertexBuffer = vertexBuffer,
          let drawable = nextDrawable() else { return }
    let texture = drawable.texture

    let spd = Float(currentSpeed)
    let time = Float(totalElapsedTime)
    let referenceSize: Float = 300.0 * Float(contentsScale)
    let resW = Float(texture.width)
    let resH = Float(texture.height)

    let ss = Self.glslSmoothstep
    let fruitScale = min(min(resW, resH) / referenceSize, 2.0)
    let vib = ss(0.3, 1.5, spd) * (1.0 - ss(8.0, 12.0, spd))
    let aberration = 1.0 / (1.0 + spd * 0.04)
    let scroll = 0.02 + (0.5 - 0.02) * ss(0.1, 10.0, spd)

    var uniforms = MetalWarpFragmentUniforms(
      resolution: SIMD2<Float>(resW, resH),
      uvOffset: SIMD2<Float>(
        fruitScale * 0.005 + sin(time * 130.0) * vib * 0.001,
        -fruitScale * 0.04 + cos(time * 110.0) * vib * 0.001
      ),
      time: time,
      speed: spd,
      referenceSize: referenceSize,
      warpFactor: 1.0 + (aberration - 1.0) * ss(2.0, 8.0, spd),
      streakMix: ss(0.3, 1.5, spd),
      brightScaled: (4.0 + (1.3 - 4.0) * ss(0.5, 2.0, spd)) * 0.225,
      tScroll: time * scroll,
      cull: 0.02 + (0.15 - 0.02) * ss(0.3, 2.0, spd),
      dopplerMix: ss(3.0, 8.0, spd),
      beamingMix: ss(2.0, 8.0, spd),
      twinkleSolid: ss(0.3, 1.0, spd),
      glow: ss(7.0, 12.0, spd) * 0.5,
      vigRadius: 2.0 + (1.2 - 2.0) * ss(3.0, 10.0, spd)
    )

    var layerData = [MetalWarpLayerData]()
    layerData.reserveCapacity(20)
    for i in 0..<20 {
      let fi = Float(i)
      let z = Self.glslFract(
        fi / 20.0 + uniforms.tScroll + Self.warpHash(SIMD2<Float>(fi, fi * 0.7)) * 0.05
      )
      let scale = 18.0 + (0.8 - 18.0) * z
      let fade = ss(0.0, 0.1, z) * ss(1.0, 0.8, z)
      let ds: Float = 0.0018 + 0.0006 * z
      layerData.append(MetalWarpLayerData(
        scale: scale,
        inv_scale: 1.0 / scale,
        fade: fade,
        inv_ds2: 1.0 / (ds * ds),
        fi64: fi * 64.0,
        fi27: fi * 27.0
      ))
    }

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
    if let fruit = currentFruit {
      let body = fruit.transformedPath.bounds
      let leafExtra = fruit.maxDimen() * 0.231
      let fb = CGRect(x: body.minX - 4, y: body.minY - 4,
                       width: body.width + 8, height: body.height + 8 + leafExtra)
      let cs = contentsScale
      let sx = max(0, Int(fb.minX * cs))
      let sy = max(0, Int((bounds.height - fb.maxY) * cs))
      let sw = min(Int(fb.width * cs), Int(resW) - sx)
      let sh = min(Int(fb.height * cs), Int(resH) - sy)
      if sw > 0 && sh > 0 {
        renderEncoder.setScissorRect(MTLScissorRect(x: sx, y: sy, width: sw, height: sh))
      }
    }
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
