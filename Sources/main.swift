import Cocoa
import Darwin

// MARK: - launchd Socket Activation

func getLaunchdSocket() -> Int32? {
  var fds: UnsafeMutablePointer<Int32> = .allocate(capacity: 0)
  var count: Int = 0
  let result = launch_activate_socket("Listeners", &fds, &count)
  guard result == 0, count > 0 else {
    if result != 0 {
      print("[Helper] Not launchd-managed (err=\(result)), will bind directly")
    } else {
      // result==0 but no sockets — free the allocation launchd wrote.
      free(fds)
    }
    return nil
  }
  let socketFD = fds[0]
  free(fds)
  return socketFD
}

let helperVersion = "1.2.1"

// MARK: - Setup

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// `--sensor-only` mode: skip the TCP server (no port conflict with the
// installed helper), just run motion detection and print events.
// `--sensor-only --verbose` additionally prints live tilt + RMS every 1 s.
if CommandLine.arguments.contains("--sensor-only") {
  let verboseMode = CommandLine.arguments.contains("--verbose")
  print("[Helper] Sensor-only debug mode (no TCP server, verbose=\(verboseMode))")
  let motionMonitor = MotionMonitor()
  motionMonitor.verbose = verboseMode
  motionMonitor.onMotionDetected = { detail, session in
    print("[Debug] >>> motion detected (\(detail)) session=\(session) <<<")
  }
  _ = motionMonitor.start()
  signal(SIGINT, SIG_IGN)
  let sigInt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
  sigInt.setEventHandler {
    MainActor.assumeIsolated {
      print("[Helper] SIGINT, stopping sensor")
      motionMonitor.stop()
      exit(0)
    }
  }
  sigInt.resume()
  app.run()
  exit(0)
}

let authManager = AuthManager()
let pmsetManager = PmsetManager()
let lockScreenManager = LockScreenManager()
let powerButtonMonitor = PowerButtonMonitor()
let motionMonitor = MotionMonitor()

let server = TCPServer(
  authManager: authManager,
  pmsetManager: pmsetManager,
  lockScreenManager: lockScreenManager,
  powerButtonMonitor: powerButtonMonitor,
  motionMonitor: motionMonitor,
  version: helperVersion
)

// Wire power button callback to broadcast
powerButtonMonitor.onPowerButtonPressed = { [weak server] in
  server?.broadcast(.powerButtonPressed())
}

// Wire motion callback to broadcast
motionMonitor.onMotionDetected = { [weak server] detail, session in
  server?.broadcast(.motionDetected(detail: detail, session: session))
}

// Observe system wake so MotionMonitor can re-wake the SPU and recalibrate.
let wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
  forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
) { [weak motionMonitor] _ in
  MainActor.assumeIsolated {
    print("[Helper] System did wake")
    motionMonitor?.handleSystemDidWake()
  }
}
_ = wakeObserver

// MARK: - Signal Handling (install BEFORE server.start so SIGTERM during
// startup runs cleanup instead of the default handler).

signal(SIGTERM, SIG_IGN)
let sigSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigSource.setEventHandler {
  MainActor.assumeIsolated {
    print("[Helper] SIGTERM received, cleaning up")
    pmsetManager.disable()
    lockScreenManager.hide()
    powerButtonMonitor.stop()
    motionMonitor.stop()
    exit(0)
  }
}
sigSource.resume()

let launchdFD = getLaunchdSocket()
guard server.start(existingFD: launchdFD) else {
  print("[Helper] TCP server failed to start — exiting")
  exit(1)
}

// MARK: - Idle Timeout

// Require TWO consecutive idle ticks at zero before exiting, so a connection
// arriving between ticks doesn't get dropped by a preemptive exit at t=30s.
nonisolated(unsafe) var idleSeconds: Int = 0
nonisolated(unsafe) var consecutiveIdleTicks: Int = 0
let idleTimer = DispatchSource.makeTimerSource(queue: .main)
idleTimer.schedule(deadline: .now() + 5, repeating: 5)
idleTimer.setEventHandler {
  MainActor.assumeIsolated {
    if server.activeConnections == 0 {
      consecutiveIdleTicks += 1
      idleSeconds += 5
      if idleSeconds >= 30 && consecutiveIdleTicks >= 2 {
        print("[Helper] Idle timeout (30s, \(consecutiveIdleTicks) ticks), exiting")
        pmsetManager.disable()
        lockScreenManager.hide()
        powerButtonMonitor.stop()
        motionMonitor.stop()
        exit(0)
      }
    } else {
      idleSeconds = 0
      consecutiveIdleTicks = 0
    }
  }
}
idleTimer.resume()

print("[Helper] Started v\(helperVersion) (pid=\(getpid()))")

// MARK: - Run Loop

app.run()
