import Cocoa
import QuartzCore
import Foundation
import MetalKit

// Portions ported from SahilK-027/0x7444ff organic-pattern shaders.
//
// MIT License
//
// Copyright (c) 2024 SK027
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

private let metalPOGOShaderSource = """
using namespace metal;

// Ported from SahilK-027/0x7444ff organic-pattern shaders.
// Original project: MIT License, Copyright (c) 2024 SK027.
// Classic Perlin 3D Noise by Stefan Gustavson (https://github.com/stegu/webgl-noise).

struct VertexData {
    float2 position;
};

struct VertexOut {
    float4 position [[position]];
};

vertex VertexOut vertex_shader_pogo(
    const device VertexData* vertex_array [[buffer(0)]],
    unsigned int vid [[vertex_id]]) {
    VertexOut out;
    out.position = float4(vertex_array[vid].position, 0.0, 1.0);
    return out;
}

struct POGOUniforms {
    float2 resolution;
    float time;
};

float4 pogo_mod289(float4 x) {
    return x - floor(x / 289.0) * 289.0;
}

float3 pogo_mod289(float3 x) {
    return x - floor(x / 289.0) * 289.0;
}

float4 pogo_permute(float4 x) {
    return pogo_mod289(((x * 34.0) + 1.0) * x);
}

float4 pogo_taylor_inv_sqrt(float4 r) {
    return 1.79284291400159 - 0.85373472095314 * r;
}

float3 pogo_fade(float3 t) {
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

float pogo_cnoise(float3 point) {
    float3 pi0 = floor(point);
    float3 pi1 = pi0 + float3(1.0);
    pi0 = pogo_mod289(pi0);
    pi1 = pogo_mod289(pi1);
    float3 pf0 = fract(point);
    float3 pf1 = pf0 - float3(1.0);
    float4 ix = float4(pi0.x, pi1.x, pi0.x, pi1.x);
    float4 iy = float4(pi0.y, pi0.y, pi1.y, pi1.y);
    float4 iz0 = float4(pi0.z);
    float4 iz1 = float4(pi1.z);

    float4 ixy = pogo_permute(pogo_permute(ix) + iy);
    float4 ixy0 = pogo_permute(ixy + iz0);
    float4 ixy1 = pogo_permute(ixy + iz1);

    float4 gx0 = ixy0 / 7.0;
    float4 gy0 = fract(floor(gx0) / 7.0) - 0.5;
    gx0 = fract(gx0);
    float4 gz0 = float4(0.5) - abs(gx0) - abs(gy0);
    float4 sz0 = step(gz0, float4(0.0));
    gx0 -= sz0 * (step(float4(0.0), gx0) - 0.5);
    gy0 -= sz0 * (step(float4(0.0), gy0) - 0.5);

    float4 gx1 = ixy1 / 7.0;
    float4 gy1 = fract(floor(gx1) / 7.0) - 0.5;
    gx1 = fract(gx1);
    float4 gz1 = float4(0.5) - abs(gx1) - abs(gy1);
    float4 sz1 = step(gz1, float4(0.0));
    gx1 -= sz1 * (step(float4(0.0), gx1) - 0.5);
    gy1 -= sz1 * (step(float4(0.0), gy1) - 0.5);

    float3 g000 = float3(gx0.x, gy0.x, gz0.x);
    float3 g100 = float3(gx0.y, gy0.y, gz0.y);
    float3 g010 = float3(gx0.z, gy0.z, gz0.z);
    float3 g110 = float3(gx0.w, gy0.w, gz0.w);
    float3 g001 = float3(gx1.x, gy1.x, gz1.x);
    float3 g101 = float3(gx1.y, gy1.y, gz1.y);
    float3 g011 = float3(gx1.z, gy1.z, gz1.z);
    float3 g111 = float3(gx1.w, gy1.w, gz1.w);

    float4 norm0 = pogo_taylor_inv_sqrt(float4(
        dot(g000, g000), dot(g010, g010), dot(g100, g100), dot(g110, g110)
    ));
    g000 *= norm0.x;
    g010 *= norm0.y;
    g100 *= norm0.z;
    g110 *= norm0.w;

    float4 norm1 = pogo_taylor_inv_sqrt(float4(
        dot(g001, g001), dot(g011, g011), dot(g101, g101), dot(g111, g111)
    ));
    g001 *= norm1.x;
    g011 *= norm1.y;
    g101 *= norm1.z;
    g111 *= norm1.w;

    float n000 = dot(g000, pf0);
    float n100 = dot(g100, float3(pf1.x, pf0.y, pf0.z));
    float n010 = dot(g010, float3(pf0.x, pf1.y, pf0.z));
    float n110 = dot(g110, float3(pf1.x, pf1.y, pf0.z));
    float n001 = dot(g001, float3(pf0.x, pf0.y, pf1.z));
    float n101 = dot(g101, float3(pf1.x, pf0.y, pf1.z));
    float n011 = dot(g011, float3(pf0.x, pf1.y, pf1.z));
    float n111 = dot(g111, pf1);

    float3 fade_xyz = pogo_fade(pf0);
    float4 n_z = mix(
        float4(n000, n100, n010, n110),
        float4(n001, n101, n011, n111),
        fade_xyz.z
    );
    float2 n_yz = mix(n_z.xy, n_z.zw, fade_xyz.y);
    float n_xyz = mix(n_yz.x, n_yz.y, fade_xyz.x);
    return 2.2 * n_xyz;
}

float pogo_pattern(float2 uv, float time) {
    float pattern = sin(0.01);
    pattern -= abs(pogo_cnoise(float3(uv * 5.0, time * 0.2)) * 0.15);
    return pattern;
}

float pogo_antialiased_pattern(float2 uv, float time, float2 sampleOffset) {
    return (
        pogo_pattern(uv + sampleOffset * float2(-1.0, -1.0), time) +
        pogo_pattern(uv + sampleOffset * float2( 1.0, -1.0), time) +
        pogo_pattern(uv + sampleOffset * float2(-1.0,  1.0), time) +
        pogo_pattern(uv + sampleOffset * float2( 1.0,  1.0), time)
    ) * 0.25;
}

fragment float4 fragment_shader_pogo(
    VertexOut in [[stage_in]],
    constant POGOUniforms &uniforms [[buffer(0)]]) {

    float2 uv = in.position.xy / uniforms.resolution;
    float aspect = uniforms.resolution.x / max(uniforms.resolution.y, 1.0);
    uv.x *= aspect;

    float zoom = 4.8 + sin(uniforms.time * 0.12) * 0.45;
    float2 center = float2(aspect * 0.5, 0.5);
    uv = (uv - center) * zoom + center;

    float pixel = 1.0 / max(uniforms.resolution.y, 1.0);
    float2 sampleOffset = float2(pixel * 0.35 * zoom);
    float2 chromaDirection = normalize((uv - center) + float2(0.0001));
    float2 chromaOffset = chromaDirection * pixel * zoom * 2.2;

    float patternR = pogo_antialiased_pattern(uv + chromaOffset, uniforms.time, sampleOffset);
    float patternG = pogo_antialiased_pattern(uv, uniforms.time, sampleOffset);
    float patternB = pogo_antialiased_pattern(uv - chromaOffset, uniforms.time, sampleOffset);

    float3 color1 = float3(1.0, 0.0, 0.35);
    float3 color2 = float3(0.01, 0.0, 0.0);

    float3 mixStrength = float3(patternR, patternG, patternB) * 2.0 + 0.25;
    float3 mixColor = mix(color2, color1, mixStrength);

    float3 edgeWidth = max(fwidth(mixStrength), float3(0.0025));
    float3 highlight = smoothstep(float3(0.24) - edgeWidth, float3(0.24) + edgeWidth, mixStrength);
    mixColor += highlight;

    return float4(pow(clamp(mixColor, 0.0, 1.0), float3(1.0 / 2.2)), 1.0);
}
"""

private struct MetalPOGOFragmentUniforms {
  var resolution: SIMD2<Float>
  var time: Float
}

final class POGOLayer: CAMetalLayer, Background {

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
    guard let other = layer as? POGOLayer else { return }
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
      let library = try metalDevice.makeLibrary(source: metalPOGOShaderSource, options: nil)
      guard let vertexFunction = library.makeFunction(name: "vertex_shader_pogo"),
            let fragmentFunction = library.makeFunction(name: "fragment_shader_pogo") else {
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

  // MARK: - Drawing
  override func display() {
    guard let pipelineState = pipelineState,
          let commandQueue = commandQueue,
          let vertexBuffer = vertexBuffer,
          let drawable = nextDrawable() else { return }
    let texture = drawable.texture

    var uniforms = MetalPOGOFragmentUniforms(
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
    if let fruit = currentFruit, let leaf = currentLeaf {
      let body = fruit.bounds(including: leaf)
      let fruitBounds = CGRect(x: body.minX - 4, y: body.minY - 4,
                               width: body.width + 8, height: body.height + 8)
      let scale = contentsScale
      let x = max(0, Int(fruitBounds.minX * scale))
      let y = max(0, Int((bounds.height - fruitBounds.maxY) * scale))
      let width = min(Int(fruitBounds.width * scale), texture.width - x)
      let height = min(Int(fruitBounds.height * scale), texture.height - y)
      if width > 0 && height > 0 {
        renderEncoder.setScissorRect(MTLScissorRect(x: x, y: y, width: width, height: height))
      }
    }
    renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
    renderEncoder.setFragmentBytes(
      &uniforms,
      length: MemoryLayout<MetalPOGOFragmentUniforms>.stride,
      index: 0
    )
    renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

    renderEncoder.endEncoding()
    commandBuffer.present(drawable)
    commandBuffer.commit()
  }
}
