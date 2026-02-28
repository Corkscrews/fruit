// swiftlint:disable file_length
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
    float2 resolution;
    float time;
};

float3 puppy_hsv2rgb(float3 c) {
    float3 p = abs(fract(float3(c.x) + float3(0.0, 2.0/3.0, 1.0/3.0)) * 6.0 - 3.0);
    return c.z * mix(float3(1.0), clamp(p - 1.0, 0.0, 1.0), c.y);
}

float puppy_smin(float a, float b, float k) {
    float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
}

float puppy_fruit_sdf(float2 p) {
    // Narrow horizontally to get the taller-than-wide Fruit proportions
    float ax = 1.45;
    float2 q = float2(p.x * ax, p.y);

    // Body: two large circles, tight smooth union for clean silhouette
    float dl = length(q - float2(-0.20, -0.04)) - 0.50;
    float dr = length(q - float2( 0.20, -0.04)) - 0.50;
    float d = puppy_smin(dl, dr, 0.08);

    // Top notch between shoulders
    float notch = length(q - float2(0.0, 0.50)) - 0.16;
    d = max(d, -notch);

    // Bottom cleft
    float bdip = length(q - float2(0.0, -0.60)) - 0.06;
    d = max(d, -bdip);

    // Convert body SDF to p-space
    d /= ax;

    // Bite (computed in p-space so it stays circular)
    float bite = length(p - float2(0.44, 0.04)) - 0.155;
    d = max(d, -bite);

    // Leaf (rotated ellipse in p-space)
    float2 lp = p - float2(0.04, 0.38);
    float la = -0.45;
    float ca = cos(la);
    float sa = sin(la);
    float2 rp = float2(lp.x * ca - lp.y * sa, lp.x * sa + lp.y * ca);
    float2 radii = float2(0.05, 0.12);
    float leaf = length(rp / radii) - 1.0;
    leaf *= min(radii.x, radii.y);
    d = min(d, leaf);

    return d;
}

fragment float4 fragment_shader_puppy(
    VertexOut in [[stage_in]],
    constant PuppyUniforms &uniforms [[buffer(0)]]) {

    float2 uv = (in.position.xy * 2.0 - uniforms.resolution) /
                 min(uniforms.resolution.x, uniforms.resolution.y);
    uv.y = -uv.y;
    uv.y += 0.06;

    float t = uniforms.time;
    float3 color = float3(0.0);
    float minRes = min(uniforms.resolution.x, uniforms.resolution.y);

    const int numLayers = 16;
    const float scaleRatio = 1.28;
    const float baseScale = 0.06;

    float animPhase = fract(t * 0.25);

    for (int i = numLayers - 1; i >= 0; i--) {
        float fi = float(i) + animPhase;
        float scale = baseScale * pow(scaleRatio, fi);

        if (scale > 5.0 || scale < 0.005) continue;

        float2 p = uv / scale;
        float d = puppy_fruit_sdf(p);

        float aa = 1.5 / (scale * minRes * 0.5);
        float inside = 1.0 - smoothstep(-aa, aa, d);

        float edgeDist = abs(d) * scale;
        float edge = exp(-edgeDist * edgeDist * 600.0);

        float depth = clamp(fi / float(numLayers), 0.0, 1.0);

        float hue = 0.58 + fi * 0.018 + t * 0.015;
        float sat = 0.7 + 0.3 * depth;

        // Smooth cosine blend replaces the hard i%2 switch so
        // the bright/dark alternation travels with the zoom
        float blend = 0.5 + 0.5 * cos(fi * 3.14159);
        float val = 0.4 + 0.5 * depth;
        float3 brightColor = puppy_hsv2rgb(float3(hue, sat, val));
        float3 darkColor = float3(0.01, 0.012, 0.035);
        float3 layerColor = mix(darkColor, brightColor, blend);

        float3 edgeColor = puppy_hsv2rgb(float3(hue, 0.5, 1.0));

        // Wider fade-in so the innermost layer enters at near-zero opacity
        float opacity = smoothstep(0.05, 0.12, scale) * smoothstep(5.0, 2.5, scale);

        color = mix(color, layerColor, inside * opacity);
        color += edgeColor * edge * opacity * 0.35;
    }

    // Vignette
    float vignette = 1.0 - smoothstep(0.6, 2.0, length(uv));
    color *= mix(0.35, 1.0, vignette);

    color = clamp(color, 0.0, 1.0);
    return float4(color, 1.0);
}
"""

private struct MetalPuppyFragmentUniforms {
  var resolution: SIMD2<Float>
  var time: Float
}

final class PuppyLayer: CAMetalLayer, Background {

  // MARK: - Metal Objects
  private var metalDevice: MTLDevice?
  private var commandQueue: MTLCommandQueue?
  private var pipelineState: MTLRenderPipelineState?
  private var vertexBuffer: MTLBuffer?

  // MARK: - Animation
  private var totalElapsedTime: CGFloat = 0
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
    guard let other = layer as? PuppyLayer else { return }

    let device = other.metalDevice ?? MTLCreateSystemDefaultDevice()
    guard let device = device else { return }
    self.metalDevice = device
    self.device = device

    self.pixelFormat = other.pixelFormat != .invalid ? other.pixelFormat : .bgra8Unorm
    self.framebufferOnly = other.framebufferOnly
    self.isOpaque = other.isOpaque

    self.totalElapsedTime = other.totalElapsedTime

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

    var uniforms = MetalPuppyFragmentUniforms(
      resolution: SIMD2<Float>(Float(texture.width), Float(texture.height)),
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

    renderEncoder.setRenderPipelineState(pipelineState)
    renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
    renderEncoder.setFragmentBytes(
      &uniforms,
      length: MemoryLayout<MetalPuppyFragmentUniforms>.stride,
      index: 0
    )
    renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

    renderEncoder.endEncoding()
    commandBuffer.present(drawable)
    commandBuffer.commit()
  }
}
// swiftlint:enable file_length
