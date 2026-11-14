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
    int count;
};

float3 glue_cycle_color(float cycleSeed) {
    return 0.5 + 0.5 * cos(
        6.2831853 * (cycleSeed + float3(0.00, 0.33, 0.67))
    );
}

float2 glue_hash2(float2 p) {
    return fract(sin(float2(
        dot(p, float2(269.5, 183.3)),
        dot(p, float2(113.5, 271.9))
    )) * 43758.5453);
}

// Decorative dust, not simulated: one jittered, drifting, twinkling dot per
// grid cell. Returns (coverage, brightness).
float2 glue_dust(float2 p, float cellSize, float time, float unit, float salt) {
    float2 uv = p / cellSize;
    float2 cell = floor(uv);
    float2 h = glue_hash2(cell + salt);
    if (h.x < 0.35) { return float2(0.0); }
    float2 h2 = glue_hash2(cell + salt + 7.1);
    // Centre 0.3...0.7 + 0.08 drift + radius <= 0.22 keeps the dot inside its cell.
    float2 centre = 0.3 + 0.4 * h2 + 0.08 * float2(
        sin(time * 0.35 + h.y * 6.2831853),
        cos(time * 0.27 + h2.x * 6.2831853)
    );
    float radius = mix(0.08, 0.22, h.y);
    float dist = length(uv - cell - centre);
    float px = (radius - dist) * cellSize * unit;
    float coverage = clamp(px + 0.5, 0.0, 1.0);
    float twinkle = 0.5 + 0.5 * sin(time * (0.6 + h2.y) + h.x * 40.0);
    float brightness = (0.25 + 0.75 * twinkle) * (0.7 + 0.3 * (1.0 - dist / radius));
    return float2(coverage, brightness);
}

// blobs[i] = (x, y, radius, unused) in units of the body's shorter half extent.
fragment float4 fragment_shader_glue(
    VertexOut in [[stage_in]],
    constant GlueUniforms &uniforms [[buffer(0)]],
    constant float4 *blobs [[buffer(1)]]) {

    float2 half_px = max(uniforms.body_half_px, float2(1.0));
    float unit = min(half_px.x, half_px.y);
    float2 p = (in.position.xy - uniforms.body_center_px) / unit;

    // 1/d^2 metaballs: coincident blobs sum to exactly one blob of the merged area.
    // The 2r..3r cutoff stops far-away tails summing into one sheet; it starts
    // past the merged edge (1.41r), so merges stay seamless.
    float field = 0.0;
    float2 grad = float2(0.0);
    for (int i = 0; i < uniforms.count; i++) {
        float2 d = p - blobs[i].xy;
        float r = blobs[i].z;
        float d2 = max(dot(d, d), 1e-6);
        if (d2 > 9.0 * r * r) { continue; }
        float w = r * r / d2 * (1.0 - smoothstep(2.0 * r, 3.0 * r, sqrt(d2)));
        field += w;
        grad -= 2.0 * w / d2 * d;
    }

    // Treat 1/sqrt(field) as d/r of a dome: exact hemisphere for a lone blob,
    // smoothly blended across merged ones. -grad points outward.
    float gn = min(rsqrt(max(field, 1e-6)), 1.0);
    float2 outward = normalize(-grad + float2(1e-7));
    float3 normal = float3(outward * gn, sqrt(1.0 - gn * gn));
    // Pixel y grows downward, so -y is up: light from the top-left.
    float3 light = normalize(float3(-0.45, -0.55, 0.70));
    float3 halfway = normalize(light + float3(0.0, 0.0, 1.0));
    float diffuse = max(dot(normal, light), 0.0);
    float specular = pow(max(dot(normal, halfway), 0.0), 60.0);

    // Clamp first: the field spikes at blob centres and would blow up fwidth.
    field = min(field, 4.0);
    // 1/sqrt(field) is d/r for a lone blob: linear in distance, so dividing by
    // its fwidth gives pixels inside the edge without spikes from nested blobs.
    // Capped at 2: as field -> 0 it shoots up and fwidth would fake half-inside edges.
    float g = min(rsqrt(max(field, 1e-4)), 2.0);
    float edgePx = (1.0 - g) / max(fwidth(g), 1e-4);
    float inside = clamp(edgePx + 0.5, 0.0, 1.0);
    float rim = 1.0 - smoothstep(1.5, 2.5, edgePx);
    float3 base = glue_cycle_color(uniforms.time / 90.0);
    float3 color = base * (0.65 + 0.35 * diffuse);
    color = mix(color, mix(base, float3(1.0), 0.45), rim);
    color += float3(0.85) * specular;

    // Two dust layers at different scales, drawn only behind the blobs.
    float2 dustA = glue_dust(p, 0.030, uniforms.time, unit, 0.0);
    float2 dustB = glue_dust(p, 0.017, uniforms.time * 1.3, unit, 91.7);
    float3 dustTint = mix(base, float3(1.0), 0.35);
    float3 dust = dustTint * (dustA.x * dustA.y * 0.75 + dustB.x * dustB.y * 0.45);
    return float4(mix(min(dust, 1.0), min(color, 1.0), inside), 1.0);
}
"""

private struct MetalGlueFragmentUniforms {
  var resolution: SIMD2<Float>
  // swiftlint:disable identifier_name
  var body_center_px: SIMD2<Float>
  var body_half_px: SIMD2<Float>
  var time: Float
  var count: Int32
  // swiftlint:enable identifier_name
}

/// Blobs drift together and merge; new small ones spawn into the gaps;
/// any that grow past `ejectRadius` get pushed out of the body.
/// Units: the body's shorter half extent is 1, origin at the body centre.
private struct GlueSimulation {
  struct Blob {
    var pos: SIMD2<Float>
    var vel = SIMD2<Float>.zero
    var radius: Float
    var growth: Float
    var ejecting = false
  }

  static let maxBlobs = 900
  static let spawnRadii: ClosedRange<Float> = 0.007...0.018
  static let spawnClearance: Float = 0.028
  static let spawnInterval: Float = 0.008
  static let ejectRadius: Float = 0.22
  static let reach: Float = 0.10
  static let pull: Float = 0.05
  static let wander: Float = 0.02
  static let damping: Float = 1.5
  static let ejectPush: Float = 0.35

  var blobs: [Blob] = []
  /// Body half extents in simulation units (shorter side is 1).
  var extent = SIMD2<Float>(1, 1)
  private var spawnTimer: Float = 0

  /// Radius as drawn: new blobs swell in instead of popping.
  static func drawnRadius(_ blob: Blob) -> Float {
    let g = blob.growth
    return blob.radius * g * g * (3 - 2 * g)
  }

  mutating func step(_ dt: Float) {
    guard dt > 0 else { return }
    if blobs.isEmpty {
      for _ in 0..<1200 { spawn(grown: true) }
    }
    spawnTimer += dt
    while spawnTimer >= Self.spawnInterval {
      spawnTimer -= Self.spawnInterval
      spawn(grown: false)
    }
    integrate(dt, accelerations())
    mergeAndEject()
  }

  private func accelerations() -> [SIMD2<Float>] {
    var acc = [SIMD2<Float>](repeating: .zero, count: blobs.count)
    for i in blobs.indices {
      for j in (i + 1)..<blobs.count {
        let a = blobs[i], b = blobs[j]
        let delta = b.pos - a.pos
        let dist = max(simd_length(delta), 1e-4)
        let dir = delta / dist
        let gap = dist - a.radius - b.radius
        if a.ejecting != b.ejecting {
          // The leaving blob shoves the others aside instead of absorbing them.
          if gap < 0 {
            let push = dir * (-gap) * 3
            if a.ejecting { acc[j] += push } else { acc[i] -= push }
          }
          continue
        }
        guard !a.ejecting, gap < Self.reach else { continue }
        let strength = Self.pull * (gap < 0 ? 3 : 1 - gap / Self.reach)
        let ma = a.radius * a.radius, mb = b.radius * b.radius
        acc[i] += dir * strength * mb / (ma + mb)
        acc[j] -= dir * strength * ma / (ma + mb)
      }
    }
    return acc
  }

  private mutating func integrate(_ dt: Float, _ acc: [SIMD2<Float>]) {
    let decay = exp(-Self.damping * dt)
    for i in blobs.indices {
      var b = blobs[i]
      var a = acc[i] + SIMD2(Float.random(in: -1...1), Float.random(in: -1...1)) * Self.wander
      if b.ejecting {
        let len = simd_length(b.pos)
        a += (len > 1e-3 ? b.pos / len : SIMD2(1, 0)) * Self.ejectPush
      } else {
        // Soft walls keep resident blobs inside the body.
        let over = abs(b.pos) + b.radius - extent
        a -= simd_sign(b.pos) * simd_max(over, .zero) * 2
      }
      b.vel = (b.vel + a * dt) * decay
      b.pos += b.vel * dt
      b.growth = min(1, b.growth + dt / 1.5)
      blobs[i] = b
    }
  }

  private mutating func mergeAndEject() {
    var i = 0
    while i < blobs.count {
      var j = i + 1
      while j < blobs.count {
        let a = blobs[i], b = blobs[j]
        let close = simd_length(a.pos - b.pos) < 0.25 * max(a.radius, b.radius)
        guard close, !a.ejecting, !b.ejecting else { j += 1; continue }
        // Merge by drawn area so a half-grown newcomer doesn't pop.
        let ra = Self.drawnRadius(a), rb = Self.drawnRadius(b)
        let ma = ra * ra, mb = rb * rb, m = max(ma + mb, 1e-8)
        blobs[i].pos = (a.pos * ma + b.pos * mb) / m
        blobs[i].vel = (a.vel * ma + b.vel * mb) / m
        blobs[i].radius = sqrt(ma + mb)
        blobs[i].growth = 1
        blobs.remove(at: j)
      }
      if blobs[i].radius > Self.ejectRadius { blobs[i].ejecting = true }
      i += 1
    }
    let limit = extent + 0.05
    blobs.removeAll { blob in
      blob.ejecting && (abs(blob.pos.x) - blob.radius > limit.x || abs(blob.pos.y) - blob.radius > limit.y)
    }
  }

  private mutating func spawn(grown: Bool) {
    guard blobs.count < Self.maxBlobs else { return }
    let span = extent - Self.spawnRadii.upperBound
    for _ in 0..<12 {
      let p = SIMD2(Float.random(in: -span.x...span.x), Float.random(in: -span.y...span.y))
      if blobs.allSatisfy({ simd_length($0.pos - p) - $0.radius > Self.spawnClearance }) {
        blobs.append(Blob(pos: p, radius: Float.random(in: Self.spawnRadii), growth: grown ? 1 : 0))
        return
      }
    }
  }
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
  private var simulation = GlueSimulation()

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
    self.simulation = other.simulation
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
  private weak var currentLeaf: Leaf?

  // MARK: - Background Protocol
  func update(frame: NSRect, fruit: Fruit, leaf: Leaf) {
    currentFruit = fruit
    currentLeaf = leaf
    setFrameAndDrawableSizeWithoutAnimation(frame)
    setNeedsDisplay()
  }

  func config(fruit: Fruit, leaf: Leaf) {
    currentFruit = fruit
    currentLeaf = leaf
    setNeedsDisplay()
  }

  func update(deltaTime: CGFloat) {
    totalElapsedTime += deltaTime
    lastUpdateTime += deltaTime
    // Cap the step so a stall (sleep, preview pause) doesn't fling blobs.
    simulation.step(Float(min(deltaTime, 0.1)))

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
    if let fruit = currentFruit, let leaf = currentLeaf {
      let body = fruit.bounds(including: leaf)
      let centerX = body.midX * cs
      let centerY = (bounds.height - body.midY) * cs
      bodyCenterPx = SIMD2<Float>(Float(centerX), Float(centerY))
      bodyHalfPx = SIMD2<Float>(
        Float((body.width * 0.5) * cs),
        Float((body.height * 0.5) * cs)
      )
    }

    let halfMin = max(min(bodyHalfPx.x, bodyHalfPx.y), 1)
    simulation.extent = bodyHalfPx / halfMin
    // Never empty: setFragmentBytes rejects a zero length.
    var blobData = [SIMD4<Float>(0, 0, 0, 0)]
    if !simulation.blobs.isEmpty {
      blobData = simulation.blobs.map {
        SIMD4<Float>($0.pos.x, $0.pos.y, GlueSimulation.drawnRadius($0), 0)
      }
    }

    var uniforms = MetalGlueFragmentUniforms(
      resolution: SIMD2<Float>(Float(texture.width), Float(texture.height)),
      body_center_px: bodyCenterPx,
      body_half_px: bodyHalfPx,
      time: Float(totalElapsedTime),
      count: Int32(simulation.blobs.count)
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
    if let fruit = currentFruit, let leaf = currentLeaf {
      let body = fruit.bounds(including: leaf)
      let fb = CGRect(x: body.minX - 4, y: body.minY - 4,
                       width: body.width + 8, height: body.height + 8)
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
    // A buffer, not setFragmentBytes: maxBlobs * 16 B is over its 4 KB limit.
    let blobBuffer = metalDevice?.makeBuffer(
      bytes: blobData,
      length: MemoryLayout<SIMD4<Float>>.stride * blobData.count,
      options: .storageModeShared
    )
    renderEncoder.setFragmentBuffer(blobBuffer, offset: 0, index: 1)
    renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

    renderEncoder.endEncoding()
    commandBuffer.present(drawable)
    commandBuffer.commit()
  }
}
