<p align="center">
  <img src="Resources/AppIcon.png" width="128" height="128" alt="LidGuard icon">
</p>

<h1 align="center">LidGuard Helper</h1>

<p align="center">
  <strong>Privileged helper daemon for <a href="https://github.com/Erel3/lidguard">LidGuard</a></strong>
</p>

<p align="center">
  <a href="https://github.com/Erel3/lidguard-helper/releases/latest"><img src="https://img.shields.io/github/v/release/Erel3/lidguard-helper?style=flat-square&color=blue" alt="Release"></a>
  <img src="https://img.shields.io/badge/platform-macOS_14%2B-black?style=flat-square" alt="Platform">
  <img src="https://img.shields.io/badge/swift-6.2-orange?style=flat-square" alt="Swift">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/Erel3/lidguard-helper?style=flat-square" alt="License"></a>
</p>

<p align="center">
  Silent background daemon managed by <code>launchd</code> with on-demand socket activation.<br>
  Handles features that require elevated privileges or private APIs.
</p>

---

## Features

🛡️ **Clamshell Sleep Prevention** — `sudo pmset disablesleep` via sudoers\
🔒 **Lock Screen Overlay** — fullscreen "STOLEN DEVICE" window via SkyLight private API\
⚡ **Power Button Detection** — NSEvent system-defined events (requires Accessibility)\
🤚 **Motion Detection** — tilt + walking detector reading the Apple Silicon accelerometer (Bosch BMI286 IMU) via IOKit HID at ~800 Hz; root-only, hence run from the helper

## How It Works

```
LidGuard app ──TCP──▶ launchd ──socket activation──▶ lidguard-helper
                       port 51423                      ├─ pmset
                       JSON + shared secret auth       ├─ SkyLight overlay
                                                       ├─ power button monitor
                                                       └─ HID accelerometer (motion)

Idle 30s → daemon exits → launchd restarts on next connection
```

Motion detector decimates the raw ~800 Hz stream to ~20 Hz, calibrates a baseline gravity vector at start, then fires on either of two paths: **tilt** (gravity-vector angle vs. baseline exceeds threshold and sustains) or **walking** (RMS of `sample - baseline` over a sliding window exceeds threshold). A cooldown after each fire prevents re-reporting a single event.

The daemon is **not always running**. `launchd` listens on port 51423 and starts the daemon only when the main app connects. Zero resource usage when LidGuard isn't active.

## Install

### Build from Source

```bash
git clone https://github.com/Erel3/lidguard-helper.git
cd lidguard-helper
just build          # Swift release build
just install        # install binary + LaunchAgent, load via launchctl
just uninstall      # unload and remove
just lint           # run swiftlint
```

### Install Location

| What | Where |
|:-----|:------|
| Binary | `~/Library/Application Support/LidGuard/lidguard-helper` |
| LaunchAgent | `~/Library/LaunchAgents/com.lidguard.helper.plist` |
| Shared secret | `~/Library/Application Support/LidGuard/.ipc-secret` |
| Sudoers | `/etc/sudoers.d/lidguard` (set up by main app or PKG installer) |

## IPC Protocol

Newline-delimited JSON over localhost TCP port 51423.

### Commands (App → Daemon)

| Command | Description |
|:--------|:------------|
| `auth` | Authenticate with shared secret (must be first) |
| `enable_pmset` / `disable_pmset` | Toggle clamshell sleep prevention |
| `show_lock_screen` / `hide_lock_screen` | Toggle lock screen overlay (carries `contactName`/`contactPhone`/`message`) |
| `enable_power_button` / `disable_power_button` | Toggle power button monitoring |
| `start_motion_monitoring` / `stop_motion_monitoring` | Toggle accelerometer motion detection |
| `get_status` | Query current state of all features |

### Events (Daemon → App)

| Event | Description |
|:------|:------------|
| `auth_result` | Authentication success/failure (carries daemon `version`) |
| `status` | Current state of pmset, lock screen, power button, motion (incl. `motionSupported` and per-start `motionSession` ID) |
| `power_button_pressed` | Power button was pressed |
| `motion_detected` | Motion fired; carries `motionDetail` (tilt/walking) and `motionSession` (drops events from earlier sessions across helper restarts) |
| `error` | Error message |

## Permissions

| Permission | Why |
|:-----------|:----|
| **Accessibility** | Power button detection via NSEvent |
| **Sudoers** | `pmset disablesleep` requires root |
| **Root (via launchd)** | IOKit HID accelerometer access for motion detection |

## License

[MIT](LICENSE)
