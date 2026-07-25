// SensorReader.swift — IOKit HID accelerometer interface for Apple Silicon
//
// Reads raw acceleration from the Apple SPU (Sensor Processing Unit) via
// IOKit HID. The SPU houses a Bosch BMI286 IMU on Apple Silicon MacBooks
// (M1 Pro, M2+). Native report rate is ~400-800 Hz depending on chip
// generation (M3 Max observed at ~800 Hz). Requires root.
//
// Adapted from OpenSlap (MIT License, © 2024 OpenSlap Contributors).
// Source: https://github.com/Nabeel-javed/OpenSlap
// Changes: inlined constants, removed shared-module coupling, print tags
// adjusted for lidguard-helper logging style.

import Foundation
import IOKit
import IOKit.hid

// Physics-axis variable names (x/y/z) and byte indices (byte0..byte3)
// are domain-correct short names; keeping them instead of verbose aliases.
struct AccelerometerSample: Sendable {
  let x: Double  // g-force
  let y: Double
  let z: Double
  let timestamp: TimeInterval  // mach_absolute_time seconds

  var magnitude: Double { (x * x + y * y + z * z).squareRoot() }
}

@MainActor
protocol SensorReaderDelegate: AnyObject {
  func sensorReader(_ reader: SensorReader, didReceiveSample sample: AccelerometerSample)
  func sensorReader(_ reader: SensorReader, didChangeConnectionState connected: Bool)
}

@MainActor
final class SensorReader {

  // Apple vendor-defined HID usage page for the SPU sensors.
  nonisolated static let sensorUsagePage: Int = 0xFF00
  // Usage 3 on that page is the accelerometer.
  nonisolated static let sensorUsage: Int = 3
  // BMI286 accelerometer reports are 22 bytes: 6-byte header, X/Y/Z as
  // Int32-LE Q16.16 at offsets 6/10/14, 4-byte tail.
  nonisolated static let reportLength: Int = 22
  nonisolated static let xOffset: Int = 6
  nonisolated static let yOffset: Int = 10
  nonisolated static let zOffset: Int = 14
  // Q16.16 fixed-point: raw Int32 / 65536 -> g-force.
  nonisolated static let rawToGForce: Double = 65536.0
  // Buffer size with headroom in case future firmware grows the report.
  nonisolated static let bufferSize: Int = 64
  // Apple's PCI vendor ID; used to disambiguate the accelerometer from
  // other HID devices that share vendor usage page 0xFF00 (keyboard, trackpad).
  nonisolated static let appleVendorID: Int = 0x05AC

  weak var delegate: SensorReaderDelegate?

  /// Why the last `start()` returned false.
  ///
  /// The distinction exists so callers can tell a retryable failure from a
  /// permanent one. `openAndEnumerate` already logs the two cases separately —
  /// an `IOHIDManagerOpen` failure (SPU driver not yet awake, sensor contended)
  /// versus an empty device set (Intel Mac / plain M1, no SPU accelerometer at
  /// all) — but returned nil for both, so MotionMonitor had to treat every
  /// failure as permanent.
  enum StartFailure {
    /// Retrying later can succeed.
    case transient
    /// No SPU accelerometer on this Mac; retrying never will.
    case unsupportedHardware
  }
  private(set) var lastStartFailure: StartFailure?

  private var manager: IOHIDManager?
  private var device: IOHIDDevice?
  private var reportBuffer: UnsafeMutablePointer<UInt8>

  private(set) var measuredSampleRate: Double = 0
  private var sampleCount: UInt64 = 0
  private var lastRateCheck: TimeInterval = 0

  private let timebaseNumer: Double
  private let timebaseDenom: Double

  init() {
    reportBuffer = .allocate(capacity: SensorReader.bufferSize)
    reportBuffer.initialize(repeating: 0, count: SensorReader.bufferSize)

    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    timebaseNumer = Double(info.numer)
    timebaseDenom = Double(info.denom)
  }

  isolated deinit {
    reportBuffer.deallocate()
  }

  /// Open the HID manager, find the accelerometer, and start streaming.
  /// Returns `true` if the sensor was found and streaming began.
  @discardableResult
  func start() -> Bool {
    guard manager == nil else { return device != nil }
    lastStartFailure = nil

    // Wake SPU drivers: the BMI286 sensor is powered-down by default; we must
    // set three registry properties on every AppleSPUHIDDriver instance
    // before the HID device will emit reports. Port of the Go library's
    // wakeSPUDrivers() sequence (taigrr/apple-silicon-accelerometer).
    wakeSPUDrivers()

    let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    let matchingDict: [String: Int] = [
      kIOHIDPrimaryUsagePageKey as String: SensorReader.sensorUsagePage,
      kIOHIDPrimaryUsageKey as String: SensorReader.sensorUsage
    ]
    IOHIDManagerSetDeviceMatching(mgr, matchingDict as CFDictionary)
    IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

    guard let deviceSet = openAndEnumerate(mgr) else {
      abandon(mgr)
      delegate?.sensorReader(self, didChangeConnectionState: false)
      return false
    }

    guard let selected = selectAccelerometer(from: deviceSet) else {
      print("[SensorReader] No suitable device among matches.")
      lastStartFailure = .unsupportedHardware
      abandon(mgr)
      delegate?.sensorReader(self, didChangeConnectionState: false)
      return false
    }

    logSelected(selected)
    device = selected
    manager = mgr

    let context = Unmanaged.passUnretained(self).toOpaque()
    IOHIDDeviceRegisterInputReportCallback(
      selected,
      reportBuffer,
      SensorReader.bufferSize,
      hidReportCallback,
      context
    )

    lastRateCheck = currentTimestamp()
    delegate?.sensorReader(self, didChangeConnectionState: true)
    print("[SensorReader] Streaming started")
    return true
  }

  /// Release a manager that failed to yield a usable device, leaving `manager`
  /// nil so a later `start()` genuinely retries.
  ///
  /// Storing it instead makes the `guard manager == nil` at the top of `start()`
  /// return `device != nil` — false — forever. Nothing clears the field either:
  /// MotionMonitor latches `isHardwareSupported = false` and leaves
  /// `isMonitoring` false, so its `stop()` early-returns and never reaches
  /// `SensorReader.stop()`. One transient IOHIDManagerOpen failure at arm time
  /// therefore kills motion detection for the whole helper lifetime.
  private func abandon(_ mgr: IOHIDManager) {
    IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
    manager = nil
  }

  func stop() {
    if let dev = device {
      IOHIDDeviceRegisterInputReportCallback(dev, reportBuffer, SensorReader.bufferSize, nil, nil)
      device = nil
    }
    if let mgr = manager {
      IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
      IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
      manager = nil
    }
    delegate?.sensorReader(self, didChangeConnectionState: false)
  }

  // MARK: - Private helpers

  /// Re-run the SPU driver wake sequence. Safe to call after a system wake,
  /// when the sensor may have powered down during sleep.
  func rewakeSPU() {
    wakeSPUDrivers()
  }

  /// Set three properties on every AppleSPUHIDDriver to enable the sensor.
  /// Without this, the HID device matches but no reports are delivered.
  private func wakeSPUDrivers() {
    guard let matching = IOServiceMatching("AppleSPUHIDDriver") else {
      print("[SensorReader] wakeSPUDrivers: IOServiceMatching returned nil")
      return
    }
    var iter: io_iterator_t = 0
    let kern = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter)
    guard kern == KERN_SUCCESS else {
      print("[SensorReader] wakeSPUDrivers: IOServiceGetMatchingServices failed: \(kern)")
      return
    }
    defer { IOObjectRelease(iter) }

    var one: Int32 = 1
    var interval: Int32 = 1000  // microseconds
    let reportingNum = CFNumberCreate(nil, .sInt32Type, &one)
    let powerNum = CFNumberCreate(nil, .sInt32Type, &one)
    let intervalNum = CFNumberCreate(nil, .sInt32Type, &interval)

    var count = 0
    while true {
      let svc = IOIteratorNext(iter)
      if svc == 0 { break }
      IORegistryEntrySetCFProperty(svc, "SensorPropertyReportingState" as CFString, reportingNum)
      IORegistryEntrySetCFProperty(svc, "SensorPropertyPowerState" as CFString, powerNum)
      IORegistryEntrySetCFProperty(svc, "ReportInterval" as CFString, intervalNum)
      IOObjectRelease(svc)
      count += 1
    }
    print("[SensorReader] Woke \(count) SPU driver(s)")
  }

  private func openAndEnumerate(_ mgr: IOHIDManager) -> Set<IOHIDDevice>? {
    let openResult = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
    guard openResult == kIOReturnSuccess else {
      print("[SensorReader] IOHIDManagerOpen failed: 0x\(String(openResult, radix: 16))")
      print("[SensorReader] Needs root; helper must run as root for SPU HID access.")
      lastStartFailure = .transient
      return nil
    }
    guard let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>, !set.isEmpty else {
      print("[SensorReader] No SPU accelerometer device. Unsupported hardware (Intel or plain M1?).")
      lastStartFailure = .unsupportedHardware
      return nil
    }
    logCandidates(set)
    return set
  }

  private func logCandidates(_ set: Set<IOHIDDevice>) {
    for (idx, dev) in set.enumerated() {
      let product = IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String ?? "Unknown"
      let size = IOHIDDeviceGetProperty(dev, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? -1
      print("[SensorReader] Candidate \(idx): \(product) (reportSize=\(size))")
    }
  }

  private func logSelected(_ dev: IOHIDDevice) {
    let product = IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String ?? "Unknown"
    let max = IOHIDDeviceGetProperty(dev, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? -1
    print("[SensorReader] Selected: \(product) (maxReportSize=\(max))")
  }

  private func selectAccelerometer(from set: Set<IOHIDDevice>) -> IOHIDDevice? {
    if let exact = set.first(where: { dev in
      let vendor = IOHIDDeviceGetProperty(dev, kIOHIDVendorIDKey as CFString) as? Int ?? 0
      let size = IOHIDDeviceGetProperty(dev, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 0
      return vendor == SensorReader.appleVendorID && size == SensorReader.reportLength
    }) {
      return exact
    }
    // Fallback: smallest reportSize >= 18 (exclude keyboards with larger reports).
    return set.filter { dev in
      let size = IOHIDDeviceGetProperty(dev, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 0
      return size >= 18
    }.sorted { lhs, rhs in
      let lhsSize = IOHIDDeviceGetProperty(lhs, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 999
      let rhsSize = IOHIDDeviceGetProperty(rhs, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 999
      return lhsSize < rhsSize
    }.first
  }

  /// Parse a raw HID report into a Sendable sample without touching
  /// main-actor-isolated state; called from the C callback before we
  /// hop to MainActor to deliver it.
  nonisolated func parseReport(_ report: UnsafePointer<UInt8>, length: Int) -> AccelerometerSample? {
    guard length >= 18 else { return nil }
    let rawX = Self.readInt32LE(report, offset: SensorReader.xOffset)
    let rawY = Self.readInt32LE(report, offset: SensorReader.yOffset)
    let rawZ = Self.readInt32LE(report, offset: SensorReader.zOffset)
    return AccelerometerSample(
      x: Double(rawX) / SensorReader.rawToGForce,
      y: Double(rawY) / SensorReader.rawToGForce,
      z: Double(rawZ) / SensorReader.rawToGForce,
      timestamp: currentTimestamp()
    )
  }

  fileprivate func handleSample(_ sample: AccelerometerSample) {
    sampleCount += 1
    if sampleCount % 1000 == 0 {
      let now = currentTimestamp()
      let elapsed = now - lastRateCheck
      if elapsed > 0 {
        measuredSampleRate = 1000.0 / elapsed
        lastRateCheck = now
      }
    }
    delegate?.sensorReader(self, didReceiveSample: sample)
  }

  nonisolated private static func readInt32LE(_ buffer: UnsafePointer<UInt8>, offset: Int) -> Int32 {
    let b0 = Int32(buffer[offset])
    let b1 = Int32(buffer[offset + 1]) << 8
    let b2 = Int32(buffer[offset + 2]) << 16
    let b3 = Int32(buffer[offset + 3]) << 24
    return b0 | b1 | b2 | b3
  }

  nonisolated private func currentTimestamp() -> TimeInterval {
    Double(mach_absolute_time()) * timebaseNumer / timebaseDenom / 1_000_000_000.0
  }
}

// IOKit's HID report callback ABI fixes these 7 params.
private func hidReportCallback(
  context: UnsafeMutableRawPointer?,
  result: IOReturn,
  sender: UnsafeMutableRawPointer?,
  type: IOHIDReportType,
  reportID: UInt32,
  report: UnsafeMutablePointer<UInt8>,
  reportLength: CFIndex
) {
  guard let context else { return }
  let reader = Unmanaged<SensorReader>.fromOpaque(context).takeUnretainedValue()
  guard let sample = reader.parseReport(report, length: reportLength) else { return }
  // Scheduled on main runloop via IOHIDManagerScheduleWithRunLoop in start().
  MainActor.assumeIsolated {
    reader.handleSample(sample)
  }
}
