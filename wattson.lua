-- Wattson: live battery watts in the menu bar, time-left predictions from the
-- last 10 min and 1 hr of drain, a "quit to save battery" list that groups
-- processes by app, an alert on sustained high drain, auto-quitting heavy apps
-- at low battery, and a per-minute CSV log.

local M = {}

local NAME = "Wattson"
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
local IDLE_WATTS = 3          -- display + idle chip draw no process accounts for; excluded from per-app estimates
local CLOSE_MIN_SHARE = 0.02  -- list apps using at least 2% of process activity
local LOW_BATTERY_PCT = 20    -- auto-quit heavy apps at or below this...
local LOW_BATTERY_REARM = 25  -- ...once per discharge; re-arms when charged past this
local LOW_BATTERY_GRACE = 30  -- seconds to click the notification and keep them open
local LOG_DIR = os.getenv("HOME") .. "/.hammerspoon/power-logs"

local samples = {}   -- { t, watts, mah }
local topProcs = {}  -- { { name, power } }
local groups = {}    -- topProcs folded by owning app: { key, label, kind, power, hint?, bundlePath? }
local totalPower = 0 -- Energy Impact summed over every process, for the % view
local lastAlert, lastAlertWatts = 0, 0
local lowBatteryFired, lowBatteryTimer = false, nil
local ICON_ONLY_KEY = "powermon.iconOnly"
local iconOnly = hs.settings.get(ICON_ONLY_KEY) == true -- hide watts/time; icon still turns orange/red
local AUTO_QUIT_KEY = "powermon.autoQuit"
local autoQuit = hs.settings.get(AUTO_QUIT_KEY) ~= false -- on unless turned off
local HEAVY_APPS_KEY = "powermon.heavyApps"
local SIMULATOR_ID = "com.apple.iphonesimulator"
-- Apps quit automatically at LOW_BATTERY_PCT: { { label, bundleID } }, edited from the menu.
local heavyApps = hs.settings.get(HEAVY_APPS_KEY) or { { label = "Simulator", bundleID = SIMULATOR_ID } }
local updateTitle
local menu, sampleTimer, topTimer, sleepWatcher

-- Plain-English hints for processes that aren't apps you can quit.
local SYSTEM_HINTS = {
  WindowServer = "draws the screen: fewer windows/animations, lower brightness",
  kernel_task = "macOS core; also climbs when the Mac is hot",
  launchd = "macOS process manager",
  coreaudiod = "audio: something is playing or recording",
  mds = "Spotlight indexing", mds_stores = "Spotlight indexing",
  backupd = "Time Machine backup",
  photoanalysisd = "Photos library analysis", mediaanalysisd = "Photos library analysis",
  cloudd = "iCloud sync", bird = "iCloud Drive sync", fileproviderd = "cloud file sync",
  softwareupdated = "macOS update download",
  sysmond = "Activity Monitor's data feed",
  ["com.apple.WebKit.WebContent"] = "web pages: Safari tabs or apps showing web content",
  ["com.apple.WebKit.GPU"] = "web page graphics: Safari or apps showing web content",
}

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

local function fmtDuration(secs)
  if not secs then return "–" end
  local h = math.floor(secs / 3600)
  local m = math.floor((secs % 3600) / 60)
  return string.format("%d:%02d", h, m)
end

-- Energy left in the battery: remaining charge times the present voltage.
local function fmtPercent(pct)
  local wh = (hs.battery.capacity() or 0) * (hs.battery.voltage() or 0) / 1e6
  if wh <= 0 then return string.format("%d%%", pct) end
  return string.format("%d%% (%.1f Wh)", pct, wh)
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

local function share(g)
  return totalPower > 0 and g.power / totalPower or 0
end

local function groupSummary(n)
  local parts = {}
  for i = 1, math.min(n, #groups) do
    parts[#parts + 1] = string.format("%s %.0f%%", groups[i].label, share(groups[i]) * 100)
  end
  return table.concat(parts, ", ")
end

-- Rough watts an app accounts for (its share of drain above idle) and the
-- battery time quitting it would buy. Energy Impact isn't watts, so this is a guide.
local function savings(g)
  if not onBattery() or totalPower <= 0 then return nil end
  local avgW = average(10 * 60) or currentWatts()
  local w = share(g) * math.max(0, avgW - IDLE_WATTS)
  local wh = (hs.battery.capacity() or 0) * (hs.battery.voltage() or 0) / 1e6
  if avgW <= 0 or avgW - w <= 0 then return w, nil end
  return w, (wh / (avgW - w) - wh / avgW) * 3600
end

-- Group processes by the app the user would actually quit; everything else is
-- macOS or command-line work, labelled with a hint instead.
local function classify(path, cmd)
  if path:find("CoreSimulator", 1, true) or path:find("simruntime", 1, true) or path:find("Simulator.app/", 1, true) then
    return { key = "simulator", label = "iOS Simulator", kind = "simulator" }
  end
  local base = path:match("([^/]+)$") or cmd
  local bundle = path:match("^(.-%.app)/") -- outermost .app bundle
  -- Only bundles in an Applications folder are apps you'd quit; others (e.g.
  -- Claude Code's CLI, shipped as claude.app in Application Support) are helpers.
  local inApps = bundle and (bundle:find("^/Applications/") or bundle:find("^/System/Applications/")
    or bundle:find("^" .. os.getenv("HOME") .. "/Applications/"))
  if path:find("claude%-code") and base == "claude" then
    return { key = "claude-code", label = "Claude Code", kind = "other", hint = "CLI sessions: end them in their terminal" }
  end
  if inApps then
    local label = bundle:match("([^/]+)%.app$")
    if label == "Hammerspoon" then
      return { key = bundle, label = "Hammerspoon", kind = "other", hint = "runs this monitor" }
    end
    return { key = bundle, label = label, kind = "app", bundlePath = bundle }
  end
  local hint = SYSTEM_HINTS[base] or (base:find("^mdworker") and "Spotlight indexing")
  if not hint then
    local isSystem = path:find("^/System/") or path:find("^/usr/") or path:find("^/sbin/")
      or path:find("^/bin/") or path:find("^/Library/Apple/")
    hint = isSystem and "macOS background process"
      or bundle and "background helper for another app"
      or "command-line process: stop it in its terminal"
  end
  return { key = base, label = base, kind = "other", hint = hint }
end

local function quitSimulator()
  local app = hs.application.get("com.apple.iphonesimulator")
  if app then app:kill() end
  -- Booted devices keep running after Simulator.app quits.
  hs.task.new("/usr/bin/xcrun", nil, { "simctl", "shutdown", "all" }):start()
end

local function simulatorRunning()
  if hs.application.get("com.apple.iphonesimulator") then return true end
  local _, ok = hs.execute("/usr/bin/pgrep -q launchd_sim")
  return ok == true
end

local function quitBundleID(id)
  for _, app in ipairs(hs.application.applicationsForBundleID(id)) do app:kill() end
end

local function quitGroup(g)
  if g.kind == "simulator" then return quitSimulator() end
  local info = hs.application.infoForBundlePath(g.bundlePath)
  if info and info.CFBundleIdentifier then quitBundleID(info.CFBundleIdentifier) end
end

local function heavyRunning(app)
  if app.bundleID == SIMULATOR_ID then return simulatorRunning() end
  return #hs.application.applicationsForBundleID(app.bundleID) > 0
end

local function quitHeavy(app)
  if app.bundleID == SIMULATOR_ID then return quitSimulator() end
  quitBundleID(app.bundleID)
end

local function saveHeavyApps()
  hs.settings.set(HEAVY_APPS_KEY, heavyApps)
end

local function addHeavyApp()
  local picked = hs.dialog.chooseFileOrFolder("Quit this app at low battery", "/Applications", true, false, false, { "app" })
  local info = picked and picked["1"] and hs.application.infoForBundlePath(picked["1"])
  if not (info and info.CFBundleIdentifier) then return end
  for _, a in ipairs(heavyApps) do
    if a.bundleID == info.CFBundleIdentifier then return end
  end
  heavyApps[#heavyApps + 1] = {
    label = info.CFBundleDisplayName or info.CFBundleName or picked["1"]:match("([^/]+)%.app$"),
    bundleID = info.CFBundleIdentifier,
  }
  saveHeavyApps()
end

local function labels(apps)
  local names = {}
  for _, a in ipairs(apps) do names[#names + 1] = a.label end
  return table.concat(names, " and ")
end

-- Warn, then quit `apps` after `grace` seconds unless the notification is clicked.
local function scheduleQuit(apps, grace)
  if lowBatteryTimer then return end
  local note = hs.notify.new(function()
    if not lowBatteryTimer then return end
    lowBatteryTimer:stop()
    lowBatteryTimer = nil
    hs.notify.new({ title = NAME .. ": kept open", informativeText = labels(apps) .. " will stay open." }):send()
  end, {
    title = string.format("%s: battery at %d%%", NAME, hs.battery.percentage() or 0),
    informativeText = string.format("Quitting %s in %d s. Click to keep open.", labels(apps), grace),
    hasActionButton = true, actionButtonTitle = "Keep open",
    withdrawAfter = 0,
  }):send()
  lowBatteryTimer = hs.timer.doAfter(grace, function()
    lowBatteryTimer = nil
    note:withdraw()
    for _, a in ipairs(apps) do quitHeavy(a) end
    hs.notify.new({ title = NAME .. ": quit " .. labels(apps), informativeText = "To save battery." }):send()
  end)
end

local function checkLowBattery()
  local pct = hs.battery.percentage() or 100
  if not onBattery() or pct > LOW_BATTERY_REARM then lowBatteryFired = false end
  if not onBattery() then
    if lowBatteryTimer then lowBatteryTimer:stop(); lowBatteryTimer = nil end
    return
  end
  if lowBatteryFired or not autoQuit or pct > LOW_BATTERY_PCT then return end
  lowBatteryFired = true
  local running = {}
  for _, a in ipairs(heavyApps) do
    if heavyRunning(a) then running[#running + 1] = a end
  end
  if #running > 0 then scheduleQuit(running, LOW_BATTERY_GRACE) end
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

  -- Right-aligned tab stop lines the numbers up despite the proportional font.
  local function row(text, value, color)
    return hs.styledtext.new("   " .. text .. "\t", {
      font = { name = ".AppleSystemUIFont", size = 14 },
      paragraphStyle = { tabStops = { { location = 340, tabStopType = "right" } } },
    }) .. hs.styledtext.new(value, { font = { name = ".AppleSystemUIFont", size = 14 }, color = color })
  end
  -- Name and value on one line, the explanation underneath in small grey.
  local function hintRow(text, hint, value)
    return row(text, value) .. hs.styledtext.new("\n   " .. hint, {
      font = { name = ".AppleSystemUIFont", size = 11 },
      color = { list = "System", name = "secondaryLabelColor" },
    })
  end

  add("-")
  add(onBattery() and "Quit to save battery (click to quit):" or "Biggest energy users (click to quit):")
  if #groups == 0 then add("   sampling…") end
  local shown, other, otherPower = 0, {}, 0
  for _, g in ipairs(groups) do
    if g.kind == "other" then
      other[#other + 1], otherPower = g, otherPower + g.power
    elseif shown < 6 and share(g) >= CLOSE_MIN_SHARE then
      shown = shown + 1
      local w, gained = savings(g)
      local value, color
      if w then
        value = string.format("≈%.1f W%s", w, gained and gained >= 60 and ("  +" .. fmtDuration(gained)) or "")
        color = w >= 5 and { hex = "#FF453A" } or w >= 2 and { hex = "#FF9F0A" } or nil
      else
        value = string.format("%.0f%%", share(g) * 100)
      end
      add(row(g.label, value, color), function() quitGroup(g) end)
    end
  end
  if #groups > 0 and shown == 0 then add("   Nothing worth quitting right now") end

  if #other > 0 then
    local sub = {}
    for _, g in ipairs(other) do
      -- Rows that would read 0% are noise.
      if #sub == 12 or share(g) < 0.005 then break end
      sub[#sub + 1] = { title = hintRow(g.label, g.hint, string.format("%.0f%%", share(g) * 100)) }
    end
    items[#items + 1] = {
      title = string.format("macOS & background (not apps): %.0f%%", totalPower > 0 and otherPower / totalPower * 100 or 0),
      menu = sub,
    }
  end
  local raw = {}
  for i = 1, #topProcs do
    local p = topProcs[i]
    raw[#raw + 1] = { title = row(p.name, string.format("%.1f  ·  %.0f%%", p.power, totalPower > 0 and p.power / totalPower * 100 or 0)) }
  end
  if #raw > 0 then items[#items + 1] = { title = "All processes (Energy Impact)", menu = raw } end

  add("-")
  local lowMenu = {
    { title = string.format("Quit these apps at %d%%", LOW_BATTERY_PCT), checked = autoQuit, fn = function()
      autoQuit = not autoQuit
      hs.settings.set(AUTO_QUIT_KEY, autoQuit)
    end },
    { title = "-" },
  }
  if #heavyApps == 0 then lowMenu[#lowMenu + 1] = { title = "   No apps yet", disabled = true } end
  for i, a in ipairs(heavyApps) do
    lowMenu[#lowMenu + 1] = { title = "   " .. a.label, menu = {
      { title = "Remove from list", fn = function()
        table.remove(heavyApps, i)
        saveHeavyApps()
      end },
    } }
  end
  lowMenu[#lowMenu + 1] = { title = "-" }
  lowMenu[#lowMenu + 1] = { title = "Add app…", fn = addHeavyApp }
  items[#items + 1] = { title = "Low battery", menu = lowMenu }
  items[#items + 1] = { title = "Icon only in menu bar", checked = iconOnly, fn = function()
    iconOnly = not iconOnly
    hs.settings.set(ICON_ONLY_KEY, iconOnly)
    updateTitle()
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
  checkLowBattery()
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
    title = string.format(isSpike and "%s: drain spike %.0f W" or "%s: high drain %.0f W", NAME, watts),
    informativeText = "Top: " .. groupSummary(3),
    withdrawAfter = 0,
  }):send()
end

-- top truncates names to 16 chars and labels simulator processes vaguely, so
-- resolve every pid's full path in one ps call.
local function processPaths()
  local paths = {}
  for pid, path in hs.execute("/bin/ps -axo pid=,comm="):gmatch("(%d+) ([^\n]+)") do
    paths[pid] = path:gsub("%s+$", "")
  end
  return paths
end

local function sampleTop()
  -- The first top sample has no power baseline, so take two and parse the last.
  hs.task.new("/usr/bin/top", function(_, out)
    local block = out:match(".*PID%s+POWER%s+COMMAND[^\n]*\n(.*)$") or ""
    local paths = processPaths()
    local procs, folded, byKey, total = {}, {}, {}, 0
    for pid, power, cmd in block:gmatch("(%d+)%s+([%d%.]+)%s+([^\n]*)") do
      power, cmd = tonumber(power), cmd:gsub("%s+$", "")
      -- Skip top itself: it's our measurement overhead, not real load.
      if power and power > 0 and cmd ~= "top" then
        total = total + power
        local path = paths[pid] or cmd
        local g = classify(path, cmd)
        local agg = byKey[g.key]
        if not agg then
          agg = g
          agg.power = 0
          byKey[g.key], folded[#folded + 1] = agg, agg
        end
        agg.power = agg.power + power
        if power >= 0.5 and #procs < 20 then
          local base = path:match("([^/]+)$") or cmd
          local name = g.kind == "simulator" and ("iOS Simulator: " .. base)
            or g.kind == "app" and not base:find(g.label, 1, true) and (g.label .. " (" .. base .. ")")
            or base
          procs[#procs + 1] = { pid = pid, power = power, name = name }
        end
      end
    end
    table.sort(folded, function(a, b) return a.power > b.power end)
    table.sort(procs, function(a, b) return a.power > b.power end)
    topProcs, groups, totalPower = procs, folded, total
    writeLog()
    maybeAlert()
  end, { "-l", "2", "-s", "2", "-o", "power", "-n", "1000", "-stats", "pid,power,command" }):start()
end

function M.start()
  menu = hs.menubar.new()
  menu:setTooltip(NAME)
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
    checkLowBattery()
  end):start()
  M.lastSource = hs.battery.powerSource()
  sampleTimer = hs.timer.doEvery(SAMPLE_SECS, sample)
  topTimer = hs.timer.doEvery(TOP_SECS, sampleTop)
  sample()
  sampleTop()
end

M.debug = {
  average = average, alertWatts = alertWatts, classify = classify, buildMenu = buildMenu,
  scheduleQuit = scheduleQuit, heavyApps = function() return heavyApps end, heavyRunning = heavyRunning,
  samples = function() return samples end, top = function() return topProcs end,
  groups = function() return groups end, total = function() return totalPower end,
  menubar = function() return menu end,
}

return M
