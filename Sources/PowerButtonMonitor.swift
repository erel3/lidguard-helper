import ApplicationServices
import Cocoa

final class PowerButtonMonitor {
  var onPowerButtonPressed: (() -> Void)?

  private var globalMonitor: Any?
  private var localMonitor: Any?
  private(set) var isMonitoring = false

  func start() {
    guard globalMonitor == nil else { return }

    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
    if !AXIsProcessTrustedWithOptions(options) {
      print("[PowerButtonMonitor] Accessibility permission not granted")
    }

    globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { [weak self] event in
      self?.handleSystemEvent(event)
    }
    localMonitor = NSEvent.addLocalMonitorForEvents(matching: .systemDefined) { [weak self] event in
      self?.handleSystemEvent(event)
      return event
    }
    isMonitoring = true
    print("[PowerButtonMonitor] Started")
  }

  func stop() {
    if let monitor = globalMonitor {
      NSEvent.removeMonitor(monitor)
      globalMonitor = nil
    }
    if let monitor = localMonitor {
      NSEvent.removeMonitor(monitor)
      localMonitor = nil
    }
    isMonitoring = false
    print("[PowerButtonMonitor] Stopped")
  }

  private func handleSystemEvent(_ event: NSEvent) {
    let subtype = event.subtype.rawValue
    guard subtype == 8 || subtype == 16 else { return }

    let data1 = event.data1
    let keyCode = (data1 & 0xFFFF0000) >> 16

    let isPowerButton = (subtype == 16) || (subtype == 8 && keyCode == 0x7F)
    if isPowerButton {
      onPowerButtonPressed?()
    }
  }
}
