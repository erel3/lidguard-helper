// MotionMonitor.swift — tilt + walking detector on top of SensorReader.
//
// Sits between the raw IOKit HID stream and the rest of the helper:
// decimates the ~800 Hz sample rate to ~20 Hz, calibrates a baseline
// gravity vector at start, then evaluates two trigger paths:
//
//   1. Tilt   — angle of current gravity vector vs. baseline exceeds
//               `tiltAngleDegrees` sustained for `tiltSustainSamples`.
//               Catches pickups, laptop-in-hand, any reorientation.
//
//   2. Walking — RMS of (sample - baseline) over the last `rmsWindowSamples`
//                exceeds `rmsThresholdG`. Catches being carried while
//                kept roughly level.
//
// After any fire, a cooldown suppresses further triggers for
// `cooldownSeconds` so a single event isn't re-reported.

import Foundation

final class MotionMonitor {

  /// Called on the run loop hosting MotionMonitor when a trigger fires.
  /// `detail` is a human-readable diagnostic ("tilt=17°" or "rms=0.18g");
  /// `session` identifies the current monitoring session (incremented on
  /// every successful `start()`) so the main app can drop stale in-flight
  /// events after a stop/start recalibration.
  var onMotionDetected: ((_ detail: String, _ session: UInt64) -> Void)?

  /// Current monitoring session number. Starts at 0; `start()` increments.
  private(set) var currentSession: UInt64 = 0

  // Tuning defaults — hard-coded; see plan for rationale.
  private static let decimation = 40                 // 800 Hz / 40 = ~20 Hz
  private static let calibrationSamples = 10         // ~500 ms at 20 Hz
  private static let tiltAngleDegrees = 15.0         // pickup threshold
  private static let tiltSustainSamples = 8          // 8 × 50 ms = 400 ms
  private static let rmsWindowSamples = 40           // 2 s at 20 Hz
  private static let rmsThresholdG = 0.15            // walking cadence
  private static let cooldownSeconds: TimeInterval = 2.0
  private static let verboseEveryNSamples = 20       // ~1 Hz heartbeat

  /// When true, print current tilt angle + RMS every ~1 s for tuning.
  var verbose = false

  private let sensorReader: SensorReader

  // Decimation counter.
  private var sampleSkip = 0

  // Calibration state.
  private var calibrationCount = 0
  private var calibSum: SIMD3<Double> = .zero
  private var baseline: SIMD3<Double>?
  private var baselineMag: Double = 1.0

  private var verboseCounter = 0

  // Tilt detector state: count of consecutive decimated samples over threshold.
  private var tiltRunLength = 0
  private var lastAngleDeg: Double = 0
  private var lastRms: Double = 0

  // RMS detector state: rolling buffer of squared (sample - baseline) magnitudes.
  private var rmsBuffer = [Double]()
  private var rmsIndex = 0
  private var rmsSumSquares = 0.0

  // Cooldown state.
  private var lastFireTime: TimeInterval = 0
  private(set) var isMonitoring = false

  /// Optimistic until proven false. On a failed `start()` (device missing,
  /// no root, unsupported hardware) this flips to false and stays false
  /// for the helper's lifetime. Used by the status message so the main app
  /// can hide the Motion toggle on unsupported Macs.
  private(set) var isHardwareSupported: Bool = true

  init(sensorReader: SensorReader = SensorReader()) {
    self.sensorReader = sensorReader
    self.sensorReader.delegate = self
  }

  @discardableResult
  func start() -> Bool {
    guard !isMonitoring else { return true }
    resetState()
    let started = sensorReader.start()
    isMonitoring = started
    if !started { isHardwareSupported = false }
    if started {
      currentSession &+= 1
      print("[MotionMonitor] Started session \(currentSession); calibrating...")
    }
    return started
  }

  func stop() {
    guard isMonitoring else { return }
    sensorReader.stop()
    isMonitoring = false
    resetState()
    print("[MotionMonitor] Stopped")
  }

  /// Re-wake the SPU sensor (it may power down on system sleep). If currently
  /// monitoring, also drops the baseline so a fresh calibration captures the
  /// post-wake resting position.
  func handleSystemDidWake() {
    sensorReader.rewakeSPU()
    guard isMonitoring else { return }
    resetState()
    print("[MotionMonitor] Post-wake recalibration")
  }

  // MARK: - Internals

  private func resetState() {
    sampleSkip = 0
    calibrationCount = 0
    calibSum = .zero
    baseline = nil
    baselineMag = 1.0
    tiltRunLength = 0
    rmsBuffer = Array(repeating: 0.0, count: MotionMonitor.rmsWindowSamples)
    rmsIndex = 0
    rmsSumSquares = 0
    lastFireTime = 0
    verboseCounter = 0
    lastAngleDeg = 0
    lastRms = 0
  }

  fileprivate func process(sample: AccelerometerSample) {
    sampleSkip += 1
    if sampleSkip < MotionMonitor.decimation { return }
    sampleSkip = 0

    let vec = SIMD3<Double>(sample.x, sample.y, sample.z)

    if baseline == nil {
      calibrate(with: vec)
      return
    }
    guard let base = baseline else { return }

    let now = sample.timestamp
    if now - lastFireTime < MotionMonitor.cooldownSeconds { return }

    let fired = evaluateTilt(vec: vec, baseline: base, now: now)
    if !fired { evaluateWalking(vec: vec, baseline: base, now: now) }
    verboseCounter += 1
    if verbose && verboseCounter >= MotionMonitor.verboseEveryNSamples {
      verboseCounter = 0
      print(
        String(format: "[MotionMonitor] tilt=%.1f° rms=%.3fg", lastAngleDeg, lastRms)
      )
    }
  }

  private func calibrate(with vec: SIMD3<Double>) {
    calibSum += vec
    calibrationCount += 1
    if calibrationCount < MotionMonitor.calibrationSamples { return }
    let base = calibSum / Double(calibrationCount)
    baseline = base
    baselineMag = (base * base).sum().squareRoot()
    print(
      String(
        format: "[MotionMonitor] Calibrated baseline: x=%+.3fg y=%+.3fg z=%+.3fg |g|=%.3fg",
        base.x, base.y, base.z, baselineMag
      )
    )
  }

  /// Returns true if the tilt detector fired (so caller should skip RMS update).
  private func evaluateTilt(vec: SIMD3<Double>, baseline: SIMD3<Double>, now: TimeInterval) -> Bool {
    let dot = (vec * baseline).sum()
    let magnitude = (vec * vec).sum().squareRoot()
    let denom = magnitude * baselineMag
    let cosAngle = denom > 1e-6 ? max(-1.0, min(1.0, dot / denom)) : 1.0
    let angleDeg = acos(cosAngle) * 180.0 / .pi
    lastAngleDeg = angleDeg

    if angleDeg >= MotionMonitor.tiltAngleDegrees {
      tiltRunLength += 1
      if tiltRunLength >= MotionMonitor.tiltSustainSamples {
        fire(detail: String(format: "tilt=%.0f°", angleDeg), now: now)
        return true
      }
    } else {
      tiltRunLength = 0
    }
    return false
  }

  private func evaluateWalking(vec: SIMD3<Double>, baseline: SIMD3<Double>, now: TimeInterval) {
    let delta = vec - baseline
    let deviationSq = (delta * delta).sum()

    let old = rmsBuffer[rmsIndex]
    rmsBuffer[rmsIndex] = deviationSq
    rmsSumSquares += deviationSq - old
    rmsIndex = (rmsIndex + 1) % MotionMonitor.rmsWindowSamples

    if rmsSumSquares <= 0 { return }
    let rms = (rmsSumSquares / Double(MotionMonitor.rmsWindowSamples)).squareRoot()
    lastRms = rms
    if rms >= MotionMonitor.rmsThresholdG {
      fire(detail: String(format: "rms=%.3fg", rms), now: now)
    }
  }

  private func fire(detail: String, now: TimeInterval) {
    lastFireTime = now
    tiltRunLength = 0
    rmsBuffer = Array(repeating: 0.0, count: MotionMonitor.rmsWindowSamples)
    rmsSumSquares = 0
    print("[MotionMonitor] MOTION: \(detail)")
    onMotionDetected?(detail, currentSession)
  }
}

extension MotionMonitor: SensorReaderDelegate {
  func sensorReader(_ reader: SensorReader, didReceiveSample sample: AccelerometerSample) {
    process(sample: sample)
  }

  func sensorReader(_ reader: SensorReader, didChangeConnectionState connected: Bool) {
    print("[MotionMonitor] Sensor connected=\(connected)")
  }
}
