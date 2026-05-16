// swiftlint:disable file_length
import Cocoa
import QuartzCore
import Foundation
import MetalKit

private let metalMetallicShaderSource = """
using namespace metal;

struct VertexData {
    float2 position;
};

struct VertexOut {
    float4 position [[position]];
};

vertex VertexOut vertex_shader_metallic(
    const device VertexData* vertex_array [[buffer(0)]],
    unsigned int vid [[vertex_id]]) {
    VertexOut out;
    out.position = float4(vertex_array[vid].position, 0.0, 1.0);
    return out;
}

struct MetallicUniforms {
    float2 resolution;
    float2 body_center_px;
    float2 body_half_px;
    float time;
};

float metallic_hash(float2 p) {
    return fract(sin(dot(p, float2(41.0, 289.0))) * 45758.5453);
}

float metallic_line(float value, float width) {
    return exp(-(value * value) / max(width * width, 0.0001));
}

float metallic_bloom(float2 lp, float2 center, float2 axes, float falloff) {
    float2 d = (lp - center) / max(axes, float2(0.001));
    return exp(-falloff * dot(d, d));
}

// Smooth gallium-like heightfield: overlapping soft blobs + wave folds.
float metallic_gallium(float2 p, float a) {
    float2 q = p;
    q.x += 0.30 * sin(p.y * 1.8 + sin(a) * 1.1);
    q.y += 0.22 * cos(p.x * 2.2 + cos(a) * 0.9);

    float v = 0.0;
    float2 c0 = float2(-0.55 + 0.15 * cos(a), -0.30 + 0.12 * sin(a));
    float2 c1 = float2( 0.50 + 0.12 * sin(a * 2.0), 0.25 + 0.10 * cos(a));
    float2 c2 = float2(-0.10 + 0.10 * cos(a * 3.0), 0.72 + 0.06 * sin(a));
    float2 c3 = float2( 0.80 + 0.08 * cos(a), -0.55 + 0.10 * sin(a * 2.0));
    float2 c4 = float2(-0.75 + 0.06 * sin(a * 2.0), 0.45 + 0.08 * cos(a * 3.0));
    float2 c5 = float2( 0.15 + 0.12 * sin(a), -0.78 + 0.06 * cos(a * 2.0));

    v += exp(-3.0 * dot(q - c0, q - c0));
    v += exp(-2.6 * dot(q - c1, q - c1));
    v += exp(-2.8 * dot(q - c2, q - c2));
    v += exp(-3.5 * dot(q - c3, q - c3));
    v += exp(-4.0 * dot(q - c4, q - c4));
    v += exp(-3.2 * dot(q - c5, q - c5));

    v += 0.35 * sin(q.x * 2.2 + q.y * 1.5 + sin(a) * 1.4);
    v += 0.25 * cos(q.x * 1.6 - q.y * 2.8 + cos(a) * 1.2);
    v += 0.18 * sin((q.x + q.y) * 3.2 + sin(a * 2.0));
    return v;
}

float3 metallic_surface_color(float2 lp, float a) {
    float2 p = float2(lp.x + lp.y * 0.12, lp.y - lp.x * 0.08);

    // Heightfield and numeric surface normals
    float e = 0.010;
    float hx = metallic_gallium(p + float2(e, 0.0), a) - metallic_gallium(p - float2(e, 0.0), a);
    float hy = metallic_gallium(p + float2(0.0, e), a) - metallic_gallium(p - float2(0.0, e), a);
    float3 n = normalize(float3(-hx * 5.0, -hy * 5.0, 0.28));

    // Environment: bright top hemisphere, grey sides, dark bottom
    float3 envUp   = float3(0.72, 0.74, 0.78);
    float3 envSide = float3(0.28, 0.32, 0.38);
    float3 envDown = float3(0.03, 0.03, 0.04);
    float3 envColor = mix(envDown, envUp, smoothstep(-0.75, 0.55, n.y));
    envColor = mix(envColor, envSide, smoothstep(0.15, 0.85, abs(n.x)) * 0.55);

    // Fresnel: steep edges reflect more
    float fresnel = pow(1.0 - clamp(n.z, 0.0, 1.0), 3.0);
    float3 color = envColor * (0.50 + 0.50 * fresnel);

    // Three specular lights for narrow highlights
    float3 L1 = normalize(float3(-0.30, -0.55, 0.78));
    float3 L2 = normalize(float3( 0.50,  0.28, 0.82));
    float3 L3 = normalize(float3( 0.0,  -0.80, 0.60));
    float spec1 = pow(clamp(dot(n, L1), 0.0, 1.0), 56.0);
    float spec2 = pow(clamp(dot(n, L2), 0.0, 1.0), 42.0);
    float spec3 = pow(clamp(dot(n, L3), 0.0, 1.0), 68.0);
    color += float3(1.00, 0.99, 0.94) * spec1 * 0.90;
    color += float3(0.85, 0.92, 1.00) * spec2 * 0.70;
    color += float3(1.00, 0.97, 0.90) * spec3 * 0.55;

    // Deep narrow creases where surface curves away sharply
    float crease = smoothstep(0.38, 0.10, n.z);
    color *= 1.0 - crease * 0.92;

    // Broad bright areas where surface faces viewer
    float facing = smoothstep(0.50, 0.92, n.z);
    color += float3(0.90, 0.92, 0.94) * facing * 0.18;

    // Warm highlights / cool shadows tinting
    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = mix(color * float3(0.90, 0.93, 1.06), color * float3(1.04, 1.01, 0.96), smoothstep(0.28, 0.72, lum));

    // Reduce overall brightness, increase contrast
    color *= 0.58;
    color = (color - 0.5) * 1.55 + 0.5;

    return color;
}

fragment float4 fragment_shader_metallic(
    VertexOut in [[stage_in]],
    constant MetallicUniforms &uniforms [[buffer(0)]]) {

    float2 half_px = max(uniforms.body_half_px, float2(1.0));
    float2 lp = (in.position.xy - uniforms.body_center_px) / half_px;

    float loop = fract(uniforms.time / 14.0);
    float a = loop * 6.28318530718;

    float2 chromaDirection = normalize(lp + float2(0.0001));
    float2 chromaOffset = chromaDirection * 0.0055;

    float3 centerColor = metallic_surface_color(lp, a);
    float3 splitColor = float3(
        metallic_surface_color(lp + chromaOffset, a).r,
        centerColor.g,
        metallic_surface_color(lp - chromaOffset, a).b
    );
    float3 color = mix(centerColor, splitColor, 0.55);

    // Fine film-grain noise (per-pixel, temporal)
    float grain = metallic_hash(floor(in.position.xy) + fract(uniforms.time * 37.0)) - 0.5;
    color += float3(grain * 0.025);

    color = pow(clamp(color, 0.0, 1.0), float3(0.94));
    return float4(color, 1.0);
}
"""

private struct MetalMetallicFragmentUniforms {
  var resolution: SIMD2<Float>
  // swiftlint:disable identifier_name
  var body_center_px: SIMD2<Float>
  var body_half_px: SIMD2<Float>
  var time: Float
  // swiftlint:enable identifier_name
}

// swiftlint:disable:next type_body_length
final class MetallicLayer: CAMetalLayer, Background {

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
    guard let other = layer as? MetallicLayer else { return }

    // Presentation copies should only copy plain Swift state.
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
      let library = try metalDevice.makeLibrary(source: metalMetallicShaderSource, options: nil)
      guard let vertexFunction = library.makeFunction(name: "vertex_shader_metallic"),
            let fragmentFunction = library.makeFunction(name: "fragment_shader_metallic") else {
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

    let cs = contentsScale
    var bodyCenterPx = SIMD2<Float>(
      Float(texture.width) * 0.5,
      Float(texture.height) * 0.5
    )
    var bodyHalfPx = SIMD2<Float>(
      Float(texture.width) * 0.25,
      Float(texture.height) * 0.25
    )
    if let fruit = currentFruit {
      let body = fruit.transformedPath.bounds
      let centerX = body.midX * cs
      let centerY = (bounds.height - body.midY) * cs
      bodyCenterPx = SIMD2<Float>(Float(centerX), Float(centerY))
      bodyHalfPx = SIMD2<Float>(
        Float((body.width * 0.5) * cs),
        Float((body.height * 0.5) * cs)
      )
    }

    var uniforms = MetalMetallicFragmentUniforms(
      resolution: SIMD2<Float>(Float(texture.width), Float(texture.height)),
      body_center_px: bodyCenterPx,
      body_half_px: bodyHalfPx,
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
    if let fruit = currentFruit {
      let body = fruit.transformedPath.bounds
      let leafExtra = fruit.maxDimen() * 0.231
      let fb = CGRect(x: body.minX - 4, y: body.minY - 4,
                       width: body.width + 8, height: body.height + 8 + leafExtra)
      let cs = contentsScale
      let sx = max(0, Int(fb.minX * cs))
      let sy = max(0, Int((bounds.height - fb.maxY) * cs))
      let sw = min(Int(fb.width * cs), texture.width - sx)
      let sh = min(Int(fb.height * cs), texture.height - sy)
      if sw > 0 && sh > 0 {
        renderEncoder.setScissorRect(MTLScissorRect(x: sx, y: sy, width: sw, height: sh))
      }
    }
    renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
    renderEncoder.setFragmentBytes(
      &uniforms,
      length: MemoryLayout<MetalMetallicFragmentUniforms>.stride,
      index: 0
    )
    renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

    renderEncoder.endEncoding()
    commandBuffer.present(drawable)
    commandBuffer.commit()
  }
}
// swiftlint:enable file_length
