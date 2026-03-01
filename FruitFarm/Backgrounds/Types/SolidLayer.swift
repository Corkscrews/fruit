import Cocoa
import QuartzCore
import Foundation
import MetalKit

private let metalSolidColorShaderSource = """
using namespace metal;

struct VertexData {
    float2 position; // Clip space coordinates (-1 to 1)
};

struct VertexOut {
    float4 position [[position]];
};

vertex VertexOut vertex_shader_solid_color(
    const device VertexData* vertex_array [[buffer(0)]],
    unsigned int vid [[vertex_id]]) {

    VertexOut out;
    out.position = float4(vertex_array[vid].position, 0.0, 1.0);
    return out;
}

struct SolidColorFragmentUniforms {
    float4 color; // Current solid color (R,G,B,A)
};

fragment float4 fragment_shader_solid_color(
    VertexOut in [[stage_in]],
    constant SolidColorFragmentUniforms &uniforms [[buffer(0)]]) {

    return uniforms.color;
}
"""

private struct MetalSolidColorFragmentUniforms {
  var color: SIMD4<Float>
}

final class MetalSolidLayer: CAMetalLayer, Background {

  // MARK: - Color Configuration (adapted from SolidLayer)
  private static let colorArray: [NSColor] = [
    NSColor(srgbRed: 67/255, green: 156/255, blue: 214/255, alpha: 1), // BLUE
    NSColor(srgbRed: 139/255, green: 69/255, blue: 147/255, alpha: 1), // PURPLE
    NSColor(srgbRed: 207/255, green: 72/255, blue: 69/255, alpha: 1), // RED
    NSColor(srgbRed: 231/255, green: 135/255, blue: 59/255, alpha: 1), // ORANGE
    NSColor(srgbRed: 243/255, green: 185/255, blue: 75/255, alpha: 1), // YELLOW
    NSColor(srgbRed: 120/255, green: 184/255, blue: 86/255, alpha: 1)  // GREEN
  ]

  // MARK: - Metal Objects
  private var metalDevice: MTLDevice?
  private var commandQueue: MTLCommandQueue?
  private var pipelineState: MTLRenderPipelineState?
  private var vertexBuffer: MTLBuffer?
  // No need for color array buffers like in gradient layers, just a uniform.

  // MARK: - Animation Properties (from SolidLayer)
  private var colorIndex: Int = 0
  private var elapsedTime: CGFloat = 0
  private let secondsPerColor: CGFloat = 10.0 // Matching SolidLayer's duration
  private var lastUpdateTime: CGFloat = 0
  private let minUpdateInterval: CGFloat = 1.0 / 30.0 // Throttle to 30 FPS max

  deinit {
    // Release Metal resources
    vertexBuffer = nil
    pipelineState = nil
    commandQueue = nil
    metalDevice = nil
  }

  // MARK: - Initialization
  init(frame: CGRect, fruit: Fruit, contentsScale: CGFloat) { // Frame is CGRect for CALayer
    super.init()

    self.frame = frame
    self.contentsScale = contentsScale
    self.pixelFormat = .bgra8Unorm
    self.isOpaque = true
    self.framebufferOnly = true // Typically true for layers that don't need to be read back

    setupMetal()
    setupPipeline()
    createVertexBuffers()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override init(layer: Any) {
    super.init(layer: layer)
    guard let other = layer as? MetalSolidLayer else { return }
    self.colorIndex = other.colorIndex
    self.elapsedTime = other.elapsedTime
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
      let library = try metalDevice.makeLibrary(source: metalSolidColorShaderSource, options: nil)
      guard let vertexFunction = library.makeFunction(name: "vertex_shader_solid_color"),
            let fragmentFunction = library.makeFunction(name: "fragment_shader_solid_color") else {
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
    elapsedTime += deltaTime
    lastUpdateTime += deltaTime

    var needsRedraw = false

    while elapsedTime >= secondsPerColor {
      elapsedTime -= secondsPerColor
      colorIndex = (colorIndex + 1) % MetalSolidLayer.colorArray.count
      needsRedraw = true
    }

    // Throttle display updates to reduce CPU usage
    // Only redraw if enough time has passed OR color changed
    if needsRedraw || lastUpdateTime >= minUpdateInterval {
      lastUpdateTime = 0
      setNeedsDisplay() // Triggers display()
    }
  }

  // MARK: - Drawing
  override func display() {
    guard let pipelineState = pipelineState,
          let commandQueue = commandQueue,
          let vertexBuffer = vertexBuffer,
          let drawable = nextDrawable() else { return }
    let texture = drawable.texture

    let currentColor = interpolatedMetalColor()
    var uniforms = MetalSolidColorFragmentUniforms(color: currentColor)

    let renderPassDescriptor = MTLRenderPassDescriptor()
    renderPassDescriptor.colorAttachments[0].texture = texture
    renderPassDescriptor.colorAttachments[0].loadAction = .clear
    renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

    guard let commandBuffer = commandQueue.makeCommandBuffer(),
          let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
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
    renderEncoder.setFragmentBytes(&uniforms, length: MemoryLayout<MetalSolidColorFragmentUniforms>.stride, index: 0)

    renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

    renderEncoder.endEncoding()
    commandBuffer.present(drawable)
    commandBuffer.commit()
  }

  // Adapted from SolidLayer's interpolatedColor to produce SIMD4<Float>
  private func interpolatedMetalColor() -> SIMD4<Float> {
    let fromIndex = colorIndex
    let toIndex = (colorIndex + 1) % MetalSolidLayer.colorArray.count

    // Ensure colors are valid and converted to deviceRGB for component access
    guard let fromColorNS = MetalSolidLayer.colorArray[fromIndex].usingColorSpace(.deviceRGB),
          let toColorNS = MetalSolidLayer.colorArray[toIndex].usingColorSpace(.deviceRGB) else {
      // Fallback to the 'from' color if conversion fails
      let fallbackColor = MetalSolidLayer.colorArray[fromIndex]
      return SIMD4<Float>(Float(fallbackColor.redComponent),
                          Float(fallbackColor.greenComponent),
                          Float(fallbackColor.blueComponent),
                          Float(fallbackColor.alphaComponent))
    }

    let colorTransitionProgress = min(elapsedTime / secondsPerColor, 1.0)

    let red = Float(fromColorNS.redComponent + (toColorNS.redComponent - fromColorNS.redComponent) * colorTransitionProgress)
    let green = Float(fromColorNS.greenComponent + (toColorNS.greenComponent - fromColorNS.greenComponent) * colorTransitionProgress)
    let blue = Float(fromColorNS.blueComponent + (toColorNS.blueComponent - fromColorNS.blueComponent) * colorTransitionProgress)
    let alpha = Float(fromColorNS.alphaComponent + (toColorNS.alphaComponent - fromColorNS.alphaComponent) * colorTransitionProgress)

    return SIMD4<Float>(min(max(red, 0), 1),    // Clamp final components
                        min(max(green, 0), 1),
                        min(max(blue, 0), 1),
                        min(max(alpha, 0), 1))
  }

}

// final class SolidLayer: CALayer, Background {
//  // MARK: - Constants
//  private static let colorArray: [NSColor] = [
//    NSColor(srgbRed: 67/255, green: 156/255, blue: 214/255, alpha: 1), // BLUE
//    NSColor(srgbRed: 139/255, green: 69/255, blue: 147/255, alpha: 1), // PURPLE
//    NSColor(srgbRed: 207/255, green: 72/255, blue: 69/255, alpha: 1), // RED
//    NSColor(srgbRed: 231/255, green: 135/255, blue: 59/255, alpha: 1), // ORANGE
//    NSColor(srgbRed: 243/255, green: 185/255, blue: 75/255, alpha: 1), // YELLOW
//    NSColor(srgbRed: 120/255, green: 184/255, blue: 86/255, alpha: 1)  // GREEN
//  ]

//  // MARK: - Properties
//  private var colorIndex: Int = 0
//  private var elapsedTime: CGFloat = 0
//  private let secondsPerColor: CGFloat = 10.0

//  // MARK: - Init
//  init(frame: NSRect, fruit: Fruit) {
//    super.init()
//    self.frame = frame
//    self.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
//    //    config(fruit: fruit)
//  }

//  required init?(coder: NSCoder) {
//    fatalError("init(coder:) has not been implemented")
//  }

//  override init(layer: Any) {
//    super.init(layer: layer)
//    self.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
//  }

//  func update(frame: NSRect, fruit: Fruit) {
//    self.frame = frame
//    setNeedsDisplay()
//  }

//  func config(fruit: Fruit) {
//    // No-op for solid square
//    setNeedsDisplay()
//  }

//  func update(deltaTime: CGFloat) {
//    elapsedTime += deltaTime
//    if elapsedTime >= secondsPerColor {
//      elapsedTime = 0
//      colorIndex = (colorIndex + 1) % Self.colorArray.count
//    }
//    setNeedsDisplay()
//  }

//  // MARK: - Drawing
//  override func draw(in ctx: CGContext) {
//    let rect = bounds
//    ctx.setFillColor(interpolatedColor().cgColor)
//    ctx.fill(rect)
//  }

//  private func interpolatedColor() -> NSColor {
//    let fromIndex = colorIndex
//    let toIndex = (colorIndex + 1) % Self.colorArray.count
//    guard let fromColor = Self.colorArray[fromIndex].usingColorSpace(.deviceRGB),
//          let toColor = Self.colorArray[toIndex].usingColorSpace(.deviceRGB) else {
//      return Self.colorArray[fromIndex]
//    }
//    let colorTransitionProgress = min(elapsedTime / secondsPerColor, 1.0)
//    let red = fromColor.redComponent + (toColor.redComponent - fromColor.redComponent) * colorTransitionProgress
//    let green = fromColor.greenComponent + (toColor.greenComponent - fromColor.greenComponent) * colorTransitionProgress
//    let blue = fromColor.blueComponent + (toColor.blueComponent - fromColor.blueComponent) * colorTransitionProgress
//    let alpha = fromColor.alphaComponent + (toColor.alphaComponent - fromColor.alphaComponent) * colorTransitionProgress
//    return NSColor(deviceRed: red, green: green, blue: blue, alpha: alpha)
//  }

// }
