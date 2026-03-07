# LidGuard Helper

A privileged helper daemon for [LidGuard](https://github.com/Erel3/lidguard), the macOS laptop theft protection app.

Pure CLI binary managed by `launchd`. Handles features that require elevated privileges or private APIs:

1. **Clamshell sleep prevention** — `sudo pmset disablesleep`
2. **Lock screen overlay** — SkyLight private API
3. **Power button detection** — requires Accessibility

## IPC

Communicates with the main app over localhost TCP (port 51423) using a JSON protocol with shared secret authentication.

## Installation

Distributed as a signed PKG installer. Installs to:
- `~/Library/Application Support/LidGuard/lidguard-helper`
- LaunchAgent plist for `launchd` management

## Requirements

- macOS 14.0+
- Swift 5.9

## Dependencies

- [SkyLightWindow](https://github.com/nicklama/SkyLightWindow) (SPM) — private API wrapper for fullscreen overlay windows
- Apple frameworks: IOKit, ApplicationServices, Security

## License

See [LICENSE](LICENSE).
