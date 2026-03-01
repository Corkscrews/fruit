// swiftlint:disable file_length
import Cocoa
import QuartzCore
import Foundation
import MetalKit

private let metalOceanShaderSource = """
using namespace metal;

struct VertexData {
    float2 position;
};

struct VertexOut {
    float4 position [[position]];
};

vertex VertexOut vertex_shader_ocean(
    const device VertexData* vertex_array [[buffer(0)]],
    unsigned int vid [[vertex_id]]) {
    VertexOut out;
    out.position = float4(vertex_array[vid].position, 0.0, 1.0);
    return out;
}

struct OceanUniforms {
    float2 resolution;
    float time;
};

float ocean_hash(float2 p) {
    float3 p3 = fract(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

float ocean_noise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(
        mix(ocean_hash(i), ocean_hash(i + float2(1.0, 0.0)), u.x),
        mix(ocean_hash(i + float2(0.0, 1.0)), ocean_hash(i + float2(1.0, 1.0)), u.x),
        u.y
    );
}

float ocean_fbm(float2 p, int octaves) {
    float v = 0.0;
    float a = 0.5;
    float2x2 rot = float2x2(0.8, 0.6, -0.6, 0.8);
    for (int i = 0; i < octaves; i++) {
        v += a * ocean_noise(p);
        p = rot * p * 2.01;
        a *= 0.49;
    }
    return v;
}

float ocean_wave_height(float2 uv, float t) {
    // Slight horizontal wobble so wave fronts aren't ruler-straight
    float wobble = ocean_noise(float2(uv.x * 0.5, uv.y * 0.3) + t * 0.05) * 0.6;

    // Primary rolling wave fronts — horizontal lines moving top-to-bottom
    float waves = sin(uv.y * 1.8 + wobble + t * 0.35) * 0.38;
    waves += sin(uv.y * 3.2 + wobble * 0.7 + t * 0.28) * 0.18;

    // Gentle cross-variation so it's not perfectly uniform across X
    waves += sin(uv.x * 0.3 + uv.y * 2.4 + t * 0.22) * 0.08;

    // Surface texture — moderate chop riding on the wave fronts
    float chop = ocean_fbm(uv * 4.0 + float2(t * 0.15, t * 0.25), 5) * 0.15;

    // Fine detail
    float detail = ocean_fbm(uv * 9.0 + float2(t * 0.25, -t * 0.20), 4) * 0.06;

    return waves + chop + detail;
}

// Visible surface current swirls — sampled independently from the wave field
float ocean_current_pattern(float2 uv, float t) {
    float2 p1 = float2(
        ocean_fbm(uv * 1.8 + float2(t * 0.12, t * 0.08), 5),
        ocean_fbm(uv * 1.8 + float2(t * 0.09, -t * 0.11) + 7.3, 5)
    );
    float2 p2 = float2(
        ocean_fbm((uv + p1 * 1.2) * 1.6 + float2(t * 0.07, t * 0.05) + 3.1, 5),
        ocean_fbm((uv + p1 * 1.2) * 1.6 + float2(-t * 0.06, t * 0.08) + 11.7, 5)
    );
    return ocean_fbm(uv + p2 * 1.4, 5);
}

fragment float4 fragment_shader_ocean(
    VertexOut in [[stage_in]],
    constant OceanUniforms &uniforms [[buffer(0)]]) {

    float2 uv = (in.position.xy * 2.0 - uniforms.resolution) /
                 min(uniforms.resolution.x, uniforms.resolution.y);
    float t = uniforms.time;

    float2 oceanUV = uv * 2.0;

    float height = ocean_wave_height(oceanUV, t);

    // Finite-difference gradient for slope / foam detection
    float e = 0.015;
    float hx = ocean_wave_height(oceanUV + float2(e, 0.0), t);
    float hy = ocean_wave_height(oceanUV + float2(0.0, e), t);
    float slope = length(float2(hx - height, hy - height) / e);

    // ---- Deep North Atlantic blue (Titanic-style) ----
    float3 abyssColor  = float3(0.01,  0.02,  0.06);
    float3 deepColor   = float3(0.02,  0.04,  0.10);
    float3 troughColor = float3(0.03,  0.06,  0.14);
    float3 bodyColor   = float3(0.05,  0.09,  0.20);
    float3 faceColor   = float3(0.07,  0.13,  0.27);
    float3 crestColor  = float3(0.10,  0.18,  0.34);
    float3 foamColor   = float3(0.50,  0.54,  0.58);
    float3 sprayColor  = float3(0.65,  0.68,  0.72);

    // Height-based colour mapping
    float h = smoothstep(-0.6, 0.8, height);
    float3 color = mix(abyssColor,  deepColor,   smoothstep(0.00, 0.15, h));
    color = mix(color, troughColor, smoothstep(0.15, 0.30, h));
    color = mix(color, bodyColor,   smoothstep(0.30, 0.50, h));
    color = mix(color, faceColor,   smoothstep(0.50, 0.70, h));
    color = mix(color, crestColor,  smoothstep(0.70, 0.90, h));

    // Subsurface glow in mid-wave translucency
    float subsurface = smoothstep(0.3, 0.7, h) * (1.0 - smoothstep(0.7, 1.0, h));
    color += float3(0.005, 0.008, 0.020) * subsurface;

    // Visible surface current swirls — lighter/darker eddies flowing across the water
    float current = ocean_current_pattern(oceanUV, t);
    float currentShift = (current - 0.5) * 0.12;
    color += color * currentShift;

    // Foam on steep wave crests
    float foamMask = smoothstep(0.6, 1.0, height * 0.7 + slope * 0.25);
    float foamDetail = ocean_fbm(oceanUV * 18.0 + float2(t * 0.35, t * 0.2), 5);
    foamMask *= smoothstep(0.25, 0.7, foamDetail);
    color = mix(color, foamColor, foamMask * 0.55);

    // Wind-blown spray tearing off the highest crests
    float spray = smoothstep(0.85, 1.0, height * 0.6 + slope * 0.4);
    spray *= ocean_fbm(oceanUV * 30.0 + float2(t * 0.8, t * 0.1), 4);
    spray = smoothstep(0.4, 0.9, spray);
    color = mix(color, sprayColor, spray * 0.35);

    // Specular glint from an overcast sky
    float spec = pow(clamp(slope * 0.4, 0.0, 1.0), 4.0) * 0.10;
    color += float3(0.06, 0.08, 0.12) * spec;

    // Deepen the troughs
    float troughDark = 1.0 - smoothstep(-0.4, 0.1, height);
    color *= 1.0 - troughDark * 0.3;

    // Vignette
    float vignette = 1.0 - smoothstep(0.8, 2.0, length(uv));
    color *= mix(0.35, 1.0, vignette);

    return float4(color, 1.0);
}
"""

private struct MetalOceanFragmentUniforms {
  var resolution: SIMD2<Float>
  var time: Float
}

final class OceanLayer: CAMetalLayer, Background {

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
    guard let other = layer as? OceanLayer else { return }
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
      let library = try metalDevice.makeLibrary(source: metalOceanShaderSource, options: nil)
      guard let vertexFunction = library.makeFunction(name: "vertex_shader_ocean"),
            let fragmentFunction = library.makeFunction(name: "fragment_shader_ocean") else {
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

    var uniforms = MetalOceanFragmentUniforms(
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
      length: MemoryLayout<MetalOceanFragmentUniforms>.stride,
      index: 0
    )
    renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

    renderEncoder.endEncoding()
    commandBuffer.present(drawable)
    commandBuffer.commit()
  }
}
// swiftlint:enable file_length
