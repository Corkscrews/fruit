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
    float4 anim;        // (a, sin a, cos a, grain seed); a is the 30 s loop phase
    float2 lp_scale;    // lp = position * lp_scale + lp_offset
    float2 lp_offset;
    float2 uv_scale;    // logo uv = position * uv_scale + uv_offset
    float2 uv_offset;
    float2 lp_to_uv;    // d(uv)/d(lp)
    float2 blobs[7];    // this frame's blob centres
};

float metallic_hash(float2 p) {
    return fract(sin(dot(p, float2(41.0, 289.0))) * 45758.5453);
}

// Smooth gallium-like heightfield over the skewed coords p: equal soft blobs + gentle folds.
// Returns (height, d/dlp.x, d/dlp.y): the analytic gradient lets the normal's four
// taps extrapolate one evaluation instead of running this four times.
float3 metallic_gallium(float2 p, constant MetallicUniforms &u) {
    float sa = u.anim.y, ca = u.anim.z;
    float cwx, swx = sincos(p.y * 1.8 + sa * 1.1, cwx);
    float cwy, swy = sincos(p.x * 2.2 + ca * 0.9, cwy);
    float2 q = p + float2(0.30 * swx, 0.22 * cwy);

    // exp(-k d²) as exp2, k = 3.6
    float v = 0.0;
    float2 gq = float2(0.0); // dv/dq, before the -2k factor
    #pragma unroll
    for (int i = 0; i < 7; i++) {
        float2 d = q - u.blobs[i];
        float b = exp2(-3.6 * 1.44269504 * dot(d, d));
        v += b;
        gq += b * d;
    }
    gq *= -2.0 * 3.6;

    float c1, s1 = sincos(q.x * 2.2 + q.y * 1.5 + sa * 1.4, c1);
    float c2, s2 = sincos(q.x * 1.6 - q.y * 2.8 + ca * 1.2, c2);
    v += 0.15 * s1 + 0.10 * c2;
    gq += 0.15 * c1 * float2(2.2, 1.5) - 0.10 * s2 * float2(1.6, -2.8);

    // Chain rule back through the q warp, then the p skew
    float2 gp = float2(gq.x - gq.y * (0.22 * 2.2) * swy, gq.y + gq.x * (0.30 * 1.8) * cwx);
    return float3(v, gp.x - 0.08 * gp.y, gp.y + 0.12 * gp.x);
}

// Studio environment seen in the mirror. Hard panel and horizon edges are what
// make the surface read as liquid metal; soft gradients alone read as satin.
half3 metallic_env(half3 r) {
    half up = -r.y; // screen y points down
    half3 c = mix(half3(0.015, 0.02, 0.035), half3(0.20, 0.23, 0.30), smoothstep(-0.9h, 0.9h, up));

    // Bright horizon glow with a hard lower edge
    c += half3(0.62, 0.68, 0.78) * smoothstep(0.10h, 0.13h, up) * smoothstep(0.75h, 0.13h, up);

    // Warm round key lamp (upper left): crisp disc, brighter core, faint halo
    half d = length(half2(r.x + 0.25h, up - 0.75h)) * 5.0h;
    half key = smoothstep(1.0h, 0.85h, d) * (0.82h + 0.18h * (1.0h - d)) + 0.12h * exp2(-d * d * half(0.8 * 1.44269504));
    c += half3(1.00, 0.96, 0.86) * (key * 0.95h);
    return c;
}

// Thin-film interference (soap bubble / oil slick): each wavelength reflects at its own
// phase, set by film thickness `d` (nm) and the refracted angle inside the film (n = 1.33).
half3 metallic_thin_film(float d, half cos_i) {
    half cos_t = sqrt(max(1.0h - (1.0h - cos_i * cos_i) * half(1.0 / (1.33 * 1.33)), 0.0h));
    // 4π n / λ for 650, 532, 450 nm; the phase reaches ~120 rad, so it stays float
    float3 phase = (d * float(cos_t)) * float3(16.7132729 / 650.0, 16.7132729 / 532.0, 16.7132729 / 450.0);
    return 0.5h + 0.5h * half3(cos(phase));
}

// Narkowicz ACES filmic fit: rolls highlights off instead of clipping them.
half3 metallic_aces(half3 x) {
    return saturate((x * (2.51h * x + 0.03h)) / (x * (2.43h * x + 0.59h) + 0.14h));
}

// `surface` is the logo slab baked once (R = height, G = face: 1 on the flat top, 0 off the logo).
half3 metallic_surface_color(float2 lp, float2 uv, constant MetallicUniforms &u, texture2d<float> surface) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float a = u.anim.x;
    float2 p = float2(lp.x + lp.y * 0.12, lp.y - lp.x * 0.08);
    float3 g = metallic_gallium(p, u);

    // The liquid keeps trying to set into the logo slab but never holds it: `form`
    // travels across the body, so one part is a crisp bevel while another slumps back.
    float cf1, sf1 = sincos(a + p.x * 1.7 + p.y * 0.9, cf1);
    float cf2, sf2 = sincos(a * 2.0 - p.y * 2.3 + p.x * 1.1, cf2);
    float t = saturate((0.55 + 0.32 * sf1 + 0.24 * sf2 - 0.20) * (1.0 / 0.60));
    float form = t * t * (3.0 - 2.0 * t);
    float2 dfp = (10.0 * t * (1.0 - t)) * (0.32 * cf1 * float2(1.7, 0.9) + 0.24 * cf2 * float2(1.1, -2.3));
    float2 dform = float2(dfp.x - 0.08 * dfp.y, dfp.y + 0.12 * dfp.x);

    // Unset liquid drags the outline around; its lp-gradient bends the taps to match.
    float cdy, sdy = sincos(p.y * 2.3 + a, cdy);
    float cdx, sdx = sincos(p.x * 2.1 - a, cdx);
    float m = 0.03 * (1.0 - form);
    float2 uvc = uv + m * float2(sdy, cdx);
    float2 drag_x = -0.03 * sdy * dform + m * cdy * float2(-0.184, 2.3);
    float2 drag_y = -0.03 * cdx * dform - m * sdx * float2(2.1, 0.252);

    // Four normal taps, each extrapolated from the centre except the logo itself
    const float e = 0.010;
    float2 tx = e * float2(u.lp_to_uv.x + drag_x.x, drag_y.x);
    float2 ty = e * float2(drag_x.y, u.lp_to_uv.y + drag_y.y);
    float2 lr = surface.sample(s, uvc + tx).rg;
    float2 ll = surface.sample(s, uvc - tx).rg;
    float2 ld = surface.sample(s, uvc + ty).rg;
    float2 lu = surface.sample(s, uvc - ty).rg;
    float4 slab = float4(lr.x, ll.x, ld.x, lu.x);
    float4 face = float4(lr.y, ll.y, ld.y, lu.y);
    float4 liquid = g.x + e * float4(g.y, -g.y, g.z, -g.z);
    float4 f = saturate(form + e * float4(dform.x, -dform.x, dform.y, -dform.y));
    // Edge protection: where the slab has set, ripples only survive on the flat face, so the bevel stays crisp.
    float4 hgt = liquid * (1.0 - 0.75 * f) * mix(1.0, face, f) + 2.1 * f * slab;
    float3 n = normalize(float3(-(hgt.x - hgt.y) * 3.5, -(hgt.z - hgt.w) * 3.5, 0.28));

    // Pure mirror reflection, slightly brighter at grazing angles
    half3 hn = half3(n);
    half3 r = reflect(half3(0.0h, 0.0h, -1.0h), hn);
    half nz = saturate(hn.z);
    half fr = 1.0h - nz;
    half3 color = metallic_env(r) * (0.85h + 1.4h * fr * fr * fr);

    // Iridescent film on the metal. Its thickness rides the surface height (liquid plus the
    // inflated logo), so the colour bands follow the ripples and the outline.
    float h = dot(hgt, float4(0.25));
    half3 film = metallic_thin_film(720.0 + 70.0 * h, nz);
    // Only where the film gathers: the highest crests (h tops out near 3.3) and steep
    // edges. Elsewhere it stays plain gallium.
    half sheen = max(smoothstep(2.85h, 3.2h, half(h)), smoothstep(0.55h, 0.35h, nz));
    color *= mix(half3(1.0h), 0.3h + 1.4h * film, 0.55h * sheen);

    // One pin-sharp glint; L = normalize(-0.30, -0.55, 0.78)
    color += half3(1.00h, 0.99h, 0.94h) * half(pow(saturate(dot(n, float3(-0.29987, -0.54975, 0.77965))), 400.0));

    // Dark seams where the surface curves away sharply
    color *= 1.0h - 0.25h * smoothstep(0.20h, 0.05h, nz);

    return color;
}

fragment float4 fragment_shader_metallic(
    VertexOut in [[stage_in]],
    constant MetallicUniforms &uniforms [[buffer(0)]],
    texture2d<float> surface [[texture(0)]]) {

    // The layer is masked to the logo, so skip the corners of the box: the face is 0 outside the outline.
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 uv = in.position.xy * uniforms.uv_scale + uniforms.uv_offset;
    if (surface.sample(s, uv).g <= 0.0) { return float4(0.0, 0.0, 0.0, 1.0); }

    float2 lp = in.position.xy * uniforms.lp_scale + uniforms.lp_offset;
    half3 color = metallic_surface_color(lp, uv, uniforms, surface);

    // Fine film-grain noise (per-pixel, temporal)
    half grain = half(metallic_hash(floor(in.position.xy) + uniforms.anim.w)) - 0.5h;
    color += grain * 0.025h;

    color = metallic_aces(max(color, 0.0h) * 1.3h);
    // S-curve for contrast: deeper blacks, punchier highlights
    color = mix(color, color * color * (3.0h - 2.0h * color), 0.7h);
    return float4(float3(color), 1.0);
}
"""

/// Mirrors `MetallicUniforms`: everything that is constant across a frame is worked out here, once.
private struct MetalMetallicFragmentUniforms {
  var anim: SIMD4<Float>
  var lpScale: SIMD2<Float>
  var lpOffset: SIMD2<Float>
  var uvScale: SIMD2<Float>
  var uvOffset: SIMD2<Float>
  var lpToUV: SIMD2<Float>
  // swiftlint:disable:next large_tuple
  var blobs: (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>, SIMD2<Float>, SIMD2<Float>, SIMD2<Float>, SIMD2<Float>)
}

// swiftlint:disable:next type_body_length
final class MetallicLayer: CAMetalLayer, Background {

  // MARK: - Metal Objects
  private var metalDevice: MTLDevice?
  private var commandQueue: MTLCommandQueue?
  private var pipelineState: MTLRenderPipelineState?
  private var vertexBuffer: MTLBuffer?
  private var heightTexture: MTLTexture?
  /// Logo rect (points) the height texture was baked for; rebaked when it changes.
  private var bakedRect = CGRect.null
  private var isBaking = false

  // MARK: - Animation
  private var totalElapsedTime: CGFloat = 0
  private var lastUpdateTime: CGFloat = 0
  private let minUpdateInterval: CGFloat = 1.0 / 30.0
  private var metallicZoomFactor: CGFloat = 0.85

  var zoomFactor: CGFloat {
    get { metallicZoomFactor }
    set {
      metallicZoomFactor = max(0.001, newValue)
      setNeedsDisplay()
    }
  }

  deinit {
    heightTexture = nil
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
    guard let other = layer as? MetallicLayer else { return }

    // Presentation copies should only copy plain Swift state.
    self.totalElapsedTime = other.totalElapsedTime
    self.metallicZoomFactor = other.metallicZoomFactor
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

    if lastUpdateTime >= minUpdateInterval {
      lastUpdateTime = 0
      setNeedsDisplay()
    }
  }

  /// Bakes the same logo relief PuppyLayer and GlassLayer use, off the main thread.
  private func bakeLogoIfNeeded() {
    guard let fruit = currentFruit, let leaf = currentLeaf else { return }
    // The paths are re-transformed after layout, so check here rather than in update(frame:).
    let rect = fruit.bounds(including: leaf).insetBy(dx: -4, dy: -4)
    guard rect != bakedRect && !isBaking else { return }
    isBaking = true
    let device = metalDevice, scale = contentsScale
    let fruitPath = fruit.transformedPath.quartzPath, leafPath = leaf.transformedPath.quartzPath
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let baked = PuppyLayer.bakeHeightTexture(
        device: device, rect: rect, contentsScale: scale, fruitPath: fruitPath, leafPath: leafPath
      ).flatMap { MetallicLayer.bakeSlabTexture(from: $0) }
      DispatchQueue.main.async {
        guard let self = self else { return }
        self.heightTexture = baked
        self.bakedRect = rect
        self.isBaking = false
        self.setNeedsDisplay()  // re-checks the rect, in case it changed meanwhile
      }
    }
  }

  /// Folds the slab profile into the relief once, so the shader reads (height, face) per tap
  /// instead of rebuilding it from the bevel ramp, and fetches half the bytes.
  static func bakeSlabTexture(from relief: MTLTexture) -> MTLTexture? {
    let width = relief.width, height = relief.height
    var rgba = [Float](repeating: 0, count: width * height * 4)
    rgba.withUnsafeMutableBytes { bytes in
      relief.getBytes(
        bytes.baseAddress!, bytesPerRow: width * 4 * MemoryLayout<Float>.stride,
        from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0
      )
    }
    var slab = [Float](repeating: 0, count: width * height * 2)
    for index in 0..<(width * height) {
      // R = bevel ramp, G = crown, B = leafness
      let k = 1 - min(max(rgba[index * 4], 0), 1)
      let leafness = rgba[index * 4 + 2]
      slab[index * 2] = 0.55 * (1 - k * k * (k + (1 - k) * leafness)).squareRoot() + 0.45 * rgba[index * 4 + 1]
      slab[index * 2 + 1] = 1 - k
    }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .rg32Float, width: width, height: height, mipmapped: false
    )
    descriptor.usage = [.shaderRead]
    guard let texture = relief.device.makeTexture(descriptor: descriptor) else { return nil }
    slab.withUnsafeBytes { bytes in
      texture.replace(
        region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
        withBytes: bytes.baseAddress!, bytesPerRow: width * 2 * MemoryLayout<Float>.stride
      )
    }
    return texture
  }

  /// Hex layout: a ring of six at r = 0.78 plus the centre.
  private static let blobHomes: [SIMD2<Float>] = [
    [0.6755, 0.39], [0.0, 0.78], [-0.6755, 0.39], [-0.6755, -0.39], [0.0, -0.78], [0.6755, -0.39], [0.0, 0.0]
  ]

  // MARK: - Drawing
  override func display() {
    bakeLogoIfNeeded()
    // Nothing is drawn until the relief lands, like PuppyLayer.
    guard let pipelineState = pipelineState,
          let commandQueue = commandQueue,
          let vertexBuffer = vertexBuffer,
          let heightTexture = heightTexture,
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

    let lpPerPx = 1 / (pointwiseMax(bodyHalfPx, SIMD2<Float>(repeating: 1)) * Float(max(metallicZoomFactor, 0.001)))
    let logoOrigin = SIMD2<Float>(Float(bakedRect.minX * cs), Float((bounds.height - bakedRect.maxY) * cs))
    let logoSize = SIMD2<Float>(Float(bakedRect.width * cs), Float(bakedRect.height * cs))
    let a = Float((totalElapsedTime / 30).truncatingRemainder(dividingBy: 1) * 2 * .pi)
    // Each blob orbits its home along (cos(a + 2.1i), sin(2a + 1.3i))
    let blob = { (i: Int) -> SIMD2<Float> in
      Self.blobHomes[i] + 0.10 * SIMD2<Float>(cos(a + 2.1 * Float(i)), sin(2 * a + 1.3 * Float(i)))
    }
    var uniforms = MetalMetallicFragmentUniforms(
      anim: SIMD4<Float>(a, sin(a), cos(a), Float((totalElapsedTime * 37).truncatingRemainder(dividingBy: 1))),
      lpScale: lpPerPx,
      lpOffset: -bodyCenterPx * lpPerPx,
      uvScale: 1 / logoSize,
      uvOffset: -logoOrigin / logoSize,
      lpToUV: 1 / (lpPerPx * logoSize),
      blobs: (blob(0), blob(1), blob(2), blob(3), blob(4), blob(5), blob(6))
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
      length: MemoryLayout<MetalMetallicFragmentUniforms>.stride,
      index: 0
    )
    renderEncoder.setFragmentTexture(heightTexture, index: 0)
    renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

    renderEncoder.endEncoding()
    commandBuffer.present(drawable)
    commandBuffer.commit()
  }
}
// swiftlint:enable file_length
