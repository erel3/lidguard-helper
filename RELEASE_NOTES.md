## Fixes

- **Your Mac could stay awake after LidGuard quit.** With lid-close sleep prevention on, the setting was never undone when the helper shut down — so closing the lid did nothing and the laptop kept running, and heating up, in your bag until the battery died. It is now always restored, both when the helper exits on its own and at logout.
- **Motion detection could stop working until you restarted the app.** A single failed sensor start disabled it permanently and hid the Motion toggle in Settings, even on hardware that supports it. It now retries, and only hides the toggle on Macs that genuinely have no motion sensor.
