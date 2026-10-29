-- Power monitor: live battery watts in the menu bar, time-left predictions
-- from the last 10 min and 1 hr of drain, an alert on sustained high drain
-- naming the top processes, and a per-minute CSV log.

local M = {}

local SAMPLE_SECS = 15        -- battery sample interval
local TOP_SECS = 60           -- process sample + log interval
local HISTORY_SECS = 60 * 60  -- keep 1 hr of samples
local ALERT_WATTS = 20        -- alert when the 5-min average is above this...
local ALERT_WINDOW = 5 * 60
local ALERT_COOLDOWN = 30 * 60 -- ...at most once per 30 min
local LOG_DIR = os.getenv("HOME") .. "/.hammerspoon/power-logs"

local samples = {}   -- { t, watts, mah }
local topProcs = {}  -- { { name, power } }
local lastAlert = 0
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

local function currentWatts()
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
  local function add(title, fn) items[#items + 1] = { title = title, fn = fn, disabled = not fn } end

  local pct = hs.battery.percentage() or 0
  if onBattery() then
    add(string.format("Now: %.1f W  ·  %d%%", currentWatts(), pct))
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
    add(string.format("On AC  ·  %d%%%s", pct, hs.battery.isCharging() and " (charging)" or ""))
  end

  add("-")
  add("Top energy users (Energy Impact):")
  if #topProcs == 0 then add("   sampling…") end
  for i = 1, math.min(8, #topProcs) do
    add(string.format("   %-28s %5.1f", topProcs[i].name, topProcs[i].power))
  end
  add("-")
  add("Open log folder", function() hs.execute("open " .. LOG_DIR) end)
  add("Open Activity Monitor", function() hs.application.launchOrFocus("Activity Monitor") end)
  return items
end

local function updateTitle()
  if not onBattery() then
    -- 30% larger than the 13pt menu bar font so the glyph doesn't look tiny;
    -- the bigger font rides high, so drop the baseline to re-centre it.
    menu:setTitle(hs.styledtext.new("⚡︎", {
      font = { name = ".AppleSystemUIFont", size = 17 },
      baselineOffset = -2,
    }))
    return
  end
  local _, avgMa = average(10 * 60)
  local left = timeLeft(avgMa)
  menu:setTitle(string.format("%.0fW%s", currentWatts(), left and (" " .. fmtDuration(left)) or ""))
end

local function sample()
  local now = os.time()
  if onBattery() then
    samples[#samples + 1] = { t = now, watts = currentWatts(), ma = math.abs(amps()) }
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
  local avg10 = onBattery() and average(10 * 60) or nil
  f:write(string.format("%s,%d,%s,%.1f,%s,\"%s\"\n",
    os.date("%Y-%m-%d %H:%M:%S"), hs.battery.percentage() or 0,
    onBattery() and "battery" or "ac", onBattery() and currentWatts() or 0,
    avg10 and string.format("%.1f", avg10) or "", topSummary(5)))
  f:close()
end

local function maybeAlert()
  if not onBattery() or os.time() - lastAlert < ALERT_COOLDOWN then return end
  local avgW, _, covered = average(ALERT_WINDOW)
  if not avgW or covered < ALERT_WINDOW * 0.8 or avgW < ALERT_WATTS then return end
  lastAlert = os.time()
  hs.notify.new({
    title = string.format("High battery drain: %.0f W", avgW),
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
    local procs = {}
    for pid, power, cmd in block:gmatch("(%d+)%s+([%d%.]+)%s+([^\n]*)") do
      power, cmd = tonumber(power), cmd:gsub("%s+$", "")
      if power and power >= 0.5 and cmd ~= "top" then
        procs[#procs + 1] = { pid = pid, power = power, name = cmd }
      end
    end
    for _, p in ipairs(procs) do p.name = friendlyName(p.pid, p.name) end
    topProcs = procs
    writeLog()
    maybeAlert()
  end, { "-l", "2", "-s", "2", "-o", "power", "-n", "12", "-stats", "pid,power,command" }):start()
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

M.debug = { average = average, samples = function() return samples end, top = function() return topProcs end }

return M
