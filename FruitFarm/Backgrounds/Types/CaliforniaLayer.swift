import Cocoa
import QuartzCore
import Foundation
import MetalKit

private let metalCaliforniaShaderSource = """
using namespace metal;

struct VertexData {
    float2 position;
};

struct VertexOut {
    float4 position [[position]];
};

vertex VertexOut vertex_shader_california(
    const device VertexData* vertex_array [[buffer(0)]],
    unsigned int vid [[vertex_id]]) {
    VertexOut out;
    out.position = float4(vertex_array[vid].position, 0.0, 1.0);
    return out;
}

struct CaliforniaUniforms {
    float2 resolution;
    float time;
};

float california_hash(float2 p) {
    float3 p3 = fract(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

float california_noise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(
        mix(california_hash(i), california_hash(i + float2(1.0, 0.0)), u.x),
        mix(california_hash(i + float2(0.0, 1.0)), california_hash(i + float2(1.0, 1.0)), u.x),
        u.y
    );
}

float california_fbm(float2 p) {
    float value = 0.0;
    float amplitude = 0.5;
    float2x2 turn = float2x2(0.86, 0.50, -0.50, 0.86);

    for (int i = 0; i < 5; i++) {
        value += amplitude * california_noise(p);
        p = turn * p * 2.03 + 7.1;
        amplitude *= 0.52;
    }

    return value;
}

// Sap pulse: a single coherent flow from leaf base (s=0) outward (s=1).
// Returns a soft bright bump that travels along a curvilinear coordinate.
float california_flow(float s, float speed, float phase, float time) {
    float head = fract(time * speed + phase);
    float d = s - head;
    d = d - floor(d + 0.5);
    return exp(-90.0 * d * d);
}

fragment float4 fragment_shader_california(
    VertexOut in [[stage_in]],
    constant CaliforniaUniforms &uniforms [[buffer(0)]]) {

    float2 uv = (in.position.xy * 2.0 - uniforms.resolution) /
                 min(uniforms.resolution.x, uniforms.resolution.y);
    // Zoom out: scale the sample space so the whole leaf network sits
    // inside the visible frame instead of filling it edge-to-edge.
    uv *= 1.75;
    float t = uniforms.time;

    // ---------------------------------------------------------------
    // Leaf body: low-frequency organic warp so the whole leaf breathes
    // as one piece. Every vein system below samples this same warp so
    // they all bend together instead of drifting independently.
    // ---------------------------------------------------------------
    float2 warp = float2(
        california_fbm(uv * 1.3 + float2(0.0, t * 0.05)) - 0.5,
        california_fbm(uv * 1.3 + float2(5.2, t * 0.05 + 3.1)) - 0.5
    ) * 0.18;
    float2 wuv = uv + warp;

    float leafNoise = california_fbm(wuv * 3.2 + float2(1.7, -2.4));
    float fineCells = california_fbm(wuv * 16.0 + leafNoise * 1.6);
    float3 leafDark  = float3(0.07, 0.21, 0.09);
    float3 leafMid   = float3(0.18, 0.38, 0.14);
    float3 leafLight = float3(0.40, 0.62, 0.22);
    float3 color = mix(leafDark, leafMid, smoothstep(0.10, 0.70, leafNoise));
    color = mix(color, leafLight, smoothstep(0.55, 0.95, leafNoise) * 0.6);
    color += (fineCells - 0.5) * float3(0.04, 0.06, 0.025);

    // ---------------------------------------------------------------
    // Midrib (central spine). Single curve traversing the full height.
    // x_mid(y) is the spine's horizontal position. We measure the
    // signed distance from the spine and the arc-length s along it.
    // ---------------------------------------------------------------
    float y = uv.y;
    float spineWobble = sin(y * 1.4 + t * 0.18) * 0.06
                      + sin(y * 3.1 - t * 0.11) * 0.025
                      + (california_fbm(float2(y * 1.1, t * 0.08)) - 0.5) * 0.05;
    float spineX = spineWobble + warp.x * 0.4;
    float dxSpine = uv.x - spineX;
    float distSpine = abs(dxSpine);
    // arc-length parameter along the spine, 0 at base (bottom) -> 1 at tip
    float sSpine = clamp((y + 1.0) * 0.5, 0.0, 1.0);

    // Spine tapers: thick at base, fine at tip — like a real midrib.
    float spineWidth = mix(0.024, 0.006, sSpine);
    float spine = 1.0 - smoothstep(spineWidth, spineWidth + 0.020, distSpine);
    float spineGlow = 1.0 - smoothstep(spineWidth + 0.010, spineWidth + 0.080, distSpine);

    // ---------------------------------------------------------------
    // Lateral veins. Indexed by y-cell along the spine, alternating
    // sides. Each lateral STARTS at the spine (u=0) and grows outward
    // (u=1). It curves forward (toward tip) as it extends so the leaf
    // reads as a pinnate venation pattern, not a ladder.
    // ---------------------------------------------------------------
    float vein = 0.0;
    float veinGlow = 0.0;
    float subVein = 0.0;
    float flow = 0.0;
    float flowCore = 0.0;

    const float lateralCount = 11.0;      // laterals visible per side, roughly
    float yBase = -1.85;
    float yTop  = 1.85;
    float ySpan = yTop - yBase;
    float cellH = ySpan / lateralCount;

    // Search nearby cells so adjacent laterals can overlap softly.
    float cellIndex = floor((y - yBase) / cellH);

    for (int k = -1; k <= 1; k++) {
        float id = cellIndex + float(k);
        // Anchor point on the spine where this lateral emerges.
        float yAnchor = yBase + (id + 0.5) * cellH;
        float seed = id * 2.137;
        // Alternate sides; small jitter so it doesn't look mechanical.
        float side = (fmod(id, 2.0) < 0.5) ? 1.0 : -1.0;
        side *= (sin(seed * 1.7) > -0.85) ? 1.0 : -1.0; // rare double-side

        // Anchor X tracks the spine exactly at yAnchor so the vein
        // physically touches the midrib.
        float anchorSpineWobble =
              sin(yAnchor * 1.4 + t * 0.18) * 0.06
            + sin(yAnchor * 3.1 - t * 0.11) * 0.025
            + (california_fbm(float2(yAnchor * 1.1, t * 0.08)) - 0.5) * 0.05;
        float2 anchor = float2(anchorSpineWobble + warp.x * 0.4, yAnchor);

        // Lateral reach + forward curl. The vein bends toward the tip
        // of the leaf as it extends, giving the classic pinnate look.
        float reach = 0.42 + 0.10 * sin(seed * 1.3);
        float curl  = 0.22 + 0.08 * sin(seed * 0.7);

        // Closed-form nearest-point along a quadratic Bezier is heavy;
        // instead sample a few points and take the minimum distance.
        // Six samples is plenty for a smooth feel.
        float bestDist = 1e9;
        float bestU = 0.0;
        for (int j = 0; j < 7; j++) {
            float u = float(j) / 6.0;
            // Quadratic curve: starts at anchor, ends at tip-curled point.
            float2 end = anchor + float2(side * reach, curl);
            float2 ctrl = anchor + float2(side * reach * 0.45, curl * 0.15);
            float2 p = mix(mix(anchor, ctrl, u), mix(ctrl, end, u), u);
            // Subtle organic wiggle along the lateral.
            p += float2(0.0, sin(u * 9.0 + seed) * 0.010);
            float d = distance(uv, p);
            if (d < bestDist) { bestDist = d; bestU = u; }
        }

        // Lateral tapers from spine outward.
        float lateralWidth = mix(0.014, 0.004, bestU);
        float lateral = 1.0 - smoothstep(lateralWidth, lateralWidth + 0.014, bestDist);
        float lateralOuter = 1.0 - smoothstep(lateralWidth + 0.008, lateralWidth + 0.055, bestDist);

        // Tertiary veins: short, fine hairs branching off the lateral.
        // They emerge perpendicular to the lateral's local tangent, so
        // they too remain physically attached to their parent.
        float subStripe = fract(bestU * 5.0 + seed * 0.3);
        float subActive = smoothstep(0.20, 0.30, bestU) *
                         (1.0 - smoothstep(0.80, 0.95, bestU)) *
                         smoothstep(0.30, 0.50, subStripe) *
                         (1.0 - smoothstep(0.55, 0.75, subStripe));
        float subDist = bestDist; // proximity to parent vein
        float sub = (1.0 - smoothstep(0.006, 0.022, subDist)) * subActive * 0.55;

        vein     = max(vein, lateral);
        veinGlow = max(veinGlow, lateralOuter);
        subVein  = max(subVein, sub);

        // Flow continues from the spine onto each lateral. The phase
        // is keyed to the lateral's anchor height so sap rises from
        // base to tip across the entire leaf as one wave, not as
        // isolated blinks.
        float lateralPhase = (yAnchor - yBase) / ySpan;     // 0..1 along leaf
        float fLateral = california_flow(bestU * 0.55 + lateralPhase,
                                         0.18, lateralPhase * 0.6, t);
        flow     = max(flow, fLateral * lateral);
        flowCore = max(flowCore, fLateral * (1.0 - smoothstep(0.002, lateralWidth, bestDist)));
    }

    // Spine flow: same global wave, evaluated along the spine.
    float fSpine = california_flow(sSpine, 0.18, 0.0, t);
    flow     = max(flow, fSpine * spine);
    flowCore = max(flowCore, fSpine * (1.0 - smoothstep(0.003, spineWidth, distSpine)));

    // Combine vein masks. Spine + laterals + tertiary all share a
    // single mask so they read as one network.
    float veinMask = max(spine, max(vein, subVein));
    float veinEdge = max(spineGlow, veinGlow);

    // Micro-texture along the veins (cell walls).
    float micro = california_fbm(wuv * 32.0 + float2(t * 0.15, -t * 0.10));
    veinMask *= 0.80 + micro * 0.22;
    veinEdge *= 0.75 + micro * 0.18;

    float3 veinColor = float3(0.030, 0.080, 0.030);
    float3 veinRim   = float3(0.52, 0.74, 0.26);
    color = mix(color, veinRim, veinEdge * 0.30);
    color = mix(color, veinColor, veinMask * 0.78);

    // Sap glow: warm chartreuse traveling through the connected system.
    float3 sap     = float3(0.78, 1.00, 0.20);
    float3 sapCore = float3(0.98, 1.00, 0.70);
    color += sap * flow * 0.70;
    color += sapCore * flowCore * 0.95;

    // Soft vignette so the leaf sits in space.
    float vignette = 1.0 - smoothstep(1.5, 3.2, length(uv));
    color *= mix(0.60, 1.0, vignette);

    return float4(clamp(color, 0.0, 1.0), 1.0);
}
"""

private struct MetalCaliforniaFragmentUniforms {
  var resolution: SIMD2<Float>
  var time: Float
}

final class CaliforniaLayer: CAMetalLayer, Background {

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
    guard let other = layer as? CaliforniaLayer else { return }
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
      let library = try metalDevice.makeLibrary(source: metalCaliforniaShaderSource, options: nil)
      guard let vertexFunction = library.makeFunction(name: "vertex_shader_california"),
            let fragmentFunction = library.makeFunction(name: "fragment_shader_california") else {
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

    var uniforms = MetalCaliforniaFragmentUniforms(
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
      length: MemoryLayout<MetalCaliforniaFragmentUniforms>.stride,
      index: 0
    )
    renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

    renderEncoder.endEncoding()
    commandBuffer.present(drawable)
    commandBuffer.commit()
  }
}
