-- Power monitor: live battery watts in the menu bar, time-left predictions
-- from the last 10 min and 1 hr of drain, an alert on sustained high drain
-- naming the top processes, and a per-minute CSV log.

local M = {}

local SAMPLE_SECS = 15        -- battery sample interval
local TOP_SECS = 60           -- process sample + log interval
local HISTORY_SECS = 60 * 60  -- keep 1 hr of samples
local ALERT_WATTS = 20        -- alert when the 5-min average is above this,
local ALERT_WINDOW = 5 * 60
local SPIKE_WATTS = 35        -- or straight away when the 1-min average is above this
local ESCALATE_WATTS = 10     -- re-alert if drain climbs this far past the last alert
local ALERT_COOLDOWN = 30 * 60 -- otherwise remind at most every 30 min while it stays high
local ALERT_RESET_WATTS = 15  -- episode ends once the 5-min average falls below this
local WARN_WATTS = 15         -- menu bar text turns orange (1-min average)...
local HIGH_WATTS = 25         -- ...and red
local LOG_DIR = os.getenv("HOME") .. "/.hammerspoon/power-logs"

local samples = {}   -- { t, watts, mah }
local topProcs = {}  -- { { name, power } }
local totalPower = 0 -- Energy Impact summed over every process, for the % view
local lastAlert, lastAlertWatts = 0, 0
local ICON_ONLY_KEY = "powermon.iconOnly"
local iconOnly = hs.settings.get(ICON_ONLY_KEY) == true -- hide watts/time; icon still turns orange/red
local SHOW_PERCENT_KEY = "powermon.showPercent"
local showPercent = hs.settings.get(SHOW_PERCENT_KEY) == true -- process list as share of total
local updateTitle
local menu, sampleTimer, topTimer, sleepWatcher

-- hs.battery.amperage() can come back as an unsigned wraparound of a negative value.
local function amps()
  local a = hs.battery.amperage() or 0
  if a > 2 ^ 31 then a = a - 2 ^ 64 end
  return a
end

local function onBattery()
  return hs.battery.powerSource() == "Battery Power"
end

-- On AC the battery current is ~0 or charging, so battery-side watts say nothing
-- about the Mac. The battery controller's PowerTelemetryData has SystemPowerIn,
-- what comes in from the charger (mW). What the Mac uses is that minus what goes
-- into the battery, taken from the battery's own current and voltage. Not from
-- SystemLoad/BatteryPower: BatteryPower flips sign when charging starts, and
-- SystemLoad then adds the charging power instead of subtracting it (77 W
-- reported for ~13 W of real use).
local function acTelemetry()
  local t = (hs.battery._appleSmartBattery() or {}).PowerTelemetryData
  if not t or not t.SystemPowerIn then return nil end
  local wallIn = t.SystemPowerIn / 1000
  local charging = amps() * (hs.battery.voltage() or 0) / 1e6 -- negative if the battery is helping
  return { wallIn = wallIn, charging = charging, load = math.max(0, wallIn - charging) }
end

-- Watts the Mac is using: battery draw on battery, charger telemetry on AC.
local function currentWatts()
  if not onBattery() then
    local t = acTelemetry()
    return t and t.load or 0
  end
  return math.abs(amps()) * (hs.battery.voltage() or 0) / 1e6
end

-- Average watts and mA over the trailing window; nil if there is too little data.
-- `covered` is how many seconds the samples actually span.
local function average(window)
  local now = os.time()
  local sumW, sumA, n, oldest = 0, 0, 0, now
  for _, s in ipairs(samples) do
    if now - s.t <= window then
      sumW, sumA, n = sumW + s.watts, sumA + s.ma, n + 1
      oldest = math.min(oldest, s.t)
    end
  end
  if n < 2 then return nil end
  return sumW / n, sumA / n, now - oldest
end

local function timeLeft(avgMa)
  if not avgMa or avgMa <= 0 then return nil end
  return (hs.battery.capacity() or 0) / avgMa * 3600
end

-- Energy left in the battery: remaining charge times the present voltage.
local function fmtPercent(pct)
  local wh = (hs.battery.capacity() or 0) * (hs.battery.voltage() or 0) / 1e6
  if wh <= 0 then return string.format("%d%%", pct) end
  return string.format("%d%% (%.1f Wh)", pct, wh)
end

local function fmtDuration(secs)
  if not secs then return "–" end
  local h = math.floor(secs / 3600)
  local m = math.floor((secs % 3600) / 60)
  return string.format("%d:%02d", h, m)
end

local function fmtCovered(covered, window)
  -- Flag predictions built on less data than their nominal window.
  if covered >= window * 0.9 then return "" end
  return string.format(" (only %d min of data)", math.max(1, math.floor(covered / 60)))
end

local function topSummary(n)
  local parts = {}
  for i = 1, math.min(n, #topProcs) do
    parts[#parts + 1] = string.format("%s %.0f", topProcs[i].name, topProcs[i].power)
  end
  return table.concat(parts, ", ")
end

local function buildMenu()
  local items = {}
  -- Info rows stay enabled (just inert): disabled items render too faded to read.
  local function add(title, fn) items[#items + 1] = { title = title, fn = fn } end

  local pct = hs.battery.percentage() or 0
  if onBattery() then
    add(string.format("Now: %.1f W  ·  %s", currentWatts(), fmtPercent(pct)))
    for _, w in ipairs({ { 10 * 60, "10 min" }, { 60 * 60, "1 hr" } }) do
      local avgW, avgMa, covered = average(w[1])
      if avgW then
        add(string.format("Last %s: %.1f W avg  →  %s left%s",
          w[2], avgW, fmtDuration(timeLeft(avgMa)), fmtCovered(covered, w[1])))
      else
        add(string.format("Last %s: collecting…", w[2]))
      end
    end
    add("macOS estimate: " .. fmtDuration((hs.battery.timeRemaining() or -1) > 0 and hs.battery.timeRemaining() * 60 or nil))
  else
    local t = acTelemetry()
    if t then
      add(string.format("On AC  ·  %s", fmtPercent(pct)))
      add(string.format("Mac using: %.1f W", t.load))
      local avgW, _, covered = average(10 * 60)
      add(avgW and string.format("Mac using, last 10 min: %.1f W avg%s", avgW, fmtCovered(covered, 10 * 60))
        or "Mac using, last 10 min: collecting…")
      if t.charging >= 0.5 then
        add(string.format("Charging battery: %.1f W", t.charging))
      elseif t.charging <= -0.5 then
        add(string.format("Battery helping charger: %.1f W", -t.charging))
      end
      add(string.format("From charger: %.1f W", t.wallIn))
    else
      add(string.format("On AC  ·  %s%s", fmtPercent(pct), hs.battery.isCharging() and " (charging)" or ""))
    end
  end

  add("-")
  add(showPercent and "Top energy users (share of all process activity):"
    or "Top energy users (Energy Impact score):")
  if #topProcs == 0 then add("   sampling…") end
  -- Right-aligned tab stop lines the numbers up despite the proportional font.
  local rowStyle = {
    font = { name = ".AppleSystemUIFont", size = 14 },
    paragraphStyle = { tabStops = { { location = 340, tabStopType = "right" } } },
  }
  for i = 1, math.min(8, #topProcs) do
    local p = topProcs[i]
    local value = showPercent and totalPower > 0 and string.format("%.0f%%", p.power / totalPower * 100)
      or string.format("%.1f", p.power)
    add(hs.styledtext.new("   " .. p.name .. "\t" .. value, rowStyle))
  end
  add("-")
  items[#items + 1] = { title = "Icon only in menu bar", checked = iconOnly, fn = function()
    iconOnly = not iconOnly
    hs.settings.set(ICON_ONLY_KEY, iconOnly)
    updateTitle()
  end }
  items[#items + 1] = { title = "Show processes as % of total", checked = showPercent, fn = function()
    showPercent = not showPercent
    hs.settings.set(SHOW_PERCENT_KEY, showPercent)
    -- Menus always close on click; reopen it under the icon so the two views can be compared.
    -- menu:frame() flips y against the focused screen but popupMenu flips against
    -- the primary one, so with several displays it lands in the wrong place.
    -- Flip the raw Cocoa frame against the primary screen instead.
    hs.timer.doAfter(0.05, function()
      local f = menu:_frame()
      local h = hs.screen.primaryScreen():fullFrame().h
      menu:popupMenu({ x = f.x, y = h - f.y })
    end)
  end }
  add("Open log folder", function() hs.execute("open " .. LOG_DIR) end)
  add("Open Activity Monitor", function() hs.application.launchOrFocus("Activity Monitor") end)
  return items
end

-- 30% larger than the 13pt menu bar font so the glyph doesn't look tiny;
-- the bigger font rides high, so drop the baseline to re-centre it.
local function glyph(color)
  return hs.styledtext.new("⚡︎", {
    font = { name = ".AppleSystemUIFont", size = 17 },
    baselineOffset = -2,
    color = color,
  })
end

updateTitle = function()
  -- On AC just the plain icon: draw there costs no battery. Watts are in the menu.
  if not onBattery() then
    menu:setTitle(glyph())
    return
  end
  -- Colour by the 1-min average so a brief spike doesn't flash the bar.
  local recent = average(60) or currentWatts()
  local color = recent >= HIGH_WATTS and { hex = "#FF453A" }
    or recent >= WARN_WATTS and { hex = "#FF9F0A" } or nil
  if iconOnly then
    menu:setTitle(glyph(color))
    return
  end
  local _, avgMa = average(10 * 60)
  local left = timeLeft(avgMa)
  local text = string.format("%.0fW%s", currentWatts(), left and (" " .. fmtDuration(left)) or "")
  if color then
    menu:setTitle(hs.styledtext.new(text, { font = { name = ".AppleSystemUIFont", size = 13 }, color = color }))
  else
    menu:setTitle(text)
  end
end

local function sample()
  local now = os.time()
  -- The gauge reads 0 mA for ~30 s after unplugging; those zeros would drag the averages down.
  local ma = math.abs(amps())
  if onBattery() and ma > 0 then
    samples[#samples + 1] = { t = now, watts = currentWatts(), ma = ma }
  elseif not onBattery() and acTelemetry() then
    -- ma = 0 keeps AC samples out of time-left; history resets on plug/unplug anyway.
    samples[#samples + 1] = { t = now, watts = currentWatts(), ma = 0 }
  end
  while samples[1] and now - samples[1].t > HISTORY_SECS do table.remove(samples, 1) end
  updateTitle()
end

local function writeLog()
  hs.fs.mkdir(LOG_DIR)
  local path = LOG_DIR .. "/" .. os.date("%Y-%m") .. ".csv"
  local isNew = hs.fs.attributes(path) == nil
  local f = io.open(path, "a")
  if not f then return end
  if isNew then f:write("time,percent,source,watts,avg10m_watts,top_processes\n") end
  local avg10 = average(10 * 60)
  f:write(string.format("%s,%d,%s,%.1f,%s,\"%s\"\n",
    os.date("%Y-%m-%d %H:%M:%S"), hs.battery.percentage() or 0,
    onBattery() and "battery" or "ac", currentWatts(),
    avg10 and string.format("%.1f", avg10) or "", topSummary(5)))
  f:close()
end

-- Returns the watts to alert about, or nil. Alerts on sustained drain (5-min
-- average) or a spike (1-min average); within one high-drain episode, repeats
-- only if drain climbs ESCALATE_WATTS past the last alert or ALERT_COOLDOWN passes.
local function alertWatts(avg5, covered5, avg1, now)
  if avg5 and avg5 < ALERT_RESET_WATTS then lastAlert, lastAlertWatts = 0, 0 end
  local sustained = avg5 and covered5 >= ALERT_WINDOW * 0.8 and avg5 >= ALERT_WATTS and avg5
  local spike = avg1 and avg1 >= SPIKE_WATTS and avg1
  local watts = math.max(sustained or 0, spike or 0)
  if watts == 0 then return nil end
  local escalated = watts >= lastAlertWatts + ESCALATE_WATTS
  if not escalated and now - lastAlert < ALERT_COOLDOWN then return nil end
  lastAlert, lastAlertWatts = now, watts
  return watts, spike and not sustained
end

local function maybeAlert()
  if not onBattery() then return end
  local avg5, _, covered5 = average(ALERT_WINDOW)
  local watts, isSpike = alertWatts(avg5, covered5, average(60), os.time())
  if not watts then return end
  hs.notify.new({
    title = string.format(isSpike and "Battery drain spike: %.0f W" or "High battery drain: %.0f W", watts),
    informativeText = "Top: " .. topSummary(3),
    withdrawAfter = 0,
  }):send()
end

-- top truncates names to 16 chars and labels simulator processes vaguely, so
-- resolve each pid's full path for a readable name.
local function friendlyName(pid, fallback)
  local path = hs.execute("/bin/ps -p " .. pid .. " -o comm= 2>/dev/null"):gsub("%s+$", "")
  if path == "" then return fallback end
  local app = path:match("([^/]+)%.app/") -- outermost .app bundle
  local base = path:match("([^/]+)$")
  if path:find("CoreSimulator") or path:find("simruntime") then
    return "iOS Simulator: " .. base
  end
  if app and not base:find(app, 1, true) then return app .. " (" .. base .. ")" end
  return base
end

local function sampleTop()
  -- The first top sample has no power baseline, so take two and parse the last.
  hs.task.new("/usr/bin/top", function(_, out)
    local block = out:match(".*PID%s+POWER%s+COMMAND[^\n]*\n(.*)$") or ""
    local procs, total = {}, 0
    for pid, power, cmd in block:gmatch("(%d+)%s+([%d%.]+)%s+([^\n]*)") do
      power, cmd = tonumber(power), cmd:gsub("%s+$", "")
      -- Skip top itself: it's our measurement overhead, not real load.
      if power and cmd ~= "top" then
        total = total + power
        if power >= 0.5 and #procs < 12 then
          procs[#procs + 1] = { pid = pid, power = power, name = cmd }
        end
      end
    end
    for _, p in ipairs(procs) do p.name = friendlyName(p.pid, p.name) end
    topProcs, totalPower = procs, total
    writeLog()
    maybeAlert()
  end, { "-l", "2", "-s", "2", "-o", "power", "-n", "1000", "-stats", "pid,power,command" }):start()
end

function M.start()
  menu = hs.menubar.new()
  menu:setMenu(buildMenu)
  -- Samples from before a sleep or a power-source change would skew the averages.
  sleepWatcher = hs.caffeinate.watcher.new(function(event)
    if event == hs.caffeinate.watcher.systemDidWake then samples = {} end
  end):start()
  M.batteryWatcher = hs.battery.watcher.new(function()
    local src = hs.battery.powerSource()
    if src ~= M.lastSource then samples = {} end
    M.lastSource = src
    updateTitle()
  end):start()
  M.lastSource = hs.battery.powerSource()
  sampleTimer = hs.timer.doEvery(SAMPLE_SECS, sample)
  topTimer = hs.timer.doEvery(TOP_SECS, sampleTop)
  sample()
  sampleTop()
end

M.debug = { average = average, alertWatts = alertWatts, samples = function() return samples end, top = function() return topProcs end, total = function() return totalPower end }

return M
