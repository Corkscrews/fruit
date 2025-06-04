// swiftlint:disable file_length
import Cocoa
import QuartzCore
import Foundation
import MetalKit

private let metalLinearGradientShaderSource = """
using namespace metal;

struct VertexData {
    float2 position; // Expected to be in clip space coordinates (-1 to 1)
};

struct VertexOut {
    float4 position [[position]];
    // Pass normalized y-coordinate for linear gradient calculation
    // The vertex shader will output clip space, fragment shader will receive pixel coords
    // For linear gradient, it's often easier to work with normalized screen coords.
    // Let's calculate normalized Y in fragment shader from in.position.y and resolution.
};

vertex VertexOut vertex_shader_linear_gradient(
    const device VertexData* vertex_array [[buffer(0)]],
    unsigned int vid [[vertex_id]]) {

    VertexOut out;
    // Pass through clip space position
    out.position = float4(vertex_array[vid].position, 0.0, 1.0);
    return out;
}

struct LinearFragmentUniforms {
    float2 resolution;          // Layer's pixel dimensions
    int num_color_stops;        // Number of color stops
};

// Using a fixed size matching colorArray.count, consistent with MetalCircularGradientLayer
constant int MAX_COLOR_STOPS_LINEAR = 6;

fragment float4 fragment_shader_linear_gradient(
    VertexOut in [[stage_in]], // in.position.xy are pixel coordinates
    constant LinearFragmentUniforms &uniforms [[buffer(0)]],
    constant float4 *colors [[buffer(1)]],      // Array of interpolated (R,G,B,A) colors
    constant float *locations [[buffer(2)]]) { // Array of color stop locations [0.0 ... 1.0]

    // For a top-to-bottom linear gradient, use the normalized y-coordinate.
    // Metal's fragment shader in.position.y origin is top-left for a CAMetalLayer.
    float t = in.position.y / uniforms.resolution.y;

    // Handle 'drawsBeforeStartLocation' (effectively the first color at the top)
    if (t <= locations[0]) {
        return colors[0];
    }

    // Handle 'drawsAfterEndLocation' (effectively the last color at the bottom)
    if (t >= locations[uniforms.num_color_stops - 1]) {
        return colors[uniforms.num_color_stops - 1];
    }

    // Interpolate between stops
    for (int i = 0; i < uniforms.num_color_stops - 1; ++i) {
        if (t >= locations[i] && t < locations[i+1]) {
            float t_local = (locations[i+1] - locations[i] < 0.00001) ? 0.0 :
                            (t - locations[i]) / (locations[i+1] - locations[i]);
            return mix(colors[i], colors[i+1], t_local);
        }
    }

    // Fallback, should be covered by edge cases above.
    return colors[uniforms.num_color_stops - 1];
}
"""

private struct MetalLinearGradientFragmentUniforms {
  var resolution: SIMD2<Float>
  // swiftlint:disable identifier_name
  var num_color_stops: Int32
  // swiftlint:enable identifier_name
}

final class MetalLinearGradientLayer: CAMetalLayer, Background {

  // MARK: - Helper Structs (from MetalCircularGradientLayer)
  private struct ColorComponents {
    let red, green, blue, alpha: CGFloat
  }
  private typealias GradientComponents = (
    start: [ColorComponents],
    end: [ColorComponents]
  )

  // MARK: - Color Configuration (adapted from LinearGradientLayer/MetalCircularGradientLayer)
  private let colorArray: [NSColor] = [
    NSColor(srgbRed: 67/255, green: 156/255, blue: 214/255, alpha: 1), // BLUE
    NSColor(srgbRed: 139/255, green: 69/255, blue: 147/255, alpha: 1), // PURPLE
    NSColor(srgbRed: 207/255, green: 72/255, blue: 69/255, alpha: 1), // RED
    NSColor(srgbRed: 231/255, green: 135/255, blue: 59/255, alpha: 1), // ORANGE
    NSColor(srgbRed: 243/255, green: 185/255, blue: 75/255, alpha: 1), // YELLOW
    NSColor(srgbRed: 120/255, green: 184/255, blue: 86/255, alpha: 1)  // GREEN
  ]

  private lazy var precomputedGradientComponents: [Int: GradientComponents] = {
    var precomputed: [Int: GradientComponents] = [:]
    precomputed.reserveCapacity(colorCombinations.count)
    for (key, (fromNSColors, toNSColors)) in colorCombinations {
      let build: (NSColor) -> ColorComponents = {
        ColorComponents(
          red: $0.redComponent,
          green: $0.greenComponent,
          blue: $0.blueComponent,
          alpha: $0.alphaComponent
        )
      }
      precomputed[key] = (start: fromNSColors.map(build), end: toNSColors.map(build))
    }
    return precomputed
  }()

  private lazy var colorCombinations: [Int: ([NSColor], [NSColor])] = {
    let colorCount = colorArray.count
    var combinations: [Int: ([NSColor], [NSColor])] = [:]
    combinations.reserveCapacity(colorCount)
    for startColorIndex in 0..<colorCount {
      var fromColors: [NSColor] = []
      fromColors.reserveCapacity(colorCount)
      var toColors: [NSColor] = []
      toColors.reserveCapacity(colorCount)
      for endColorIndex in 0..<colorCount {
        let fromIdx = (startColorIndex + endColorIndex) % colorCount
        let toIdx = (startColorIndex + endColorIndex + 1) % colorCount
        fromColors.append(colorArray[fromIdx])
        toColors.append(colorArray[toIdx])
      }
      combinations[startColorIndex] = (fromColors, toColors)
    }
    return combinations
  }()

  private lazy var gradientLocations: [Float] = { // For Metal, use Float
    (0..<colorArray.count).map {
      Float($0) / Float(colorArray.count - 1)
    }
  }()
  private var gradientLocationsBuffer: MTLBuffer!

  // MARK: - Metal Objects
  private var metalDevice: MTLDevice!
  private var commandQueue: MTLCommandQueue!
  private var pipelineState: MTLRenderPipelineState!
  private var vertexBuffer: MTLBuffer!
  private var currentInterpolatedColorsBuffer: MTLBuffer!

  // MARK: - Animation Properties
  private var colorIndex: Int = 0
  private var elapsedTime: CGFloat = 0
  // continuousTotalElapsedTimeForRotation is not needed for simple linear gradient
  private let secondsPerColor: CGFloat = 2.0

  deinit {
    // Release Metal resources
    vertexBuffer = nil
    pipelineState = nil
    commandQueue = nil
    currentInterpolatedColorsBuffer = nil
    gradientLocationsBuffer = nil
    metalDevice = nil
  }

  // MARK: - Initialization
  init(frame: CGRect, fruit: Fruit) { // Frame is CGRect for CALayer
    // currentFruitMaxDimension is not used for linear gradient
    super.init()

    self.frame = frame
    self.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
    self.pixelFormat = .bgra8Unorm
    self.isOpaque = true
    self.framebufferOnly = true

    setupMetal()
    setupPipeline()
    createVertexBuffers()
    createColorLocationBuffer()

    let initialColors = calculateCurrentInterpolatedColors()
    currentInterpolatedColorsBuffer = metalDevice.makeBuffer(
      bytes: initialColors,
      length: MemoryLayout<SIMD4<Float>>.stride * colorArray.count,
      options: .storageModeShared
    )
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override init(layer: Any) {
    super.init(layer: layer) // CALayer properties are copied. self.device (CAMetalLayer.device) is nil.

//    if let other = layer as? MetalLinearGradientLayer {
//      // 1. Establish the MTLDevice for this new layer.
//      let deviceToUseForNewLayer: MTLDevice
//      if let sourceStrongDeviceRef = other.metalDevice {
//        deviceToUseForNewLayer = sourceStrongDeviceRef
//      } else {
//        print("Warning: Source layer ('other') did not have metalDevice. Creating new MTLDevice for copied MetalLinearGradientLayer.")
//        guard let newDevice = MTLCreateSystemDefaultDevice() else {
//          fatalError("Metal is not supported on this device. Cannot create MTLDevice for copied layer.")
//        }
//        deviceToUseForNewLayer = newDevice
//      }
//
//      self.metalDevice = deviceToUseForNewLayer // Our strong reference
//      self.device = deviceToUseForNewLayer      // CAMetalLayer's weak reference
//
//      // 2. Copy CAMetalLayer specific properties (safe now that device is set)
//      self.pixelFormat = other.pixelFormat
//      self.framebufferOnly = other.framebufferOnly
//      self.isOpaque = other.isOpaque
//
//      // 3. Copy custom application-specific state
//      self.colorIndex = other.colorIndex
//      self.elapsedTime = other.elapsedTime
//      // secondsPerColor is a constant, no need to copy if it's always the same
//
//      // 4. Re-create Metal resources using self.metalDevice
//      guard let currentDeviceForResources = self.metalDevice else {
//        fatalError("self.metalDevice is unexpectedly nil before re-creating Metal resources in init(layer:Any) for MetalLinearGradientLayer.")
//      }
//      guard let cq = currentDeviceForResources.makeCommandQueue() else {
//        fatalError("Could not create Metal command queue for copied MetalLinearGradientLayer.")
//      }
//      self.commandQueue = cq
//      setupPipeline() // Uses self.metalDevice and self.pixelFormat
//      createVertexBuffers() // Uses self.metalDevice
//      createColorLocationBuffer() // Uses self.metalDevice
//
//      let currentColors = calculateCurrentInterpolatedColors()
//      if let colorBuffer = currentDeviceForResources.makeBuffer(bytes: currentColors, length: MemoryLayout<SIMD4<Float>>.stride * colorArray.count, options: .storageModeShared) {
//        self.currentInterpolatedColorsBuffer = colorBuffer
//      } else {
//        fatalError("Failed to create currentInterpolatedColorsBuffer for copied MetalLinearGradientLayer.")
//      }
//    } else {
//      print("Warning: init(layer: Any) called for MetalLinearGradientLayer with a layer that is not MetalLinearGradientLayer.")
//    }
  }

  private func setupMetal() {
    guard let device = MTLCreateSystemDefaultDevice() else {
      fatalError("Metal is not supported on this device for MetalLinearGradientLayer")
    }
    self.metalDevice = device
    self.device = device // Assign to CAMetalLayer's device property

    guard let commandQueue = device.makeCommandQueue() else {
      fatalError("Could not create Metal command queue for MetalLinearGradientLayer")
    }
    self.commandQueue = commandQueue
  }

  private func setupPipeline() {
    do {
      let library = try metalDevice.makeLibrary(
        source: metalLinearGradientShaderSource, options: nil
      )
      guard let vertexFunction = library.makeFunction(
        name: "vertex_shader_linear_gradient"
      ), let fragmentFunction = library.makeFunction(
        name: "fragment_shader_linear_gradient"
      ) else {
        fatalError("Could not find shader functions for MetalLinearGradientLayer")
      }

      let pipelineDescriptor = MTLRenderPipelineDescriptor()
      pipelineDescriptor.vertexFunction = vertexFunction
      pipelineDescriptor.fragmentFunction = fragmentFunction
      pipelineDescriptor.colorAttachments[0].pixelFormat = self.pixelFormat

      pipelineState = try metalDevice.makeRenderPipelineState(
        descriptor: pipelineDescriptor
      )
    } catch {
      fatalError(
        "Could not create Metal render pipeline state for " +
        "MetalLinearGradientLayer: \(error)"
      )
    }
  }

  private func createVertexBuffers() {
    let vertices: [SIMD2<Float>] = [
      SIMD2<Float>(-1.0, -1.0), SIMD2<Float>( 1.0, -1.0), SIMD2<Float>(-1.0, 1.0),
      SIMD2<Float>( 1.0, -1.0), SIMD2<Float>( 1.0, 1.0), SIMD2<Float>(-1.0, 1.0)
    ]
    vertexBuffer = metalDevice.makeBuffer(
      bytes: vertices,
      length: MemoryLayout<SIMD2<Float>>.stride * vertices.count,
      options: .storageModeShared
    )
  }

  private func createColorLocationBuffer() {
    gradientLocationsBuffer = metalDevice.makeBuffer(
      bytes: gradientLocations,
      length: MemoryLayout<Float>.stride * gradientLocations.count,
      options: .storageModeShared
    )
  }

  // MARK: - Background Protocol
  func update(frame: NSRect, fruit: Fruit) {
    self.frame = frame
    setNeedsDisplay()
  }

  func config(fruit: Fruit) {
    // Fruit parameter is not directly used by MetalLinearGradientLayer's appearance
    setNeedsDisplay()
  }

  func update(deltaTime: CGFloat) {
    elapsedTime += deltaTime
    while elapsedTime >= secondsPerColor {
      elapsedTime -= secondsPerColor
      colorIndex = (colorIndex + 1) % colorArray.count
    }
    setNeedsDisplay() // Triggers display()
  }

  // MARK: - Drawing
  override func display() {
    guard let drawable = nextDrawable() else { return }
    let texture = drawable.texture

    let currentColors = calculateCurrentInterpolatedColors()
    let bufferSize = MemoryLayout<SIMD4<Float>>.stride * currentColors.count
    if currentInterpolatedColorsBuffer.length != bufferSize {
      currentInterpolatedColorsBuffer = metalDevice.makeBuffer(
        bytes: currentColors,
        length: bufferSize,
        options: .storageModeShared
      )
    } else {
      currentInterpolatedColorsBuffer.contents().copyMemory(
        from: currentColors,
        byteCount: MemoryLayout<SIMD4<Float>>.stride * currentColors.count
      )
    }

    var uniforms = MetalLinearGradientFragmentUniforms(
      resolution: SIMD2<Float>(Float(texture.width), Float(texture.height)),
      num_color_stops: Int32(colorArray.count)
    )

    let renderPassDescriptor = MTLRenderPassDescriptor()
    renderPassDescriptor.colorAttachments[0].texture = texture
    renderPassDescriptor.colorAttachments[0].loadAction = .clear
    renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(
      red: 0,
      green: 0,
      blue: 0,
      alpha: 1
    )

    guard let commandBuffer = commandQueue.makeCommandBuffer(),
          let renderEncoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: renderPassDescriptor
          ) else {
      return
    }

    renderEncoder.setRenderPipelineState(pipelineState)
    renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)

    renderEncoder.setFragmentBytes(
      &uniforms,
      length: MemoryLayout<MetalLinearGradientFragmentUniforms>.stride,
      index: 0
    )
    renderEncoder.setFragmentBuffer(currentInterpolatedColorsBuffer, offset: 0, index: 1)
    renderEncoder.setFragmentBuffer(gradientLocationsBuffer, offset: 0, index: 2)

    renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

    renderEncoder.endEncoding()
    commandBuffer.present(drawable)
    commandBuffer.commit()
  }

  private func calculateCurrentInterpolatedColors() -> [SIMD4<Float>] {
    guard let (startComponentList, endComponentList) = precomputedGradientComponents[colorIndex],
          startComponentList.count == endComponentList.count else {
      return Array(repeating: SIMD4<Float>(0, 0, 0, 1), count: colorArray.count) // Fallback
    }

    let colorTransitionProgress = min(max(elapsedTime / secondsPerColor, 0.0), 1.0)
    let colorCount = startComponentList.count
    guard colorCount >= 2 else {
      return Array(repeating: SIMD4<Float>(0, 0, 0, 1), count: colorArray.count) // Fallback
    }

    var interpolatedShaderColors: [SIMD4<Float>] = []
    interpolatedShaderColors.reserveCapacity(colorCount)

    for index in 0..<colorCount {
      let fromComps = startComponentList[index]
      let toComps = endComponentList[index]

      let interpolate = { (fromColor: CGFloat, toColor: CGFloat) in
        Float(min(max(fromColor + (toColor - fromColor) * colorTransitionProgress, 0), 1))
      }

      let red = interpolate(fromComps.red, toComps.red)
      let green = interpolate(fromComps.green, toComps.green)
      let blue = interpolate(fromComps.blue, toComps.blue)
      let alpha = interpolate(fromComps.alpha, toComps.alpha)
      interpolatedShaderColors.append(SIMD4<Float>(red, green, blue, alpha))
    }
    return interpolatedShaderColors
  }
}

// // A layer that renders a linear gradient background with smooth color transitions.
// // The gradient flows vertically from top to bottom, creating a dynamic and engaging visual effect.
// final class LinearGradientLayer: CALayer, Background {
//  // MARK: - Color Configuration
//
//  /// The array of colors used in the gradient animation.
//  /// Colors are defined in sRGB color space for consistent color reproduction.
//  private let colorArray: [NSColor] = [
//    NSColor(srgbRed: 67/255, green: 156/255, blue: 214/255, alpha: 1), // BLUE
//    NSColor(srgbRed: 139/255, green: 69/255, blue: 147/255, alpha: 1), // PURPLE
//    NSColor(srgbRed: 207/255, green: 72/255, blue: 69/255, alpha: 1), // RED
//    NSColor(srgbRed: 231/255, green: 135/255, blue: 59/255, alpha: 1), // ORANGE
//    NSColor(srgbRed: 243/255, green: 185/255, blue: 75/255, alpha: 1), // YELLOW
//    NSColor(srgbRed: 120/255, green: 184/255, blue: 86/255, alpha: 1)  // GREEN
//  ]
//
//  /// Reusable array for CGColors to avoid allocation during drawing.
//  /// This array is cleared and reused on each draw call.
//  private var cgColors: [CGColor] = []
//
//  /// Cache for all possible color combinations used in the gradient.
//  /// The dictionary is keyed by the starting color index and contains tuples of
//  /// (fromColors, toColors) arrays for smooth transitions.
//  private lazy var colorCombinations: [Int: ([NSColor], [NSColor])] = {
//    let colorCount = colorArray.count
//    var combinations: [Int: ([NSColor], [NSColor])] = [:]
//    combinations.reserveCapacity(colorCount)
//
//    for startColorIndex in 0..<colorCount {
//      var fromColors: [NSColor] = []
//      fromColors.reserveCapacity(colorCount)
//      var toColors: [NSColor] = []
//      toColors.reserveCapacity(colorCount)
//
//      for endColorIndex in 0..<colorCount {
//        let fromIdx = (startColorIndex + endColorIndex) % colorCount
//        let toIdx = (startColorIndex + endColorIndex + 1) % colorCount
//        fromColors.append(colorArray[fromIdx])
//        toColors.append(colorArray[toIdx])
//      }
//
//      combinations[startColorIndex] = (fromColors, toColors)
//    }
//    return combinations
//  }()
//
//  // MARK: - Gradient Configuration
//
//  /// The color space used for gradient rendering.
//  /// Using device RGB color space for optimal performance.
//  private let gradientColorSpace = CGColorSpaceCreateDeviceRGB()
//
//  /// Pre-calculated gradient locations for consistent color distribution.
//  /// Locations are evenly spaced between 0 and 1.
//  private lazy var gradientLocations: [CGFloat] = (0..<colorArray.count).map {
//    CGFloat($0) / CGFloat(colorArray.count - 1)
//  }
//
//  // MARK: - Animation Properties
//
//  /// The current index in the color array.
//  private var colorIndex: Int = 0
//
//  /// Time elapsed since the last color transition.
//  private var elapsedTime: CGFloat = 0
//
//  /// Duration for each color transition in seconds.
//  private let secondsPerColor: CGFloat = 2.0
//
//  // MARK: - Initialization
//
//  /// Initializes a new linear gradient layer with the specified frame and fruit.
//  /// - Parameters:
//  ///   - frame: The frame rectangle for the layer.
//  ///   - fruit: The fruit object to determine the gradient's dimensions.
//  init(frame: NSRect, fruit: Fruit) {
//    super.init()
//    self.frame = frame
//    self.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
//  }
//
//  required init?(coder: NSCoder) {
//    fatalError("init(coder:) has not been implemented")
//  }
//
//  override init(layer: Any) {
//    super.init(layer: layer)
//    self.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
//  }
//
//  // MARK: - Public Methods
//
//  /// Updates the layer's frame.
//  /// - Parameters:
//  ///   - frame: The new frame rectangle.
//  ///   - fruit: The fruit object (unused in this implementation).
//  func update(frame: NSRect, fruit: Fruit) {
//    self.frame = frame
//    setNeedsDisplay()
//  }
//
//  /// Configures the layer with a new fruit object.
//  /// - Parameter fruit: The fruit object (unused in this implementation).
//  func config(fruit: Fruit) {
//    setNeedsDisplay()
//  }
//
//  /// Updates the animation state with the elapsed time since the last update.
//  /// - Parameter deltaTime: The time elapsed since the last update in seconds.
//  func update(deltaTime: CGFloat) {
//    elapsedTime += deltaTime
//    while elapsedTime >= secondsPerColor {
//      elapsedTime -= secondsPerColor
//      colorIndex = (colorIndex + 1) % colorArray.count
//    }
//    setNeedsDisplay()
//  }
//
//  // MARK: - Drawing
//
//  override func draw(in ctx: CGContext) {
//    let rect = bounds
//
//    // Get pre-calculated color combinations for the current index
//    guard let (fromColors, toColors) = colorCombinations[colorIndex] else { return }
//
//    // Calculate the current transition progress
//    let colorTransitionProgress = min(max(elapsedTime / secondsPerColor, 0.0), 1.0)
//    let colorCount = fromColors.count
//
//    // Ensure we have enough colors for a gradient
//    guard colorCount >= 2 else { return }
//
//    // Reuse the CGColors array
//    self.cgColors.removeAll(keepingCapacity: true)
//
//    // Interpolate colors based on the current transition progress
//    for index in 0..<colorCount {
//      let fromColor = fromColors[index]
//      let toColor = toColors[index]
//
//      // Clamp color components to [0,1] to avoid color glitches
//      let red = min(max(fromColor.redComponent + (toColor.redComponent - fromColor.redComponent) * colorTransitionProgress, 0), 1)
//      let green = min(max(fromColor.greenComponent + (toColor.greenComponent - fromColor.greenComponent) * colorTransitionProgress, 0), 1)
//      let blue = min(max(fromColor.blueComponent + (toColor.blueComponent - fromColor.blueComponent) * colorTransitionProgress, 0), 1)
//      let alpha = min(max(fromColor.alphaComponent + (toColor.alphaComponent - fromColor.alphaComponent) * colorTransitionProgress, 0), 1)
//
//      // Create CGColor directly from components
//      self.cgColors.append(CGColor(colorSpace: gradientColorSpace, components: [red, green, blue, alpha])!)
//    }
//
//    // Create and draw the gradient
//    if let gradient = CGGradient(
//      colorsSpace: gradientColorSpace,
//      colors: self.cgColors as CFArray,
//      locations: gradientLocations
//    ) {
//      // Draw the linear gradient from top to bottom
//      ctx.drawLinearGradient(
//        gradient,
//        start: CGPoint(x: rect.midX, y: rect.maxY),
//        end: CGPoint(x: rect.midX, y: rect.minY),
//        options: []
//      )
//    }
//  }
// }
// swiftlint:enable file_length
