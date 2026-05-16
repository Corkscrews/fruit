// swiftlint:disable file_length
import Cocoa
import QuartzCore
import Foundation
import MetalKit

private let metalGlueShaderSource = """
using namespace metal;

struct VertexData {
    float2 position;
};

struct VertexOut {
    float4 position [[position]];
};

vertex VertexOut vertex_shader_glue(
    const device VertexData* vertex_array [[buffer(0)]],
    unsigned int vid [[vertex_id]]) {
    VertexOut out;
    out.position = float4(vertex_array[vid].position, 0.0, 1.0);
    return out;
}

struct GlueUniforms {
    float2 resolution;
    float2 body_center_px;
    float2 body_half_px;
    float time;
};

float glue_hash(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453123);
}

float2 glue_hash2(float2 p) {
    return fract(sin(float2(
        dot(p, float2(269.5, 183.3)),
        dot(p, float2(113.5, 271.9))
    )) * 43758.5453);
}

float glue_noise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);

    float a = glue_hash(i);
    float b = glue_hash(i + float2(1.0, 0.0));
    float c = glue_hash(i + float2(0.0, 1.0));
    float d = glue_hash(i + float2(1.0, 1.0));

    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float glue_fbm(float2 p) {
    float v = 0.0;
    float amp = 0.5;

    for (int i = 0; i < 4; i++) {
        v += glue_noise(p) * amp;
        p = float2(p.x * 1.7 + p.y * 0.3, p.y * 1.8 - p.x * 0.2) + 11.7;
        amp *= 0.5;
    }

    return v;
}

float3 glue_cycle_color(float cycleSeed) {
    return 0.5 + 0.5 * cos(
        6.2831853 * (cycleSeed + float3(0.00, 0.33, 0.67))
    );
}

float3 glue_reactor_palette(float heat, float seed, float cycleSeed) {
    float3 idle = float3(0.006, 0.018, 0.011);
    float3 reactorColor = glue_cycle_color(cycleSeed);
    float3 hotColor = mix(reactorColor, float3(1.0, 0.88, 0.18), 0.45);
    float3 white = float3(1.00, 0.96, 0.74);

    float3 color = mix(idle, reactorColor, smoothstep(0.02, 0.48, heat));
    color = mix(color, hotColor, smoothstep(0.38, 0.78, heat));
    color = mix(color, white, smoothstep(0.74, 1.0, heat));
    color *= 0.86 + seed * 0.28;
    return color;
}

float glue_ignition_delay(float2 cell, float hotspot) {
    float seed = glue_hash(cell);
    float neighborSeed = glue_noise(cell * 0.018);
    return mix(0.06, 0.86, seed) - neighborSeed * 0.12 - hotspot;
}

float glue_cell_preheat(float2 cell, float igniteProgress, float fadeProgress, float hotspot) {
    float ignitionDelay = glue_ignition_delay(cell, hotspot);
    float preheatIn = smoothstep(ignitionDelay - 0.22, ignitionDelay + 0.02, igniteProgress);
    float preheatOut = smoothstep(ignitionDelay - 0.22, ignitionDelay + 0.02, fadeProgress);
    return preheatIn * (1.0 - preheatOut) * 0.32;
}

float glue_cell_heat(
    float2 cell,
    float igniteProgress,
    float fadeProgress,
    float fullSaturation,
    float hotspot,
    float cycle,
    float time) {

    float ignitionDelay = glue_ignition_delay(cell, hotspot);
    float litIn = smoothstep(ignitionDelay - 0.018, ignitionDelay + 0.030, igniteProgress);
    float litOut = smoothstep(ignitionDelay - 0.018, ignitionDelay + 0.030, fadeProgress);
    float lit = max(litIn, fullSaturation) * (1.0 - litOut);
    float preheat = glue_cell_preheat(cell, igniteProgress, fadeProgress, hotspot);
    float flicker = glue_hash(cell + float2(floor(time * 18.0))) * 0.24;
    float surge = smoothstep(0.32, 0.50, cycle) * (1.0 - smoothstep(0.58, 0.82, cycle)) * flicker;
    return clamp(max(lit, preheat) + surge * lit, 0.0, 1.0);
}

float2 glue_neighbor_direction(float2 cell) {
    float pick = glue_hash(cell + 37.1);
    if (pick < 0.25) {
        return float2(1.0, 0.0);
    }
    if (pick < 0.50) {
        return float2(-1.0, 0.0);
    }
    if (pick < 0.75) {
        return float2(0.0, 1.0);
    }
    return float2(0.0, -1.0);
}

float glue_capsule(float2 p, float2 a, float2 b, float radius) {
    float2 ba = b - a;
    float h = clamp(dot(p - a, ba) / max(dot(ba, ba), 0.0001), 0.0, 1.0);
    return 1.0 - smoothstep(radius, radius + 0.54, length(p - (a + ba * h)));
}

fragment float4 fragment_shader_glue(
    VertexOut in [[stage_in]],
    constant GlueUniforms &uniforms [[buffer(0)]]) {

    float2 half_px = max(uniforms.body_half_px, float2(1.0));
    float2 lp = (in.position.xy - uniforms.body_center_px) / half_px;
    float loopTime = uniforms.time / 50.0;
    float cycle = fract(loopTime);
    float cycleSeed = glue_hash(float2(floor(loopTime), 17.3));
    float loopFade = smoothstep(0.00, 0.08, cycle) * (1.0 - smoothstep(0.92, 1.0, cycle));
    float2 component = lp * float2(1.0, half_px.y / max(half_px.x, 1.0));

    float cellSizePx = 4.0;
    float2 gridUv = in.position.xy / cellSizePx;
    float2 cell = floor(gridUv);

    float hotspotA = 1.0 - smoothstep(0.0, 1.15, length(component - float2(-0.42, -0.22)));
    float hotspotB = 1.0 - smoothstep(0.0, 1.22, length(component - float2(0.48, 0.26)));
    float hotspot = max(hotspotA, hotspotB) * 0.16;
    float seed = glue_hash(cell);

    float igniteProgress = pow(clamp(cycle / 0.44, 0.0, 1.0), 2.65);
    float fadeProgress = pow(clamp((cycle - 0.56) / 0.44, 0.0, 1.0), 2.65);
    float fullSaturation = 0.75 * smoothstep(0.40, 0.48, cycle) * (1.0 - smoothstep(0.56, 0.64, cycle));
    float preheat = glue_cell_preheat(cell, igniteProgress, fadeProgress, hotspot);
    float heat = glue_cell_heat(cell, igniteProgress, fadeProgress, fullSaturation, hotspot, cycle, uniforms.time);

    float shape = 0.0;
    float shapeHeat = 0.0;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            float2 offset = float2(float(x), float(y));
            float2 sourceCell = cell + offset;
            float sourceHeat = glue_cell_heat(sourceCell, igniteProgress, fadeProgress, fullSaturation, hotspot, cycle, uniforms.time);
            float2 direction = glue_neighbor_direction(sourceCell);
            float neighborHeat = glue_cell_heat(
                sourceCell + direction,
                igniteProgress,
                fadeProgress,
                fullSaturation,
                hotspot,
                cycle,
                uniforms.time
            );
            float merge = smoothstep(0.10, 0.72, min(sourceHeat, neighborHeat));
            float2 sourceLocalPx = (gridUv - sourceCell) * cellSizePx;
            float2 centerPx = float2(cellSizePx * 0.5);
            float circleDistance = length(sourceLocalPx - centerPx);
            float circle = 1.0 - smoothstep(1.42, 1.95, circleDistance);
            float bridge = glue_capsule(
                sourceLocalPx,
                centerPx,
                centerPx + direction * cellSizePx,
                mix(0.16, 1.24, merge)
            ) * merge;
            float sourceShape = max(circle, bridge);
            shape = max(shape, sourceShape);
            shapeHeat = max(shapeHeat, sourceHeat * sourceShape);
        }
    }
    float pixelCore = shape;
    heat = max(heat, shapeHeat);
    float3 color = glue_reactor_palette(heat, seed, cycleSeed) * pixelCore;

    float3 background = float3(0.0);
    color += background;

    float bloom = heat * smoothstep(0.78, 1.0, heat) * 0.36;
    color += glue_cycle_color(cycleSeed) * bloom * pixelCore;
    color += float3(glue_fbm(in.position.xy * 0.45 + uniforms.time * 0.4) * 0.018);

    float vignette = smoothstep(1.55, 0.20, length(lp * float2(0.82, 0.94)));
    color *= 0.72 + 0.28 * vignette;
    color *= 0.75;
    color *= loopFade;
    color = pow(clamp(color, 0.0, 1.0), float3(0.86));
    return float4(color, 1.0);
}
"""

private struct MetalGlueFragmentUniforms {
  var resolution: SIMD2<Float>
  // swiftlint:disable identifier_name
  var body_center_px: SIMD2<Float>
  var body_half_px: SIMD2<Float>
  var time: Float
  // swiftlint:enable identifier_name
}

// swiftlint:disable:next type_body_length
final class GlueLayer: CAMetalLayer, Background {

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
    guard let other = layer as? GlueLayer else { return }

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
      let library = try metalDevice.makeLibrary(source: metalGlueShaderSource, options: nil)
      guard let vertexFunction = library.makeFunction(name: "vertex_shader_glue"),
            let fragmentFunction = library.makeFunction(name: "fragment_shader_glue") else {
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

    var uniforms = MetalGlueFragmentUniforms(
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
      length: MemoryLayout<MetalGlueFragmentUniforms>.stride,
      index: 0
    )
    renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

    renderEncoder.endEncoding()
    commandBuffer.present(drawable)
    commandBuffer.commit()
  }
}
// swiftlint:enable file_length
