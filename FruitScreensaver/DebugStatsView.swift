import AppKit
import IOKit

final class DebugStatsView: NSView {

  private let textFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
  private let padding: CGFloat = 8
  private let textLayer = CATextLayer()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.backgroundColor = NSColor(white: 0, alpha: 0.7).cgColor
    layer?.cornerRadius = 6

    textLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
    textLayer.alignmentMode = .left
    textLayer.isWrapped = true
    layer?.addSublayer(textLayer)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError()
  }

  func update(fps: Int) {
    let cpu = Self.processCPUUsage()
    let gpu = Self.gpuUtilization()

    var text = String(format: "FPS  %d\nCPU  %.1f%%", fps, cpu)
    if let gpu = gpu {
      text += String(format: "\nGPU  %.0f%%", gpu)
    } else {
      text += "\nGPU  N/A"
    }

    let attributed = NSAttributedString(string: text, attributes: [
      .font: textFont,
      .foregroundColor: NSColor.white
    ])

    let textSize = attributed.boundingRect(
      with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading]
    ).size

    frame.size = CGSize(
      width: ceil(textSize.width) + padding * 2,
      height: ceil(textSize.height) + padding * 2
    )

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    textLayer.frame = bounds.insetBy(dx: padding, dy: padding)
    textLayer.string = attributed
    CATransaction.commit()
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    textLayer.contentsScale = window?.backingScaleFactor
      ?? NSScreen.main?.backingScaleFactor ?? 2.0
  }

  // MARK: - CPU (per-process via Mach thread info)

  private static func processCPUUsage() -> Double {
    var threadList: thread_act_array_t?
    var threadCount: mach_msg_type_number_t = 0
    let result = task_threads(mach_task_self_, &threadList, &threadCount)
    guard result == KERN_SUCCESS, let threads = threadList else { return 0 }
    defer {
      vm_deallocate(
        mach_task_self_,
        vm_address_t(bitPattern: threads),
        vm_size_t(Int(threadCount) * MemoryLayout<thread_act_t>.stride)
      )
    }

    var totalCPU: Double = 0
    for i in 0..<Int(threadCount) {
      var info = thread_basic_info()
      var infoCount = mach_msg_type_number_t(
        MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<natural_t>.size
      )
      let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
          thread_info(threads[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &infoCount)
        }
      }
      if kr == KERN_SUCCESS && (info.flags & TH_FLAGS_IDLE) == 0 {
        totalCPU += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100.0
      }
    }
    return totalCPU
  }

  // MARK: - GPU (system-wide via IOKit IOAccelerator)

  private static func gpuUtilization() -> Double? {
    var iterator: io_iterator_t = 0
    let result = IOServiceGetMatchingServices(
      0, IOServiceMatching("IOAccelerator"), &iterator
    )
    guard result == kIOReturnSuccess else { return nil }
    defer { IOObjectRelease(iterator) }

    var entry = IOIteratorNext(iterator)
    while entry != 0 {
      let current = entry
      defer { IOObjectRelease(current) }

      var properties: Unmanaged<CFMutableDictionary>?
      if IORegistryEntryCreateCFProperties(
        current, &properties, kCFAllocatorDefault, 0
      ) == kIOReturnSuccess,
        let dict = properties?.takeRetainedValue() as? [String: Any],
        let stats = dict["PerformanceStatistics"] as? [String: Any]
      {
        if let utilization = stats["GPU Activity(%)"] as? Int {
          return Double(utilization)
        }
        if let utilization = stats["Device Utilization %"] as? Int {
          return Double(utilization)
        }
      }
      entry = IOIteratorNext(iterator)
    }
    return nil
  }
}
