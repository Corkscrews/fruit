// swiftlint:disable file_length type_body_length
import Cocoa
import QuartzCore
import Foundation
import MetalKit

private let metalShaderSource = """
using namespace metal;

struct VertexData {
    float2 position;
};

struct VertexOut {
    float4 position [[position]];
    // We will use position.xy (pixel coordinates) directly in the fragment shader
};

vertex VertexOut vertex_shader_circular_gradient(
    const device VertexData* vertex_array [[buffer(0)]],
    unsigned int vid [[vertex_id]]) {

    VertexOut out;
    out.position = float4(vertex_array[vid].position, 0.0, 1.0);
    return out;
}

struct FragmentUniforms {
    float2 resolution;          // Layer's pixel dimensions
    float2 gradient_center_px;  // Center of the gradient in pixels
    float gradient_radius_px;   // Radius of the gradient in pixels
    int num_color_stops;        // Number of color stops (e.g., 6)
};

// Metal needs to know the size for arrays in buffers if not dynamically sized.
// We'll use a fixed size matching our colorArray.count
constant int MAX_COLOR_STOPS = 6;

fragment float4 fragment_shader_circular_gradient(
    VertexOut in [[stage_in]],
    constant FragmentUniforms &uniforms [[buffer(0)]],
    constant float4 *colors [[buffer(1)]],      // Array of interpolated (R,G,B,A) colors
    constant float *locations [[buffer(2)]]) { // Array of color stop locations [0.0 ... 1.0]

    float dist_from_center = distance(in.position.xy, uniforms.gradient_center_px);
    float t = dist_from_center / uniforms.gradient_radius_px; // Normalized distance for gradient lookup

    // Handle 'drawsBeforeStartLocation'
    if (t <= locations[0]) {
        return colors[0];
    }

    // Handle 'drawsAfterEndLocation'
    if (t >= locations[uniforms.num_color_stops - 1]) {
        return colors[uniforms.num_color_stops - 1];
    }

    // Interpolate between stops
    for (int i = 0; i < uniforms.num_color_stops - 1; ++i) {
        if (t >= locations[i] && t < locations[i+1]) {
            // Ensure divisor is not zero if locations are identical (should not happen with current setup)
            float t_local = (locations[i+1] - locations[i] < 0.00001) ? 0.0 :
                            (t - locations[i]) / (locations[i+1] - locations[i]);
            return mix(colors[i], colors[i+1], t_local);
        }
    }

    // Fallback, though ideally, one of the above conditions should always be met.
    // This can happen if t is exactly locations[uniforms.num_color_stops - 1] and the loop finishes.
    // The check `t >= locations[uniforms.num_color_stops - 1]` should catch this.
    // To be safe, return the last color.
    return colors[uniforms.num_color_stops - 1];
}
"""

// Matching Swift struct for the fragment shader uniforms
private struct MetalCircularGradientFragmentUniforms {
  var resolution: SIMD2<Float>
  // swiftlint:disable identifier_name
  var gradient_center_px: SIMD2<Float>
  var gradient_radius_px: Float
  var num_color_stops: Int32
  // swiftlint:enable identifier_name
}

final class MetalCircularGradientLayer: CAMetalLayer, Background {

  // MARK: - Helper Structs (copied from CircularGradientLayer for color component data)
  private struct ColorComponents {
    let red, green, blue, alpha: CGFloat
  }
  private typealias GradientComponents = (
    start: [ColorComponents],
    end: [ColorComponents]
  )

  // MARK: - Color Configuration (copied and adapted)
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

  private lazy var colorCombinations: [Int: ([NSColor], [NSColor])] = { // Copied from CircularGradientLayer
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
  private var continuousTotalElapsedTimeForRotation: CGFloat = 0
  private var currentFruitMaxDimension: CGFloat = 50.0
  private let secondsPerColor: CGFloat = 2.0 // Duration for each color transition
  private var lastUpdateTime: CGFloat = 0
  private let minUpdateInterval: CGFloat = 1.0 / 30.0 // Throttle to 30 FPS max

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
    self.currentFruitMaxDimension = fruit.maxDimen()
    super.init()

    self.frame = frame
    self.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
    self.pixelFormat = .bgra8Unorm
    self.isOpaque = true // Assuming it's a background
    self.framebufferOnly = true // Performance optimization

    setupMetal()
    setupPipeline()
    createVertexBuffers()
    createColorLocationBuffer()

    // Initial color buffer setup
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

  // swiftlint:disable:next todo
  // TODO: Can't fix this, something is wrong with the invalidation of strong references.
  override init(layer: Any) {
    super.init(layer: layer)
//    if let other = layer as? MetalCircularGradientLayer {
//      // 1. Establish the MTLDevice for this new layer.
//
//      let determinedDevice: MTLDevice? // Use an optional to be explicit about nil possibility
//      if let sourceStrongDeviceRef = other.metalDevice {
//        print("DEBUG init(layer:Any): Using device from other.metalDevice: \(sourceStrongDeviceRef)")
//        determinedDevice = sourceStrongDeviceRef
//      } else {
//        print("DEBUG init(layer:Any): other.metalDevice is nil. Attempting to create a new system default device.")
//        guard let newDevice = MTLCreateSystemDefaultDevice() else {
//          // This fatalError should be hit if MTLCreateSystemDefaultDevice() returns nil.
//          // If the assert below (checking self.device) is hit, and this wasn't, it's very strange.
//          fatalError("Metal is not supported on this device or MTLCreateSystemDefaultDevice() failed. Cannot create MTLDevice for copied layer.")
//        }
//        print("DEBUG init(layer:Any): Created new system default device: \(newDevice)")
//        determinedDevice = newDevice
//      }
//
//      // At this point, determinedDevice should ideally be a valid MTLDevice.
//      // If determinedDevice is nil here, the logic above has a flaw or an assumption was wrong.
//      guard let deviceToUseForNewLayer = determinedDevice else {
//          fatalError("CRITICAL init(layer:Any): deviceToUseForNewLayer is nil after determination logic. This should not happen if previous guards/conditions were met.")
//      }
//      print("DEBUG init(layer:Any): Confirmed deviceToUseForNewLayer is: \(deviceToUseForNewLayer)")
//
//      // Set our strong reference first to ensure the device is retained.
//      self.metalDevice = deviceToUseForNewLayer // self.metalDevice is MTLDevice! (strong)
//      print("DEBUG init(layer:Any): Assigned to self.metalDevice. Current value: \(String(describing: self.metalDevice))")
//
//      // Check if self.metalDevice (the strong reference) actually holds the device.
//      // If self.metalDevice is nil here, the assignment failed or deviceToUseForNewLayer was problematic.
//      guard self.metalDevice != nil else {
//          fatalError("CRITICAL init(layer:Any): self.metalDevice is nil immediately after being assigned deviceToUseForNewLayer (\(deviceToUseForNewLayer)). Strong reference failed.")
//      }
//      print("DEBUG init(layer:Any): self.metalDevice successfully holds a strong reference: \(self.metalDevice!)")
//
//      // Then set CAMetalLayer's weak reference.
//      // Assign from self.metalDevice to be certain we're using the object held by the strong ref.
//      self.device = self.metalDevice // self.device is weak property of CAMetalLayer
//      print("DEBUG init(layer:Any): Assigned to self.device. Current value: \(String(describing: self.device))")
//
//      // CRASH POINT WAS HERE:
//      // This assertion helps confirm that 'self.device' is actually set.
//      // If this fails, it means that despite self.metalDevice holding a strong reference,
//      // self.device (weak) became nil. This is highly unusual if self.metalDevice is valid.
//      assert(self.device != nil, "CRITICAL init(layer:Any): self.device (CAMetalLayer's weak property) is nil even after self.metalDevice (\(String(describing: self.metalDevice))) holds a strong reference. This suggests an issue with CAMetalLayer's device assignment or the MTLDevice instance itself.")
//
//      // --- At this point, self.metalDevice and self.device should both point to the same valid, live MTLDevice object ---
//
//      // 2. Copy CAMetalLayer specific properties.
//      if self.device != nil {
//        if other.pixelFormat == .invalid {
//          print("Warning init(layer:Any): Source layer's pixelFormat was MTLPixelFormat.invalid. Setting to .bgra8Unorm for the new layer.")
//          self.pixelFormat = .bgra8Unorm
//        } else {
//          self.pixelFormat = other.pixelFormat
//        }
//        self.framebufferOnly = other.framebufferOnly
//        self.isOpaque = other.isOpaque
//      } else {
//          // This should have been caught by the assert.
//          fatalError("CRITICAL init(layer:Any): self.device is nil before setting pixelFormat. The earlier assert should have caught this.")
//      }
//
//      // ... (rest of your init(layer: Any) method: copy custom properties, re-create Metal resources) ...
//      // 3. Copy custom application-specific state properties
//      self.colorIndex = other.colorIndex
//      self.elapsedTime = other.elapsedTime
//      self.continuousTotalElapsedTimeForRotation = other.continuousTotalElapsedTimeForRotation
//      self.currentFruitMaxDimension = other.currentFruitMaxDimension
//
//      // 4. Re-create all Metal resources
//      guard let currentDeviceForResources = self.metalDevice else {
//        fatalError("self.metalDevice is unexpectedly nil before re-creating Metal resources in init(layer:Any).")
//      }
//      guard let cq = currentDeviceForResources.makeCommandQueue() else {
//        fatalError("Could not create Metal command queue for copied layer using device: \(currentDeviceForResources).")
//      }
//      self.commandQueue = cq
//      setupPipeline()
//      createVertexBuffers()
//      createColorLocationBuffer()
//      let currentColors = calculateCurrentInterpolatedColors()
//      if let colorBuffer = currentDeviceForResources.makeBuffer(bytes: currentColors, length: MemoryLayout<SIMD4<Float>>.stride * colorArray.count, options: .storageModeShared) {
//        self.currentInterpolatedColorsBuffer = colorBuffer
//      } else {
//        fatalError("Failed to create currentInterpolatedColorsBuffer for copied layer using device: \(currentDeviceForResources).")
//      }
//
//    } else {
//      print("Warning init(layer:Any): init(layer: Any) called with a layer that is not a MetalCircularGradientLayer.")
//    }
  }

  private func setupMetal() {
    guard let device = MTLCreateSystemDefaultDevice() else {
      fatalError("Metal is not supported on this device")
    }
    self.metalDevice = device
    self.device = device // Assign to CAMetalLayer's device property

    guard let commandQueue = device.makeCommandQueue() else {
      fatalError("Could not create Metal command queue")
    }
    self.commandQueue = commandQueue
  }

  private func setupPipeline() {
    do {
      let library = try metalDevice.makeLibrary(source: metalShaderSource, options: nil)
      guard let vertexFunction = library.makeFunction(name: "vertex_shader_circular_gradient"),
            let fragmentFunction = library.makeFunction(name: "fragment_shader_circular_gradient") else {
        fatalError("Could not find shader functions")
      }

      let pipelineDescriptor = MTLRenderPipelineDescriptor()
      pipelineDescriptor.vertexFunction = vertexFunction
      pipelineDescriptor.fragmentFunction = fragmentFunction
      pipelineDescriptor.colorAttachments[0].pixelFormat = self.pixelFormat // Match CAMetalLayer's format

      pipelineState = try metalDevice.makeRenderPipelineState(descriptor: pipelineDescriptor)
    } catch {
      fatalError("Could not create Metal render pipeline state: \(error)")
    }
  }

  private func createVertexBuffers() {
    // Fullscreen quad using two triangles. Positions are for a -1 to 1 clip space.
    // CAMetalLayer will provide a viewport transform.
    let vertices: [SIMD2<Float>] = [
      SIMD2<Float>(-1.0, -1.0), // V0: Bottom Left
      SIMD2<Float>( 1.0, -1.0), // V1: Bottom Right
      SIMD2<Float>(-1.0, 1.0), // V2: Top Left

      SIMD2<Float>( 1.0, -1.0), // V1: Bottom Right (repeated)
      SIMD2<Float>( 1.0, 1.0), // V3: Top Right
      SIMD2<Float>(-1.0, 1.0)  // V2: Top Left (repeated)
    ]
    vertexBuffer = metalDevice.makeBuffer(
      bytes: vertices,
      length: MemoryLayout<SIMD2<Float>>.stride * vertices.count,
      options: .storageModeShared)
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
    self.currentFruitMaxDimension = fruit.maxDimen()
    setNeedsDisplay()
  }

  func config(fruit: Fruit) {
    self.currentFruitMaxDimension = fruit.maxDimen()
    setNeedsDisplay()
  }

  func update(deltaTime: CGFloat) {
    continuousTotalElapsedTimeForRotation += deltaTime
    elapsedTime += deltaTime
    lastUpdateTime += deltaTime
    
    var needsRedraw = false
    
    while elapsedTime >= secondsPerColor {
      elapsedTime -= secondsPerColor
      colorIndex = (colorIndex + 1) % colorArray.count
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
    guard let drawable = nextDrawable() else { return }
    let texture = drawable.texture

    updateColorBuffer(with: calculateCurrentInterpolatedColors())
    var uniforms = calculateUniforms(texture: texture)
    let renderPassDescriptor = createRenderPassDescriptor(texture: texture)

    guard let commandBuffer = commandQueue.makeCommandBuffer(),
          let renderEncoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: renderPassDescriptor
          ) else {
      return
    }

    configureRenderEncoder(renderEncoder, uniforms: &uniforms)
    renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

    renderEncoder.endEncoding()
    commandBuffer.present(drawable)
    commandBuffer.commit()
  }

  private func updateColorBuffer(with currentColors: [SIMD4<Float>]) {
    if currentInterpolatedColorsBuffer.length != MemoryLayout<SIMD4<Float>>.stride * currentColors.count {
      currentInterpolatedColorsBuffer = metalDevice.makeBuffer(
        bytes: currentColors,
        length: MemoryLayout<SIMD4<Float>>.stride * currentColors.count,
        options: .storageModeShared)
      return
    }
    currentInterpolatedColorsBuffer.contents().copyMemory(
        from: currentColors,
        byteCount: MemoryLayout<SIMD4<Float>>.stride * currentColors.count
      )
  }

  private func calculateUniforms(texture: MTLTexture) -> MetalCircularGradientFragmentUniforms {
    let offset = bounds.height * 0.021
    let movementRadius = self.currentFruitMaxDimension * 0.75
    let rotationPeriod = max(secondsPerColor * 16, 0.01)
    let angle = (continuousTotalElapsedTimeForRotation / rotationPeriod)
      .truncatingRemainder(dividingBy: 1.0) * 2 * .pi

    let calculatedCenter = CGPoint(
      x: bounds.midX + movementRadius * cos(angle),
      y: bounds.midY - offset + movementRadius * sin(angle)
    )
    let calculatedRadius = min(bounds.width, bounds.height) / 2.0

    return MetalCircularGradientFragmentUniforms(
      resolution: SIMD2<Float>(Float(texture.width), Float(texture.height)),
      gradient_center_px: SIMD2<Float>(
        Float(calculatedCenter.x * contentsScale),
        Float(calculatedCenter.y * contentsScale)
      ),
      gradient_radius_px: Float(calculatedRadius * contentsScale),
      num_color_stops: Int32(colorArray.count)
    )
  }

  private func createRenderPassDescriptor(
    texture: MTLTexture
  ) -> MTLRenderPassDescriptor {
    let renderPassDescriptor = MTLRenderPassDescriptor()
    renderPassDescriptor.colorAttachments[0].texture = texture
    renderPassDescriptor.colorAttachments[0].loadAction = .clear
    renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(
      red: 0,
      green: 0,
      blue: 0,
      alpha: 1
    )
    return renderPassDescriptor
  }

  private func configureRenderEncoder(
    _ renderEncoder: MTLRenderCommandEncoder,
    uniforms: inout MetalCircularGradientFragmentUniforms
  ) {
    renderEncoder.setRenderPipelineState(pipelineState)
    renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)

    renderEncoder.setFragmentBytes(
      &uniforms,
      length: MemoryLayout<MetalCircularGradientFragmentUniforms>.stride,
      index: 0
    )
    renderEncoder.setFragmentBuffer(currentInterpolatedColorsBuffer, offset: 0, index: 1)
    renderEncoder.setFragmentBuffer(gradientLocationsBuffer, offset: 0, index: 2)
  }

  private func calculateCurrentInterpolatedColors() -> [SIMD4<Float>] {
    guard let (startComponentList, endComponentList) = precomputedGradientComponents[colorIndex],
          startComponentList.count == endComponentList.count else {
      // Fallback: return an array of black colors
      return Array(repeating: SIMD4<Float>(0, 0, 0, 1), count: colorArray.count)
    }

    let colorTransitionProgress = min(max(elapsedTime / secondsPerColor, 0.0), 1.0)
    let colorCount = startComponentList.count
    guard colorCount >= 2 else {
      return Array(repeating: SIMD4<Float>(0, 0, 0, 1), count: colorArray.count)
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

// /// A layer that renders a circular gradient background with smooth color transitions and orbital movement.
// /// The gradient rotates around the fruit's center point, creating a dynamic and engaging visual effect.
// final class CircularGradientLayer: CALayer, Background {

//   // MARK: - Helper Structs
//   private struct ColorComponents {
//     let red, green, blue, alpha: CGFloat
//   }

//   private typealias GradientComponents = (
//     start: [ColorComponents],
//     end: [ColorComponents]
//   )

//   // MARK: - Constants
//   private static let animationStepsPerTransition: Int = 120

//   // MARK: - Color Configuration

//   /// The array of colors used in the gradient animation.
//   /// Colors are defined in sRGB color space for consistent color reproduction.
//   private let colorArray: [NSColor] = [
//     NSColor(srgbRed: 67/255, green: 156/255, blue: 214/255, alpha: 1), // BLUE
//     NSColor(srgbRed: 139/255, green: 69/255, blue: 147/255, alpha: 1), // PURPLE
//     NSColor(srgbRed: 207/255, green: 72/255, blue: 69/255, alpha: 1), // RED
//     NSColor(srgbRed: 231/255, green: 135/255, blue: 59/255, alpha: 1), // ORANGE
//     NSColor(srgbRed: 243/255, green: 185/255, blue: 75/255, alpha: 1), // YELLOW
//     NSColor(srgbRed: 120/255, green: 184/255, blue: 86/255, alpha: 1)  // GREEN
//   ]

//   /// Reusable array for CGColors to avoid allocation during drawing.
//   /// This array is cleared and reused on each draw call.
//   // private var cgColors: [CGColor] = [] // Removed: Will get colors directly from allPrecomputedCGColorFrames in draw(in:)

//   /// Cache for all possible color combinations used in the gradient.
//   /// The dictionary is keyed by the starting color index and contains tuples of
//   /// (fromColors, toColors) arrays for smooth transitions.
//   private lazy var colorCombinations: [Int: ([NSColor], [NSColor])] = {
//     let colorCount = colorArray.count
//     var combinations: [Int: ([NSColor], [NSColor])] = [:]
//     combinations.reserveCapacity(colorCount)

//     for startColorIndex in 0..<colorCount {
//       var fromColors: [NSColor] = []
//       fromColors.reserveCapacity(colorCount)
//       var toColors: [NSColor] = []
//       toColors.reserveCapacity(colorCount)

//       for endColorIndex in 0..<colorCount {
//         let fromIdx = (startColorIndex + endColorIndex) % colorCount
//         let toIdx = (startColorIndex + endColorIndex + 1) % colorCount
//         fromColors.append(colorArray[fromIdx])
//         toColors.append(colorArray[toIdx])
//       }

//       combinations[startColorIndex] = (fromColors, toColors)
//     }
//     return combinations
//   }()

//   /// Pre-calculated RGBA components for gradient transitions.
//   /// Keyed by colorIndex, contains start and end components for each color band.
//   private lazy var precomputedGradientComponents: [Int: GradientComponents] = {
//     var precomputed: [Int: GradientComponents] = [:]
//     precomputed.reserveCapacity(colorCombinations.count)
//     for (key, (fromNSColors, toNSColors)) in colorCombinations {
//       let startComps = fromNSColors.map {
//         ColorComponents(
//           red: $0.redComponent,
//           green: $0.greenComponent,
//           blue: $0.blueComponent,
//           alpha: $0.alphaComponent)
//       }
//       let endComps = toNSColors.map {
//         ColorComponents(
//           red: $0.redComponent,
//           green: $0.greenComponent,
//           blue: $0.blueComponent,
//           alpha: $0.alphaComponent
//         )
//       }
//       precomputed[key] = (start: startComps, end: endComps)
//     }
//     return precomputed
//   }()

//   private lazy var allPrecomputedGradients: [Int: [CGGradient]] = {
//     var allFrames: [Int: [CGGradient]] = [:]
//     allFrames.reserveCapacity(colorArray.count)
//     let steps = CircularGradientLayer.animationStepsPerTransition

//     // Ensure gradientLocations and gradientColorSpace are available
//     let locs = self.gradientLocations
//     let cs = self.gradientColorSpace

//     for cIndex in 0..<colorArray.count {
//       guard let (startComponentList, endComponentList) = precomputedGradientComponents[cIndex],
//             startComponentList.count == endComponentList.count else {
//         print("Warning: Missing or mismatched gradient components for colorIndex: \(cIndex)")
//         continue
//       }

//       let colorCountInGradient = startComponentList.count
//       guard colorCountInGradient >= 2 else { continue }

//       var gradientsForThisColorIndex: [CGGradient] = []
//       gradientsForThisColorIndex.reserveCapacity(steps)

//       for step in 0..<steps {
//         let progress = (steps == 1) ? 0.0 : CGFloat(step) / CGFloat(steps - 1)

//         var currentCGColorsForStep: [CGColor] = []
//         currentCGColorsForStep.reserveCapacity(colorCountInGradient)

//         for i in 0..<colorCountInGradient {
//           let fromComps = startComponentList[i]
//           let toComps = endComponentList[i]

//           let r = min(max(fromComps.red + (toComps.red - fromComps.red) * progress, 0), 1)
//           let g = min(max(fromComps.green + (toComps.green - fromComps.green) * progress, 0), 1)
//           let b = min(max(fromComps.blue + (toComps.blue - fromComps.blue) * progress, 0), 1)
//           let a = min(max(fromComps.alpha + (toComps.alpha - fromComps.alpha) * progress, 0), 1)
//           currentCGColorsForStep.append(CGColor(colorSpace: cs, components: [r,g,b,a])!)
//         }

//         if let gradient = CGGradient(colorsSpace: cs, colors: currentCGColorsForStep as CFArray, locations: locs) {
//           gradientsForThisColorIndex.append(gradient)
//         } else {
//           // This should not happen if colors and locations are valid.
//           print("Warning: Could not create CGGradient for colorIndex: \(cIndex), step: \(step)")
//         }
//       }
//       allFrames[cIndex] = gradientsForThisColorIndex
//     }
//     print("allPrecomputedGradients: \(allFrames.values.flatMap { $0 }.count) CGGradient objects created.")
//     return allFrames
//   }()

//   // MARK: - Gradient Configuration

//   /// The color space used for gradient rendering.
//   /// Using device RGB color space for optimal performance.
//   private let gradientColorSpace = CGColorSpaceCreateDeviceRGB()

//   /// Pre-calculated gradient locations for consistent color distribution.
//   /// Locations are evenly spaced between 0 and 1.
//   private lazy var gradientLocations: [CGFloat] = (0..<colorArray.count).map {
//     CGFloat($0) / CGFloat(colorArray.count - 1)
//   }

//   // MARK: - Animation Properties

//   /// The current index in the color array.
//   private var colorIndex: Int = 0

//   /// Time elapsed since the last color transition.
//   private var elapsedTime: CGFloat = 0

//   /// Total elapsed time used for continuous rotation calculation.
//   private var continuousTotalElapsedTimeForRotation: CGFloat = 0

//   /// The maximum dimension of the current fruit.
//   private var currentFruitMaxDimension: CGFloat = 50.0

//   /// Duration for each color transition in seconds.
//   private let secondsPerColor: CGFloat = 2.0

//   // MARK: - Initialization

//   /// Initializes a new circular gradient layer with the specified frame and fruit.
//   /// - Parameters:
//   ///   - frame: The frame rectangle for the layer.
//   ///   - fruit: The fruit object to determine the gradient's dimensions and positioning.
//   init(frame: NSRect, fruit: Fruit) {
//     self.currentFruitMaxDimension = fruit.maxDimen()
//     super.init()
//     self.frame = frame
//     self.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
//     _ = self.allPrecomputedGradients // Force initialization
//   }

//   required init?(coder: NSCoder) {
//     fatalError("init(coder:) has not been implemented")
//   }

//   override init(layer: Any) {
//     super.init(layer: layer)
//     self.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
//   }

//   // MARK: - Public Methods

//   /// Updates the layer's frame and fruit dimensions.
//   /// - Parameters:
//   ///   - frame: The new frame rectangle.
//   ///   - fruit: The fruit object containing updated dimensions.
//   func update(frame: NSRect, fruit: Fruit) {
//     self.frame = frame
//     self.currentFruitMaxDimension = fruit.maxDimen()
//     setNeedsDisplay()
//   }

//   /// Configures the layer with a new fruit object.
//   /// - Parameter fruit: The fruit object to configure the layer with.
//   func config(fruit: Fruit) {
//     self.currentFruitMaxDimension = fruit.maxDimen()
//     setNeedsDisplay()
//   }

//   /// Updates the animation state with the elapsed time since the last update.
//   /// - Parameter deltaTime: The time elapsed since the last update in seconds.
//   func update(deltaTime: CGFloat) {
//     continuousTotalElapsedTimeForRotation += deltaTime

//     elapsedTime += deltaTime
//     while elapsedTime >= secondsPerColor {
//       elapsedTime -= secondsPerColor
//       colorIndex = (colorIndex + 1) % colorArray.count
//     }
//     setNeedsDisplay()
//   }

//   // MARK: - Drawing

//   override func draw(in ctx: CGContext) {
//     let rect = bounds

//     // Determine current colors to use for the gradient
//     let progressInTransition = (secondsPerColor > 0) ? (elapsedTime / secondsPerColor) : 0
//     let steps = CircularGradientLayer.animationStepsPerTransition
//     var stepIndex = Int(progressInTransition * CGFloat(steps))
//     stepIndex = min(max(stepIndex, 0), steps - 1)

//     guard let gradientsForCurrentColorIndex = allPrecomputedGradients[colorIndex],
//           stepIndex < gradientsForCurrentColorIndex.count else {
//       print("Error: Could not find precomputed CGGradient for colorIndex: \(colorIndex), step: \(stepIndex). Drawing nothing.")
//       return
//     }
//     let gradientToDraw = gradientsForCurrentColorIndex[stepIndex]

//     // Calculate gradient center position and movement
//     let offset = rect.height * 0.021
//     let movementRadius = self.currentFruitMaxDimension * 0.75
//     let rotationPeriod = max(secondsPerColor * 16, 0.01)

//     // Calculate rotation angle using continuous time
//     let angle = (continuousTotalElapsedTimeForRotation / rotationPeriod)
//       .truncatingRemainder(dividingBy: 1.0) * 2 * .pi

//     // Calculate gradient center point
//     let center = CGPoint(
//       x: rect.midX + movementRadius * cos(angle),
//       y: rect.midY - offset + movementRadius * sin(angle)
//     )

//     // Calculate gradient radius
//     let radius = min(rect.width, rect.height) / 2.0

//     // Create and draw the gradient
//     ctx.saveGState()
//     // Clip to bounds for safety
//     ctx.addRect(rect)
//     ctx.clip()

//     // Draw the radial gradient
//     ctx.drawRadialGradient(
//       gradientToDraw,
//       startCenter: center,
//       startRadius: 0,
//       endCenter: center,
//       endRadius: radius,
//       options: [.drawsAfterEndLocation, .drawsBeforeStartLocation]
//     )

//     ctx.restoreGState()
//   }
// }
// swiftlint:enable file_length type_body_length
