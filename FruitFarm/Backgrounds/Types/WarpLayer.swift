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
    float time;
    float speed;
    float referenceSize;
};

float warp_hash(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

fragment float4 fragment_shader_warp(
    VertexOut in [[stage_in]],
    constant WarpUniforms &uniforms [[buffer(0)]]) {

    float2 uv = (in.position.xy - uniforms.resolution * 0.5) /
                 uniforms.referenceSize;

    float fruitScale = min(
        min(uniforms.resolution.x, uniforms.resolution.y) / uniforms.referenceSize,
        2.0);
    uv.y -= fruitScale * 0.04;
    uv.x += fruitScale * 0.005;

    float t = uniforms.time;
    float spd = uniforms.speed;

    // 0 = dots only, 1 = full streaks
    float streak_mix = smoothstep(0.3, 1.5, spd);
    // always visible, brighter at warp
    float bright = mix(1.0, 1.3, smoothstep(0.5, 2.0, spd));

    float3 col = float3(0.0);

    for (int i = 0; i < 20; i++) {
        float fi = float(i);
        float z = fract(fi / 20.0 + t * 0.25);
        float scale = mix(18.0, 0.8, z);
        float fade = smoothstep(0.0, 0.1, z) * smoothstep(1.0, 0.8, z);

        float2 st = uv * scale;
        float2 gid = floor(st);
        float2 gf = fract(st) - 0.5;

        for (int dy = -1; dy <= 1; dy++) {
            for (int dx = -1; dx <= 1; dx++) {
                float2 off = float2(float(dx), float(dy));
                float2 id = gid + off;

                float h1 = warp_hash(id + fi * 64.0);
                if (h1 < 0.15) continue;

                float rx = warp_hash(id * 3.14 + fi * 27.0);
                float ry = warp_hash(id * 2.71 + fi * 43.0);
                float2 sp = float2(rx, ry) - 0.5;

                // Particle screen position
                float2 ss = (gid + off + sp + 0.5) / scale;
                float sr = length(ss);

                // --- Dot: tight gaussian, always visible ---
                float dd = length(uv - ss);
                float ds = 0.0018 + 0.0006 * z;
                float pb = exp(-dd * dd / (ds * ds));

                // --- Streak: line segment toward center, warp only ---
                float sb = 0.0;
                if (streak_mix > 0.01) {
                    float slen = spd * sr * 0.15;
                    float2 sdir = sr > 0.001 ? normalize(ss) : float2(0.0);
                    float2 sa = ss;
                    float2 sba = -sdir * slen;
                    float sba2 = dot(sba, sba);
                    float2 pa = uv - sa;
                    float tp = sba2 > 0.0001
                        ? clamp(dot(pa, sba) / sba2, 0.0, 1.0) : 0.0;
                    float seg_d = length(pa - sba * tp);
                    float sw = 0.001;
                    sb = exp(-seg_d * seg_d / (sw * sw))
                       * streak_mix * (1.0 - tp * 0.6);
                }

                float b = max(pb, sb) * fade;
                b *= smoothstep(0.15, 0.8, h1);

                // Twinkle at low speed, solid at warp
                float tw = mix(
                    0.5 + 0.5 * sin(t * 3.0 + warp_hash(id * 17.0) * 6.283),
                    1.0,
                    smoothstep(0.3, 1.0, spd)
                );
                b *= tw;

                float cr = warp_hash(id * 7.77 + fi);
                float3 sc = mix(
                    float3(0.5, 0.6, 1.0),
                    float3(0.95, 0.97, 1.0),
                    smoothstep(0.3, 0.8, cr)
                );
                sc = mix(sc, float3(1.0, 0.9, 0.75),
                         smoothstep(0.85, 0.95, cr));

                col += sc * b * bright * 0.15;
            }
        }
    }

    float dist = length(uv);

    // Central glow — only appears near peak warp (70%+ of max ~7.0)
    float gf2 = smoothstep(4.5, 6.5, spd) * 0.5;
    col += float3(0.15, 0.2, 0.45) * exp(-dist * 5.0) * gf2;
    col += float3(0.3, 0.4, 0.65) * exp(-dist * 14.0) * gf2 * 0.5;
    col += float3(0.6, 0.65, 0.8) * exp(-dist * 30.0) * gf2 * 0.3;

    col *= smoothstep(2.0, 0.5, dist);
    col = pow(1.0 - exp(-col * 3.5), float3(0.9));

    return float4(col, 1.0);
}
"""

private struct MetalWarpFragmentUniforms {
  var resolution: SIMD2<Float>
  var time: Float
  var speed: Float
  var referenceSize: Float
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

  // MARK: - Speed Variation
  private var currentSpeed: CGFloat = 0.3
  private var startSpeed: CGFloat = 0.3
  private var targetSpeed: CGFloat = 5.0
  private var speedTimer: CGFloat = 0
  private var phaseDuration: CGFloat = 2.0
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
    setFrameAndDrawableSizeWithoutAnimation(frame)
    setNeedsDisplay()
  }

  func config(fruit: Fruit) {
    setNeedsDisplay()
  }

  private func easeInOut(_ t: CGFloat) -> CGFloat {
    let p: CGFloat = 4.0
    if t < 0.5 {
      return 0.5 * pow(2.0 * t, p)
    } else {
      return 1.0 - 0.5 * pow(2.0 * (1.0 - t), p)
    }
  }

  func update(deltaTime: CGFloat) {
    speedTimer += deltaTime
    if speedTimer >= phaseDuration {
      speedTimer = 0
      startSpeed = currentSpeed
      isWarpPhase.toggle()
      if isWarpPhase {
        targetSpeed = CGFloat.random(in: 4.0...7.0)
        phaseDuration = CGFloat.random(in: 10.0...25.0)
      } else {
        targetSpeed = CGFloat.random(in: 0.4...0.7)
        phaseDuration = CGFloat.random(in: 3.0...5.0)
      }
    }

    let progress = min(speedTimer / phaseDuration, 1.0)
    currentSpeed = startSpeed + (targetSpeed - startSpeed) * easeInOut(progress)

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
          let drawable = nextDrawable() else { return }
    let texture = drawable.texture

    var uniforms = MetalWarpFragmentUniforms(
      resolution: SIMD2<Float>(Float(texture.width), Float(texture.height)),
      time: Float(totalElapsedTime),
      speed: Float(currentSpeed),
      referenceSize: 300.0 * Float(contentsScale)
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

    renderEncoder.setRenderPipelineState(pipelineState)
    renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
    renderEncoder.setFragmentBytes(
      &uniforms,
      length: MemoryLayout<MetalWarpFragmentUniforms>.stride,
      index: 0
    )
    renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

    renderEncoder.endEncoding()
    commandBuffer.present(drawable)
    commandBuffer.commit()
  }
}
// swiftlint:enable file_length
