# Macbook Battery Monitor

A [Hammerspoon](https://www.hammerspoon.org/) module that shows what Activity Monitor and Battery settings don't: real battery draw in watts, how long the battery will last at your recent rate, and which processes are eating it — including helpers that Activity Monitor groups away (iOS Simulator, browser renderers, etc.).

No sudo, no dependencies beyond Hammerspoon.

## What it does
<img width="421" height="475" alt="Screenshot 2026-10-30 at 08 13 11" src="https://github.com/user-attachments/assets/d445d624-e12e-40f7-bb5b-672575b5fabb" />
<img width="421" height="500" alt="image" src="https://github.com/user-attachments/assets/7f9a5305-9b7b-41c5-ab4d-c1371c1bc82b" />


- **Menu bar:** live watts and time left at the last-10-minute rate, e.g. `17W 1:05`. Turns orange above 15 W and red above 25 W (1-min average). Shows a plain ⚡︎ on AC, since draw there costs no battery.
  - **Icon only** (toggle in the menu, remembered across reloads): hides the numbers and shows just ⚡︎, which still turns orange/red, so it's there when you need it without being a distraction.
- **Menu:**
  - current watts and battery %
  - average watts and predicted time left over the **last 10 min** and **last 1 hr**
  - macOS's own estimate, for comparison
  - on AC: what the Mac is using (now and 10-min average), what's going into the battery, and what's coming from the charger
  - top processes by energy impact, with full names (`iOS Simulator: SimMetalHost`, `Claude Helper (Renderer)`, …)
  - toggle to show each process as a % of all process activity instead of the raw score (the menu reopens so you can compare). Energy Impact is Apple's unitless score, and macOS has no per-process watts, so this is a share of process activity, not of battery: the display, radios and other hardware draw belong to no process.
- **Alerts:** a notification naming the top 3 processes when the 5-min average passes 20 W, or straight away when the 1-min average passes 35 W. Within one high-drain episode it re-alerts if drain climbs another 10 W, and otherwise reminds every 30 min; the episode resets once drain falls below 15 W.
- **Log:** one CSV line per minute in `~/.hammerspoon/power-logs/YYYY-MM.csv`: battery %, watts, 10-min average, top 5 processes.

History is cleared after sleep and on plug/unplug, so idle time doesn't make the estimate look better than it is.

## Install
**Copy this repo to your AI agent and tell it to install**

```bash
curl -o ~/.hammerspoon/powermon.lua https://raw.githubusercontent.com/optimisticnpc/macbook-battery-monitor/main/powermon.lua
```

Add to `~/.hammerspoon/init.lua`:

```lua
-- Global so its timers and watchers aren't garbage collected.
powermon = require("powermon")
powermon.start()
```

Then reload Hammerspoon.

## Configuration

Edit the constants at the top of `powermon.lua`:

| Constant | Default | Meaning |
| --- | --- | --- |
| `SAMPLE_SECS` | 15 | battery sample interval |
| `TOP_SECS` | 60 | process sample + log interval |
| `ALERT_WATTS` | 20 | sustained alert threshold (5-min average) |
| `SPIKE_WATTS` | 35 | spike alert threshold (1-min average) |
| `ESCALATE_WATTS` | 10 | re-alert when drain climbs this far past the last alert |
| `ALERT_COOLDOWN` | 30 min | reminder interval while drain stays high |
| `ALERT_RESET_WATTS` | 15 | episode ends below this (5-min average) |
| `WARN_WATTS` / `HIGH_WATTS` | 15 / 25 | orange / red menu bar text |
| `LOG_DIR` | `~/.hammerspoon/power-logs` | where CSV logs go |

## How it works

- Watts = battery current × voltage, from `hs.battery` (the same SMC numbers `ioreg -rn AppleSmartBattery` exposes).
- Time left = remaining mAh ÷ average current over the window.
- On AC, Mac usage = charger input (`SystemPowerIn` from the battery controller's `PowerTelemetryData`) minus battery charging power (current × voltage). Its own `SystemLoad` field isn't used: it reports the charging power with the wrong sign for a few seconds when charging starts.
- Processes come from `top -o power` (two samples, so the energy column has a baseline), with each pid resolved to its full path for a readable name.
