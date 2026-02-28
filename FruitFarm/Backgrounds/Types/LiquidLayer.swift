// swiftlint:disable file_length
import Cocoa
import QuartzCore
import Foundation
import MetalKit

private let metalLiquidShaderSource = """
using namespace metal;

struct VertexData {
    float2 position;
};

struct VertexOut {
    float4 position [[position]];
};

vertex VertexOut vertex_shader_liquid(
    const device VertexData* vertex_array [[buffer(0)]],
    unsigned int vid [[vertex_id]]) {
    VertexOut out;
    out.position = float4(vertex_array[vid].position, 0.0, 1.0);
    return out;
}

struct LiquidUniforms {
    float2 resolution;
    float time;
    float color_phase;
};

float3 liquid_hsv2rgb(float3 c) {
    float3 p = abs(fract(float3(c.x) + float3(0.0, 2.0/3.0, 1.0/3.0)) * 6.0 - 3.0);
    return c.z * mix(float3(1.0), clamp(p - 1.0, 0.0, 1.0), c.y);
}

float2 liquid_domain_warp(float2 p, float t, float seed) {
    return float2(
        sin(p.y * 3.7 + t * 0.73 + seed) + cos(p.x * 2.3 - t * 0.51),
        cos(p.x * 3.3 - t * 0.67 + seed) + sin(p.y * 2.7 + t * 0.43)
    );
}

float liquid_plasma(float2 p, float t) {
    float v = 0.0;
    v += sin(p.x * 10.0 + t);
    v += sin((p.y * 10.0 + t) * 0.5);
    v += sin((p.x * 10.0 + p.y * 10.0 + t) * 0.33);
    float cx = p.x + 0.5 * sin(t * 0.33);
    float cy = p.y + 0.5 * cos(t * 0.5);
    v += sin(sqrt(cx * cx + cy * cy + 1.0) * 10.0 + t);
    return v * 0.25;
}

// SDF of the fruit body derived from Fruit.swift bezier path.
// Original path bbox: x [35.5, 112.5], y [49.36, 119.61] (77 x 70).
// After the pi-rotation + scale + translate applied by FruitView,
// the bite lands on the right side and the stem at the top.
float liquid_sd_fruit(float2 p) {
    // Main body: ellipse matching the 77:70 aspect ratio
    float body = length(p * float2(0.91, 1.0)) - 0.5;

    // Bite cutout on the right, centered slightly above midline
    float bite = length(p - float2(0.52, -0.04)) - 0.22;
    body = max(body, -bite);

    // Heart-shaped indent at the top where the stem sits
    float dip = smoothstep(0.12, 0.0, abs(p.x)) * smoothstep(0.0, -0.52, p.y);
    body += dip * 0.04;

    return body;
}

// SDF of the leaf derived from Leaf.swift bezier path.
// Intersection of two offset circles, tilted ~20 deg.
float liquid_sd_leaf(float2 p) {
    float2 lp = p - float2(0.1, -0.56);
    float ca = cos(-0.35);
    float sa = sin(-0.35);
    lp = float2(ca * lp.x - sa * lp.y, sa * lp.x + ca * lp.y);
    float d1 = length(lp - float2(0.0, 0.04)) - 0.1;
    float d2 = length(lp - float2(0.0, -0.04)) - 0.1;
    return max(d1, d2);
}

fragment float4 fragment_shader_liquid(
    VertexOut in [[stage_in]],
    constant LiquidUniforms &uniforms [[buffer(0)]]) {

    float2 uv = (in.position.xy * 2.0 - uniforms.resolution) /
                 min(uniforms.resolution.x, uniforms.resolution.y);
    float t = uniforms.time;

    // Fruit + leaf signed-distance drives all contour-based effects
    float fruit = liquid_sd_fruit(uv);
    float leaf  = liquid_sd_leaf(uv);
    float shape = min(fruit, leaf);
    float origR = length(uv);

    // Multi-pass domain warping for organic flow
    float2 p = uv;
    float amp = 0.65;
    for (int i = 0; i < 5; i++) {
        p = liquid_domain_warp(p, t * 0.7 + float(i) * 1.37, float(i) * 2.19) * amp;
        amp *= 0.82;
    }

    // Plasma field
    float pl = liquid_plasma(uv * 0.8 + p * 0.3, t * 0.9);

    // Fruit-contour concentric rings (follow the silhouette)
    float fruitRings = sin(shape * 30.0 - t * 3.0) * 0.5 + 0.5;

    // Interference from warped coordinates
    float interference = 0.0;
    interference += sin(p.x * 9.0 + t * 1.3) * cos(p.y * 7.0 - t * 0.8);
    interference += sin(length(p) * 14.0 - t * 2.2) * 0.6;
    interference += cos(atan2(p.y, p.x) * 6.0 + t * 0.7 + length(p) * 10.0) * 0.4;
    interference *= 0.25;

    // Spiral that traces the fruit contour
    float angle = atan2(uv.y, uv.x);
    float spiral = sin(shape * 25.0 + angle * 4.0 - t * 2.5);
    float spiralMask = smoothstep(-0.5, 0.5, shape) * 0.1;

    // Hue: warped angle + shape distance + plasma
    float hue = fract(
        atan2(p.y, p.x) / (2.0 * M_PI_F) + 0.5
        + t * 0.035
        + pl * 0.18
        + shape * 0.2
        + spiral * spiralMask
        + uniforms.color_phase
    );

    // Saturation: vivid, modulated by shape distance
    float sat = 0.8 + 0.2 * sin(shape * 8.0 + t * 1.2 + pl * 3.0);

    // Value: layered from fruit-contour rings + plasma + interference
    float val = 0.45
        + 0.3 * fruitRings
        + 0.1 * pl
        + interference * 0.12;

    // Pulsing glow along the fruit edge (zero-crossing of the SDF)
    float edgeGlow = exp(-shape * shape * 50.0);
    val += edgeGlow * 0.4 * (0.5 + 0.5 * sin(t * 2.0));

    // Subtle center pulse
    float centerGlow = exp(-origR * origR * 3.0);
    val = mix(val, 1.0, centerGlow * 0.2 * (0.5 + 0.5 * sin(t * 1.3)));

    sat = clamp(sat, 0.0, 1.0);
    val = clamp(val, 0.05, 1.0);

    float3 color = liquid_hsv2rgb(float3(hue, sat, val));

    // Soft vignette
    float vignette = 1.0 - smoothstep(0.8, 2.0, origR);
    color *= mix(0.3, 1.0, vignette);

    return float4(color, 1.0);
}
"""

private struct MetalLiquidFragmentUniforms {
  var resolution: SIMD2<Float>
  var time: Float
  // swiftlint:disable:next identifier_name
  var color_phase: Float
}

// swiftlint:disable:next type_body_length
final class LiquidLayer: CAMetalLayer, Background {

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
    guard let other = layer as? LiquidLayer else { return }

    let device = other.metalDevice ?? MTLCreateSystemDefaultDevice()
    guard let device = device else { return }
    self.metalDevice = device
    self.device = device

    self.pixelFormat = other.pixelFormat != .invalid ? other.pixelFormat : .bgra8Unorm
    self.framebufferOnly = other.framebufferOnly
    self.isOpaque = other.isOpaque

    self.totalElapsedTime = other.totalElapsedTime
    self.colorPhase = other.colorPhase

    self.commandQueue = device.makeCommandQueue()
    setupPipeline()
    createVertexBuffers()
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
      let library = try metalDevice.makeLibrary(source: metalLiquidShaderSource, options: nil)
      guard let vertexFunction = library.makeFunction(name: "vertex_shader_liquid"),
            let fragmentFunction = library.makeFunction(name: "fragment_shader_liquid") else {
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
    self.frame = frame
    setNeedsDisplay()
  }

  func config(fruit: Fruit) {
    setNeedsDisplay()
  }

  func update(deltaTime: CGFloat) {
    totalElapsedTime += deltaTime
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

    var uniforms = MetalLiquidFragmentUniforms(
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
      length: MemoryLayout<MetalLiquidFragmentUniforms>.stride,
      index: 0
    )
    renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

    renderEncoder.endEncoding()
    commandBuffer.present(drawable)
    commandBuffer.commit()
  }
}
// swiftlint:enable file_length
