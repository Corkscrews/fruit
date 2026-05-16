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

constant int OCEAN_NUM_STEPS = 32;
constant int OCEAN_ITER_GEOMETRY = 3;
constant int OCEAN_ITER_FRAGMENT = 5;
constant float OCEAN_EPSILON = 0.001;
constant float OCEAN_HEIGHT = 0.6;
constant float OCEAN_CHOPPY = 4.0;
constant float OCEAN_SPEED = 0.8;
constant float OCEAN_FREQ = 0.16;
constant float OCEAN_CONTRAST = 1.22;
constant float OCEAN_CAMERA_TIME_SCALE = 0.08;
constant float OCEAN_BUBBLE_STRENGTH = 0.38;
constant float3 OCEAN_BASE = float3(0.0, 0.09, 0.18);
constant float3 OCEAN_WATER_COLOR = float3(0.48, 0.54, 0.36);

float3x3 ocean_from_euler(float3 ang) {
    float2 a1 = float2(sin(ang.x), cos(ang.x));
    float2 a2 = float2(sin(ang.y), cos(ang.y));
    float2 a3 = float2(sin(ang.z), cos(ang.z));

    return float3x3(
        float3(a1.y * a3.y + a1.x * a2.x * a3.x,
               a1.y * a2.x * a3.x + a3.y * a1.x,
              -a2.y * a3.x),
        float3(-a2.y * a1.x,
                a1.y * a2.y,
                a2.x),
        float3(a3.y * a1.x * a2.x + a1.y * a3.x,
               a1.x * a3.x - a1.y * a3.y * a2.x,
               a2.y * a3.y)
    );
}

float ocean_hash(float2 p) {
    float h = dot(p, float2(127.1, 311.7));
    return fract(sin(h) * 43758.5453123);
}

float ocean_noise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);

    float v = mix(
        mix(ocean_hash(i + float2(0.0, 0.0)), ocean_hash(i + float2(1.0, 0.0)), u.x),
        mix(ocean_hash(i + float2(0.0, 1.0)), ocean_hash(i + float2(1.0, 1.0)), u.x),
        u.y
    );
    return -1.0 + 2.0 * v;
}

float ocean_diffuse(float3 n, float3 l, float p) {
    return pow(dot(n, l) * 0.4 + 0.6, p);
}

float ocean_specular(float3 n, float3 l, float3 eye, float s) {
    float nrm = (s + 8.0) / (3.14159265 * 8.0);
    return pow(max(dot(reflect(eye, n), l), 0.0), s) * nrm;
}

float3 ocean_sky_color(float3 eye) {
    eye.y = max(eye.y, 0.0);
    float horizon = 1.0 - eye.y;
    return float3(
        pow(horizon, 2.0),
        horizon,
        0.6 + horizon * 0.4
    );
}

float ocean_octave(float2 uv, float choppy) {
    uv += float2(ocean_noise(uv));
    float2 wave = float2(1.0) - abs(sin(uv));
    float2 swell = abs(cos(uv));
    wave = mix(wave, swell, wave);
    return pow(1.0 - pow(wave.x * wave.y, 0.65), choppy);
}

float2 ocean_rotate_octave(float2 uv) {
    return float2x2(
        float2(1.6, 1.2),
        float2(-1.2, 1.6)
    ) * uv;
}

float ocean_map_with_iterations(float3 p, int iterations, float seaTime) {
    float freq = OCEAN_FREQ;
    float amp = OCEAN_HEIGHT;
    float choppy = OCEAN_CHOPPY;
    float height = 0.0;
    float2 uv = p.xz;
    uv.x *= 0.75;

    for (int i = 0; i < iterations; i++) {
        float wave = ocean_octave((uv + seaTime) * freq, choppy);
        wave += ocean_octave((uv - seaTime) * freq, choppy);
        height += wave * amp;
        uv = ocean_rotate_octave(uv);
        freq *= 1.9;
        amp *= 0.22;
        choppy = mix(choppy, 1.0, 0.2);
    }

    return p.y - height;
}

float ocean_map(float3 p, float time) {
    float seaTime = 1.0 + time * OCEAN_SPEED;
    return ocean_map_with_iterations(p, OCEAN_ITER_GEOMETRY, seaTime);
}

float ocean_map_detailed(float3 p, float time) {
    float seaTime = 1.0 + time * OCEAN_SPEED;
    return ocean_map_with_iterations(p, OCEAN_ITER_FRAGMENT, seaTime);
}

float ocean_height_map_tracing(float3 origin, float3 direction, float time, thread float3 &p) {
    float nearDistance = 0.0;
    float farDistance = 1000.0;
    float farHeight = ocean_map(origin + direction * farDistance, time);

    if (farHeight > 0.0) {
        p = origin + direction * farDistance;
        return farDistance;
    }

    float nearHeight = ocean_map(origin + direction * nearDistance, time);
    float midDistance = 0.0;

    for (int i = 0; i < OCEAN_NUM_STEPS; i++) {
        midDistance = mix(nearDistance, farDistance, nearHeight / (nearHeight - farHeight));
        p = origin + direction * midDistance;
        float midHeight = ocean_map(p, time);

        if (fabs(midHeight) < OCEAN_EPSILON) {
            break;
        }

        if (midHeight < 0.0) {
            farDistance = midDistance;
            farHeight = midHeight;
        } else {
            nearDistance = midDistance;
            nearHeight = midHeight;
        }
    }

    return midDistance;
}

float3 ocean_normal(float3 p, float eps, float time) {
    float height = ocean_map_detailed(p, time);
    float3 n = float3(
        ocean_map_detailed(p + float3(eps, 0.0, 0.0), time) - height,
        eps,
        ocean_map_detailed(p + float3(0.0, 0.0, eps), time) - height
    );
    return normalize(n);
}

float ocean_bubble_cells(float2 uv) {
    float2 cell = floor(uv);
    float2 local = fract(uv);
    float randomValue = ocean_hash(cell);
    float2 center = float2(
        ocean_hash(cell + float2(13.1, 7.7)),
        ocean_hash(cell + float2(3.4, 19.9))
    );
    float radius = mix(0.08, 0.22, randomValue);
    float bubble = 1.0 - smoothstep(radius, radius + 0.025, distance(local, center));
    return bubble * smoothstep(0.58, 1.0, randomValue);
}

float ocean_breaking_bubbles(float3 p, float3 n, float3 dist, float time) {
    float crest = smoothstep(0.24, 0.95, p.y);
    float steepness = smoothstep(0.08, 0.34, 1.0 - n.y);
    float distanceFade = max(1.0 - dot(dist, dist) * 0.0015, 0.0);
    float2 flow = p.xz + float2(time * 0.28, -time * 0.12);

    float fineBubbles = ocean_bubble_cells(flow * 26.0);
    float clusteredBubbles = ocean_bubble_cells(flow * 13.0 + 4.7);
    float streaks = smoothstep(0.42, 0.78, ocean_noise(flow * 8.0));

    return clamp((fineBubbles * 0.72 + clusteredBubbles * 0.38) * streaks *
                 crest * steepness * distanceFade, 0.0, 1.0);
}

float3 ocean_sea_color(float3 p, float3 n, float3 l, float3 eye, float3 dist, float time) {
    float fresnel = clamp(1.0 - dot(n, -eye), 0.0, 1.0);
    fresnel = min(pow(fresnel, 3.0), 0.5);

    float3 reflected = ocean_sky_color(reflect(eye, n));
    float3 refracted = OCEAN_BASE + OCEAN_WATER_COLOR * ocean_diffuse(n, l, 80.0) * 0.12;
    float3 color = mix(refracted, reflected, float3(fresnel));

    float atten = max(1.0 - dot(dist, dist) * 0.001, 0.0);
    color += OCEAN_WATER_COLOR * (p.y - OCEAN_HEIGHT) * 0.18 * atten;
    color += float3(ocean_specular(n, l, eye, 60.0));

    float bubbles = ocean_breaking_bubbles(p, n, dist, time);
    color = mix(color, float3(0.82, 0.90, 0.95), bubbles * OCEAN_BUBBLE_STRENGTH);

    return color;
}

float3 ocean_pixel(float2 fragCoord, float2 resolution, float waveTime, float cameraTime) {
    float2 uv = fragCoord / resolution * 2.0 - 1.0;
    uv.x *= resolution.x / resolution.y;

    float3 origin = float3(0.0, 3.5, cameraTime * 5.0);
    float3 direction = normalize(float3(uv, -2.0));
    direction.z += length(uv) * 0.14;
    direction = normalize(direction);

    float3 angle = float3(
        sin(cameraTime * 3.0) * 0.1,
        sin(cameraTime) * 0.035 + 0.3,
        cameraTime * 0.05
    );
    direction = normalize(transpose(ocean_from_euler(angle)) * direction);

    float3 p;
    ocean_height_map_tracing(origin, direction, waveTime, p);
    float3 dist = p - origin;
    float eps = max(dot(dist, dist) * (0.1 / resolution.x), 0.001);
    float3 normal = ocean_normal(p, eps, waveTime);
    float3 light = normalize(float3(0.0, 1.0, 0.8));

    float3 sky = ocean_sky_color(direction);
    float3 sea = ocean_sea_color(p, normal, light, direction, dist, waveTime);
    float horizonMask = pow(smoothstep(0.0, -0.02, direction.y), 0.2);

    float3 color = mix(sky, sea, float3(horizonMask));
    color = pow(max(color, float3(0.0)), float3(0.65));
    return clamp((color - 0.5) * OCEAN_CONTRAST + 0.5, float3(0.0), float3(1.0));
}

fragment float4 fragment_shader_ocean(
    VertexOut in [[stage_in]],
    constant OceanUniforms &uniforms [[buffer(0)]]) {

    float2 fragCoord = float2(in.position.x, uniforms.resolution.y - in.position.y);
    float3 color = ocean_pixel(
        fragCoord,
        uniforms.resolution,
        uniforms.time,
        uniforms.time * OCEAN_CAMERA_TIME_SCALE
    );
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
