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

fragment float4 fragment_shader_psy(
    VertexOut in [[stage_in]],
    constant PsyUniforms &uniforms [[buffer(0)]]) {

    float2 uv = (in.position.xy * 2.0 - uniforms.resolution) /
                 min(uniforms.resolution.x, uniforms.resolution.y);
    float t = uniforms.time;
    float origR = length(uv);

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

    return float4(color, 1.0);
}
"""

private struct MetalPsyFragmentUniforms {
  var resolution: SIMD2<Float>
  var time: Float
  // swiftlint:disable:next identifier_name
  var color_phase: Float
}

// swiftlint:disable:next type_body_length
final class PsyLayer: CAMetalLayer, Background {

  // MARK: - Metal Objects
  private var metalDevice: MTLDevice?
  private var commandQueue: MTLCommandQueue?
  private var pipelineState: MTLRenderPipelineState?
  private var vertexBuffer: MTLBuffer?

  // MARK: - Animation
  private var totalElapsedTime: CGFloat = 0
  private var colorPhase: CGFloat = 0
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
    guard let other = layer as? PsyLayer else { return }

    // Only copy plain Swift stored properties. Do NOT access any CAMetalLayer
    // properties (device, pixelFormat, etc.) — this runs inside
    // CA::Layer::presentation_copy where Metal state is not valid yet.
    self.totalElapsedTime = other.totalElapsedTime
    self.colorPhase = other.colorPhase
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
      isFastPhase.toggle()
      if isFastPhase {
        targetSpeed = CGFloat.random(in: 1.6...2.8)
        phaseDuration = CGFloat.random(in: 1.5...3.0)
      } else {
        targetSpeed = CGFloat.random(in: 0.08...0.25)
        phaseDuration = CGFloat.random(in: 20.0...40.0)
      }
    }

    let progress = min(speedTimer / phaseDuration, 1.0)
    currentSpeed = startSpeed + (targetSpeed - startSpeed) * easeInOut(progress)

    totalElapsedTime += deltaTime * currentSpeed
    colorPhase = (totalElapsedTime * 0.02).truncatingRemainder(dividingBy: 1.0)
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

    var uniforms = MetalPsyFragmentUniforms(
      resolution: SIMD2<Float>(Float(texture.width), Float(texture.height)),
      time: Float(totalElapsedTime),
      color_phase: Float(colorPhase)
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
      length: MemoryLayout<MetalPsyFragmentUniforms>.stride,
      index: 0
    )
    renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

    renderEncoder.endEncoding()
    commandBuffer.present(drawable)
    commandBuffer.commit()
  }
}
// swiftlint:enable file_length
