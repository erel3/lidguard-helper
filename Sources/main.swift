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
    }
    return nil
  }
  let socketFD = fds[0]
  free(fds)
  return socketFD
}

let helperVersion = "1.0.6"

// MARK: - Setup

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let authManager = AuthManager()
let pmsetManager = PmsetManager()
let lockScreenManager = LockScreenManager()
let powerButtonMonitor = PowerButtonMonitor()

let server = TCPServer(
  authManager: authManager,
  pmsetManager: pmsetManager,
  lockScreenManager: lockScreenManager,
  powerButtonMonitor: powerButtonMonitor,
  version: helperVersion
)

// Wire power button callback to broadcast
powerButtonMonitor.onPowerButtonPressed = { [weak server] in
  server?.broadcast(.powerButtonPressed())
}

let launchdFD = getLaunchdSocket()
server.start(existingFD: launchdFD)

// MARK: - Idle Timeout

var idleSeconds: Int = 0
let idleTimer = DispatchSource.makeTimerSource(queue: .main)
idleTimer.schedule(deadline: .now() + 5, repeating: 5)
idleTimer.setEventHandler {
  if server.activeConnections == 0 {
    idleSeconds += 5
    if idleSeconds >= 30 {
      print("[Helper] Idle timeout (30s), exiting")
      pmsetManager.disable()
      lockScreenManager.hide()
      powerButtonMonitor.stop()
      exit(0)
    }
  } else {
    idleSeconds = 0
  }
}
idleTimer.resume()

// MARK: - Signal Handling

signal(SIGTERM, SIG_IGN)
let sigSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigSource.setEventHandler {
  print("[Helper] SIGTERM received, cleaning up")
  pmsetManager.disable()
  lockScreenManager.hide()
  powerButtonMonitor.stop()
  exit(0)
}
sigSource.resume()

print("[Helper] Started v\(helperVersion) (pid=\(getpid()))")

// MARK: - Run Loop

app.run()
