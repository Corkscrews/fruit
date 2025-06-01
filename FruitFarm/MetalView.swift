//
//  MetalView.swift
//  BrightXDR
//
//  Created by Dmitry Starkov on 28/03/2023.
//

import Cocoa
import MetalKit

// Metal view displaying static HDR content to enable EDR display mode
public class MetalView: MTKView, MTKViewDelegate {
  private let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
  private var contrast: Float // values from 1.0 to 3.0, where 1.0 is optimal
  private var brightness: Float // values from 0.0 to 3.0, where 1.0 is optimal

  private var commandQueue: MTLCommandQueue?
  private var renderContext: CIContext?

  private var image: CIImage?

  /// Callback to notify when the MTKView is ready (i.e., first drawable is available)
  public var onReady: (() -> Void)?

  /// Internal flag to ensure onReady is only called once
  private var didBecomeReady = false

  /// Public initializer
  /// - frameRate: lower the frame rate for better perfomance, otherwise the screen frame rate is used (probably 120)
  /// - contrast: value use by `CIColorControls` `CIFilter`
  /// - brightness: value use by `CIColorControls` `CIFilter`
  public init(frame: CGRect, frameRate: Int? = nil, contrast: Float = 1.0, brightness: Float = 1.0) {
    self.contrast = contrast
    self.brightness = brightness
    super.init(frame: frame, device: MTLCreateSystemDefaultDevice())

    if let device = self.device {
      self.commandQueue = device.makeCommandQueue()

      // Create a CIContext for rendering a CIImage to a destination using Metal
      if let commandQueue = self.commandQueue {
        self.renderContext = CIContext(mtlCommandQueue: commandQueue, options: [
          .name: "BrightXDRContext",
          .workingColorSpace: colorSpace ?? CGColorSpace.extendedLinearSRGB,
          .workingFormat: CIFormat.RGBAf,
          .cacheIntermediates: true,
          .allowLowPower: false,
        ])
      }
    }
    self.delegate = self

    // Allow the view to display its contents outside of the framebuffer and bind the delegate to the coordinator
    self.framebufferOnly = false
    // Update FPS (matter only on space switching or on/off HDR brightness mode)
    if let frameRate = frameRate {
      self.preferredFramesPerSecond = frameRate
    } else {
      if #available(macOS 12.0, *) {
        self.preferredFramesPerSecond = NSScreen.main?.maximumFramesPerSecond ?? 120
      } else {
        self.preferredFramesPerSecond = 120
      }
    }
    // Enable EDR
    self.colorPixelFormat = .rgba16Float
    self.colorspace = colorSpace
    if let layer = self.layer as? CAMetalLayer {
      layer.wantsExtendedDynamicRangeContent = true
      layer.isOpaque = false

      // Blend EDR layer with background
      layer.compositingFilter = "multiplyBlendMode"
    }
    // Initialize color filter for brightness adjustment
    guard let colorControlsFilter = CIFilter(name: "CIColorControls") else { return }
    colorControlsFilter.setValue(contrast, forKey: kCIInputContrastKey) // default to 1.0
    colorControlsFilter.setValue(brightness, forKey: kCIInputBrightnessKey) // default to 0.0

    // Transparent color in EDR color space
    guard let colorSpace = colorSpace, let color = CIColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0, colorSpace: colorSpace),
          let cgColor = CGColor(colorSpace: colorSpace, components: [1.0, 1.0, 1.0, 1.0]) else {
      return
    }

    // Text overlay
    var preview: CIImage?

    // Preview data
    let textLayer = CATextLayer()
    textLayer.string = "Bright XDR"
    textLayer.font = NSFont.boldSystemFont(ofSize: 16) // fontSize ignored
    textLayer.fontSize = 1
    textLayer.foregroundColor = cgColor
    //textLayer.contentsScale = screenScale

    // Calculate text size and position
    let textLayerSize = textLayer.preferredFrameSize()
    textLayer.frame = CGRect(x: 0, y: 0, width: textLayerSize.width, height: textLayerSize.height)
    textLayer.position = CGPoint(x: bounds.width / 2, y: bounds.height / 2)

    // Render text layer on NSImage
    let textImage = NSImage(size: bounds.size)
    textImage.lockFocus()
    if let current = NSGraphicsContext.current {
      let context = current.cgContext
      // Center text
      context.translateBy(x: bounds.width / 2 - textLayerSize.width / 2, y: bounds.height / 2 - textLayerSize.height / 2)
      textLayer.render(in: context)
      textImage.unlockFocus()
      // Convert to CIImage
      if let cgImage = textImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
        // Apply color filter
        colorControlsFilter.setValue(CIImage(cgImage: cgImage), forKey: kCIInputImageKey)
        if let image = colorControlsFilter.outputImage {
          // Save preview image
          preview = image
        }
      }
    }

    // Solid transparent
    var transparent: CIImage?
    // Apply color filter
    colorControlsFilter.setValue(CIImage(color: color), forKey: kCIInputImageKey)
    if let image = colorControlsFilter.outputImage {
      // Save main image
      transparent = image
    }

    // Set global image
    if (preview != nil) {
      self.image = preview
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
        // Hide app preview
        self.image = transparent
      }
    } else {
      self.image = transparent
    }
  }

  required init(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /// Detect when the MTKView is ready by checking for the first available drawable in draw(in:)
  public func draw(in view: MTKView) {
    // Verify transparent image was rendered
    guard let image = image, let colorSpace = colorSpace else { return  }

    // Check Metal device was initialized correctly
    guard let commandQueue = commandQueue, let renderContext = renderContext else { return }

    // Create a new command buffer and get the drawable object to render into
    guard let commandBuffer = commandQueue.makeCommandBuffer(), let drawable = currentDrawable else { return }

    // Notify when the view is ready (first drawable available)
    if !didBecomeReady {
      didBecomeReady = true
      onReady?()
    }

    // Render the CIImage
    renderContext.render(image, to: drawable.texture, commandBuffer: commandBuffer, bounds: CGRect(origin: CGPoint.zero, size: drawableSize), colorSpace: colorSpace)

    // Present the drawable to the screen
    commandBuffer.present(drawable)

    // Commit the command buffer for execution on the GPU
    commandBuffer.commit()
  }

  public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { }
}
