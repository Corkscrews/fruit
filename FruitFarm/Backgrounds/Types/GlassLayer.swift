// swiftlint:disable file_length
import Cocoa
import QuartzCore
import Foundation
import MetalKit

private let metalGlassShaderSource = """
using namespace metal;

struct VertexData {
    float2 position;
};

struct VertexOut {
    float4 position [[position]];
};

vertex VertexOut vertex_shader_glass(
    const device VertexData* vertex_array [[buffer(0)]],
    unsigned int vid [[vertex_id]]) {
    VertexOut out;
    out.position = float4(vertex_array[vid].position, 0.0, 1.0);
    return out;
}

struct GlassUniforms {
    float2 resolution;
    float2 body_center_px;
    float2 body_half_px;
    float time;
    float color_phase;
};

float glass_hash(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453123);
}

float glass_noise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = glass_hash(i);
    float b = glass_hash(i + float2(1.0, 0.0));
    float c = glass_hash(i + float2(0.0, 1.0));
    float d = glass_hash(i + float2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float glass_fbm(float2 p) {
    float v = 0.0;
    float amp = 0.5;
    for (int i = 0; i < 4; i++) {
        v += amp * glass_noise(p);
        p = float2(p.x * 1.82 + p.y * 0.44,
                   p.y * 1.76 - p.x * 0.39) + 13.0;
        amp *= 0.52;
    }
    return v;
}

// Anisotropic gaussian bloom in apple-relative space.
float glass_bloom(float2 lp, float2 center, float2 axes, float falloff) {
    float2 d = (lp - center) / max(axes, float2(0.001));
    return exp(-falloff * dot(d, d));
}

fragment float4 fragment_shader_glass(
    VertexOut in [[stage_in]],
    constant GlassUniforms &uniforms [[buffer(0)]]) {

    // Apple-relative coordinates: roughly [-1, 1] across the fruit body.
    // lp.y > 0 is the lower half of the fruit (Metal y-down).
    float2 half_px = max(uniforms.body_half_px, float2(1.0));
    float2 lp = (in.position.xy - uniforms.body_center_px) / half_px;

    float loop = fract(uniforms.time / 14.0);
    float a = loop * 6.28318530718;

    float2 skew = float2(
        lp.x + 0.22 * lp.y + 0.10 * sin(lp.y * 4.0 + cos(a) * 1.2),
        lp.y - 0.15 * lp.x + 0.08 * sin(lp.x * 5.0 + sin(a) * 1.4)
    );
    float2 bend = float2(
        skew.x + 0.18 * sin(skew.y * 3.4 + sin(a)),
        skew.y + 0.14 * sin(skew.x * 4.2 + cos(a))
    );

    float edgeShape = max(abs(bend.x * 0.82 + 0.08 * sin(bend.y * 6.0)),
                          abs(bend.y * 0.92 - 0.10 * sin(bend.x * 5.0)));
    float edgeWeight = smoothstep(0.52, 1.08, edgeShape);
    float rim = smoothstep(0.72, 1.02, edgeShape) * (1.0 - smoothstep(1.02, 1.26, edgeShape));

    float stressA = sin(bend.x * 5.1 + bend.y * 1.9 + sin(a) * 1.4);
    float stressB = sin(bend.y * 4.3 - bend.x * 2.7 + cos(a * 2.0) * 1.1);
    float stressC = sin((bend.x + bend.y * 0.6) * 7.2 + sin(a * 3.0) * 0.9);
    float baseBand = exp(-pow((lp.y - 0.72 - 0.08 * sin(lp.x * 4.0 + sin(a))) * 4.0, 2.0));
    float retardance = 4.0
        + stressA * 2.0
        + stressB * 1.7
        + stressC * 0.9
        + edgeWeight * 8.5
        + baseBand * 5.0
        + sin(a) * 1.2;

    float3 spectrum = 0.5 + 0.5 * cos(
        retardance * float3(0.92, 1.19, 1.55) + float3(0.0, 2.1, 4.35)
    );
    spectrum = pow(clamp(spectrum, 0.0, 1.0), float3(0.38));

    float3 baseGlass = float3(0.085, 0.075, 0.105);
    float3 color = baseGlass + spectrum * (0.48 + edgeWeight * 0.78);
    color += spectrum * rim * 2.10;

    float2 dRed = float2(0.10 * cos(a), 0.05 * sin(a * 2.0));
    float2 dCyan = float2(0.06 * sin(a * 2.0 + 0.8), 0.10 * cos(a));
    float2 dYellow = float2(0.12 * cos(a * 3.0 + 1.1), 0.05 * sin(a));
    float2 dMagenta = float2(0.08 * sin(a + 2.4), 0.04 * cos(a * 3.0));
    float2 dCyanTop = float2(0.05 * cos(a * 2.0 + 4.1), 0.07 * sin(a + 0.3));

    float redCorner = glass_bloom(bend, float2(-0.92,  0.78) + dRed, float2(0.52, 0.36), 5.0);
    float cyanCorner = glass_bloom(bend, float2( 0.88,  0.56) + dCyan, float2(0.42, 0.52), 5.2);
    float yellowBase = glass_bloom(bend, float2(-0.02,  0.98) + dYellow, float2(0.82, 0.24), 4.2);
    float magentaTop = glass_bloom(bend, float2( 0.35, -0.88) + dMagenta, float2(0.42, 0.24), 6.0);
    float cyanTop = glass_bloom(bend, float2(-0.58, -0.72) + dCyanTop, float2(0.34, 0.26), 6.0);

    float pulseRed = 0.85 + 0.25 * sin(a);
    float pulseCyan = 0.85 + 0.25 * sin(a + 2.0);
    float pulseYellow = 0.85 + 0.25 * sin(a + 4.0);

    color += float3(1.00, 0.12, 0.03) * redCorner * 2.45 * pulseRed;
    color += float3(0.00, 0.95, 1.00) * cyanCorner * 2.25 * pulseCyan;
    color += float3(1.00, 0.90, 0.12) * yellowBase * 2.55 * pulseYellow;
    color += float3(1.00, 0.12, 0.58) * magentaTop * 1.35 * pulseRed;
    color += float3(0.08, 0.88, 1.00) * cyanTop * 1.30 * pulseCyan;

    float stressRibbon = exp(-pow((bend.y - 0.16 + 0.16 * sin(bend.x * 3.0 + a)) * 3.0, 2.0));
    color += spectrum * stressRibbon * 0.45;

    // Soft scanline modulation typical of polarized LCD viewing.
    float scan = sin(in.position.y * 1.8) * 0.5 + 0.5;
    color *= 1.08 + 0.08 * scan;
    color = pow(color, float3(0.88));

    color = clamp(color, 0.0, 1.0);
    return float4(color, 1.0);
}
"""

private struct MetalGlassFragmentUniforms {
  var resolution: SIMD2<Float>
  // swiftlint:disable identifier_name
  var body_center_px: SIMD2<Float>
  var body_half_px: SIMD2<Float>
  var time: Float
  var color_phase: Float
  // swiftlint:enable identifier_name
}

// swiftlint:disable:next type_body_length
final class GlassLayer: CAMetalLayer, Background {

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
    guard let other = layer as? GlassLayer else { return }

    // Only copy plain Swift state; presentation copies cannot touch Metal layer state safely.
    self.totalElapsedTime = other.totalElapsedTime
    self.colorPhase = other.colorPhase
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
      let library = try metalDevice.makeLibrary(source: metalGlassShaderSource, options: nil)
      guard let vertexFunction = library.makeFunction(name: "vertex_shader_glass"),
            let fragmentFunction = library.makeFunction(name: "fragment_shader_glass") else {
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
    colorPhase = (totalElapsedTime * 0.08).truncatingRemainder(dividingBy: 1.0)
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
      // Convert NSRect (origin bottom-left) to Metal pixel coords (origin top-left).
      let centerY = (bounds.height - body.midY) * cs
      bodyCenterPx = SIMD2<Float>(Float(centerX), Float(centerY))
      bodyHalfPx = SIMD2<Float>(
        Float((body.width * 0.5) * cs),
        Float((body.height * 0.5) * cs)
      )
    }

    var uniforms = MetalGlassFragmentUniforms(
      resolution: SIMD2<Float>(Float(texture.width), Float(texture.height)),
      body_center_px: bodyCenterPx,
      body_half_px: bodyHalfPx,
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
      length: MemoryLayout<MetalGlassFragmentUniforms>.stride,
      index: 0
    )
    renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

    renderEncoder.endEncoding()
    commandBuffer.present(drawable)
    commandBuffer.commit()
  }
}
// swiftlint:enable file_length
