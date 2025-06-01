import Cocoa
import MetalKit

public final class MetalView: MTKView, MTKViewDelegate {
  // MARK: - Public Properties
  public var onReady: (() -> Void)?

  // MARK: - Private Properties
  private let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
  private var contrast: Float // values from 1.0 to 3.0, where 1.0 is optimal
  private var brightness: Float // values from 0.0 to 3.0, where 1.0 is optimal
  private var commandQueue: MTLCommandQueue?
  private var renderContext: CIContext?
  private var image: CIImage?
  private var didBecomeReady = false

  // MARK: - Init
  /// Public initializer
  /// - frameRate: lower the frame rate for better perfomance, otherwise the screen frame
  /// rate is used (probably 120)
  /// - contrast: value use by `CIColorControls` `CIFilter`
  /// - brightness: value use by `CIColorControls` `CIFilter`
  public init(
    frame: CGRect,
    frameRate: Int? = nil,
    contrast: Float = 1.0,
    brightness: Float = 1.0
  ) {
    self.contrast = contrast
    self.brightness = brightness
    super.init(frame: frame, device: MTLCreateSystemDefaultDevice())
    setupMetal(frameRate: frameRate)
    setupImagePipeline()
  }

  required init(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Setup
  private func setupMetal(frameRate: Int?) {
    guard let device = self.device else { return }
    commandQueue = device.makeCommandQueue()
    if let commandQueue = commandQueue {
      renderContext = CIContext(mtlCommandQueue: commandQueue, options: [
        .name: "MetalViewContext",
        .workingColorSpace: colorSpace ?? CGColorSpace.extendedLinearSRGB,
        .workingFormat: CIFormat.RGBAf,
        .allowLowPower: false,
        .cacheIntermediates: true
      ])
    }
    delegate = self
    framebufferOnly = false
    preferredFramesPerSecond = frameRate ?? MetalView.defaultFrameRate
    colorPixelFormat = .rgba16Float
    colorspace = colorSpace
    enableEDR()
  }

  private func enableEDR() {
    guard let layer = self.layer as? CAMetalLayer else { return }
    layer.wantsExtendedDynamicRangeContent = true
    layer.isOpaque = false
    layer.compositingFilter = "multiplyBlendMode"
  }

  private func setupImagePipeline() {
    let filter = makeColorControlsFilter()
    let preview = makePreviewImage(filter: filter)
    let transparent = makeTransparentImage(filter: filter)
    if let preview = preview {
      image = preview
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
        self?.image = transparent
      }
    } else {
      image = transparent
    }
  }

  // MARK: - Image Preparation
  private func makeColorControlsFilter() -> CIFilter {
    let filter = CIFilter(name: "CIColorControls")!
    filter.setValue(contrast, forKey: kCIInputContrastKey)
    filter.setValue(brightness, forKey: kCIInputBrightnessKey)
    return filter
  }

  private func makePreviewImage(filter: CIFilter) -> CIImage? {
    let text = " "
    let size = bounds.size
    let textImage = NSImage(size: size)
    textImage.lockFocus()
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: min(size.width, size.height) / 8, weight: .bold),
      .foregroundColor: NSColor.white,
      .paragraphStyle: style
    ]
    let rect = CGRect(x: 0, y: (size.height - 40) / 2, width: size.width, height: 40)
    (text as NSString).draw(in: rect, withAttributes: attrs)
    textImage.unlockFocus()
    guard let cgImage = textImage.cgImage(
      forProposedRect: nil,
      context: nil,
      hints: nil
    ) else { return nil }
    filter.setValue(CIImage(cgImage: cgImage), forKey: kCIInputImageKey)
    return filter.outputImage
  }

  private func makeTransparentImage(filter: CIFilter) -> CIImage? {
    guard let colorSpace = colorSpace,
          let color = CIColor(
            red: 1,
            green: 1,
            blue: 1,
            alpha: 1,
            colorSpace: colorSpace
          ) else { return nil }
    filter.setValue(CIImage(color: color), forKey: kCIInputImageKey)
    return filter.outputImage
  }

  // MARK: - MTKViewDelegate
  public func draw(in view: MTKView) {
    guard let image = image,
          let colorSpace = colorSpace,
          let commandQueue = commandQueue,
          let renderContext = renderContext,
          let commandBuffer = commandQueue.makeCommandBuffer(),
          let drawable = currentDrawable else { return }
    if !didBecomeReady {
      didBecomeReady = true
      onReady?()
    }
    renderContext.render(
      image,
      to: drawable.texture,
      commandBuffer: commandBuffer,
      bounds: CGRect(origin: .zero, size: drawableSize),
      colorSpace: colorSpace
    )
    commandBuffer.present(drawable)
    commandBuffer.commit()
  }

  public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { }

  // MARK: - Helpers
  private static var defaultFrameRate: Int {
    if #available(macOS 12.0, *) {
      return NSScreen.main?.maximumFramesPerSecond ?? 120
    } else {
      return 120
    }
  }
}
