-- Foldback - Copyright (C) 2026 Franktree. Free software under the GNU General Public License v3.0 (see LICENSE).
-- Foldback - shared functions
-- Not an action. Loaded by the other Foldback scripts with dofile().
local r = reaper
local C = {}

C.VERSION = "0.5.0-mix"
C.res = r.GetResourcePath()
C.dir = C.res .. "/Foldback"
C.logdir = C.dir .. "/logs"
C.profdir = C.dir .. "/profiles"
C.script_dir = (debug.getinfo(1, "S").source or ""):match("^@?(.*[/\\])") or ""

-- Track tags (stored inside the project file, on the track)
C.KEY_STEM   = "P_EXT:FOLDBACK"        -- value = stem id, on CUE tracks
C.KEY_LISTEN = "P_EXT:FOLDBACK_LISTEN" -- on the CUE LISTEN track
C.KEY_TEST   = "P_EXT:FOLDBACK_TEST"   -- on temporary test tracks
C.KEY_VERB   = "P_EXT:FOLDBACK_VERB"   -- on the CUE VERB track
C.KEY_SEEN   = "P_EXT:FOLDBACK_SEEN"   -- on normal tracks once auto-assign has looked at them
C.KEY_NAME   = "P_EXT:FOLDBACK_NAME"   -- the track name auto-assign last looked at (to notice renames)
C.KEY_CLICK  = "P_EXT:FOLDBACK_CLICK"  -- on the click track (an ordinary track as far as sends go)
C.KEY_TALK   = "P_EXT:FOLDBACK_TALK"   -- on the TALKBACK track
C.KEY_AUTO   = "P_EXT:FOLDBACK_AUTO"   -- stem id of the cue send auto-assign made for this track

C.MONO_FX = { "JS:Foldback/Foldback_MonoSum", "Foldback mono sum" }
C.CLICK_FX = { "JS:Foldback/Foldback_Click", "Foldback click" }
C.LIMITER_FX = { "JS:Foldback/Foldback_Limiter", "Foldback limiter" }
C.TONE_FX = { "JS:Foldback/Foldback_TestTone", "Foldback test tone" }

C.SENDMODE_POSTFADER = 0
C.SENDMODE_PREFX = 1
C.SENDMODE_PREFADER_POSTFX = 3

---------------------------------------------------------------- stem colors
-- ui_color (from the profile) is the cue's color; color is the fallback.
function C.stem_color(s)
  return s.ui_color or s.color
end

---------------------------------------------------------------- utilities
function C.db2lin(db)
  if db <= -150 then return 0 end
  return 10 ^ (db / 20)
end

function C.lin2db(v)
  if v <= 0 then return -math.huge end
  return 20 * math.log(v, 10)
end

function C.fmtdb(db)
  if db == -math.huge or db < -150 then return "-inf" end
  return string.format("%.2f", db)
end

function C.name(tr)
  local _, n = r.GetTrackName(tr)
  return n
end

function C.guid(tr) return r.GetTrackGUID(tr) end

function C.get_ext(tr, key)
  local ok, v = r.GetSetMediaTrackInfo_String(tr, key, "", false)
  if ok and v ~= "" then return v end
  return nil
end

function C.set_ext(tr, key, v)
  r.GetSetMediaTrackInfo_String(tr, key, v, true)
end

function C.is_system(tr)
  return C.get_ext(tr, C.KEY_STEM) ~= nil
      or C.get_ext(tr, C.KEY_LISTEN) ~= nil
      or C.get_ext(tr, C.KEY_TEST) ~= nil
      or C.get_ext(tr, C.KEY_VERB) ~= nil
      or C.get_ext(tr, C.KEY_TALK) ~= nil
end

---------------------------------------------------------------- logging
function C.new_log(filename)
  r.RecursiveCreateDirectory(C.logdir, 0)
  local L = { lines = {}, path = C.logdir .. "/" .. filename, errors = 0, warnings = 0 }
  function L.w(...)
    local t = {}
    for i = 1, select('#', ...) do t[#t + 1] = tostring((select(i, ...))) end
    L.lines[#L.lines + 1] = table.concat(t, " ")
  end
  function L.err(...) L.errors = L.errors + 1; L.w("ERROR:", ...) end
  function L.warn(...) L.warnings = L.warnings + 1; L.w("WARNING:", ...) end
  function L.save()
    local f = io.open(L.path, "w")
    if f then
      f:write(table.concat(L.lines, "\n") .. "\n")
      f:close()
    end
  end
  L.w("Foldback", C.VERSION, "-", filename, "-", os.date("%Y-%m-%d %H:%M:%S"), "- REAPER", r.GetAppVersion())
  local _, proj = r.EnumProjects(-1, "")
  L.w("Project:", (proj ~= "" and proj) or "(unsaved project)")
  return L
end

---------------------------------------------------------------- config
-- Built-in defaults: anything a profile leaves out falls back to these.
C.DEFAULT_OPTIONS = {
  default_stems = "",
  hide_cue_tracks_in_arrange = true,
  hide_cue_tracks_in_mixer = true,
  auto_send_db = 0.0,
  mix_send_db = -150,          -- mix mode: level new cue sends start at (-150 or lower = off / -inf)
  mix_new_tracks = "all",      -- mix mode: "all" = new tracks get a silent send to every mix; "pick" = you add them
  skip_folder_tracks = true,
  auto_setup_new_projects = false,
  listen_off_on_open = true,
  send_mode = "prefader",
  enforce_send_mode = false,
  cue_prefix = "CUE ",
  listen_name = "CUE LISTEN",
  listen_color = { 220, 40, 40 },
  click_track = false,         -- mix mode: a click track (follows the project tempo) with its own send to every mix
  talkback = false,            -- a TALKBACK track + a hold-to-talk button in the panel
  limiter = false,             -- a peak limiter last in every cue, so nothing can get painfully loud
  limiter_ceiling_db = -3,     -- the loudest a cue can ever get (dBFS) while the limiter is on
}
C.LEFT_GUTTER = 21   -- empty space at the panel's left edge (pixels), the same for everyone
C.SEND_MODES = { prefader = 3, prefx = 1, postfader = 0 }
C.SEND_MODE_NAMES = { [3] = "pre-fader (post-FX)", [1] = "pre-FX", [0] = "post-fader" }

local function read_file(path)
  local f = io.open(path, "rb"); if not f then return nil end
  local d = f:read("a"); f:close(); return d
end
local function write_file(path, data)
  local f = io.open(path, "wb"); if not f then return false end
  f:write(data); f:close(); return true
end

-- name of the active profile (Foldback/active_profile.txt), or nil
function C.active_profile_name()
  local d = read_file(C.dir .. "/active_profile.txt")
  if not d then return nil end
  d = d:match("^%s*(.-)%s*$")
  return (d ~= "") and d or nil
end

function C.set_active_profile(name)
  r.RecursiveCreateDirectory(C.dir, 0)
  return write_file(C.dir .. "/active_profile.txt", name .. "\n")
end

-- profile names (file names without .lua) in Foldback/profiles
function C.list_profiles()
  local t, i = {}, 0
  while true do
    local f = r.EnumerateFiles(C.profdir, i)
    if not f then break end
    if f:lower():match("%.lua$") then t[#t + 1] = f:gsub("%.[Ll][Uu][Aa]$", "") end
    i = i + 1
  end
  table.sort(t)
  return t
end

-- The effects (JSFX) ship next to the scripts, in effects/*.txt, and are copied into
-- <REAPER resource folder>/Effects/Foldback (no .txt) when missing or out of date.
C.FX_FILES = { "Foldback_MonoSum", "Foldback_TestTone", "Foldback_Limiter", "Foldback_Click" }
function C.ensure_effects()
  local dir = C.res .. "/Effects/Foldback"
  for _, n in ipairs(C.FX_FILES) do
    local src = read_file(C.script_dir .. "effects/" .. n .. ".txt")
    if src and read_file(dir .. "/" .. n) ~= src then
      r.RecursiveCreateDirectory(dir, 0)
      write_file(dir .. "/" .. n, src)
    end
  end
end

-- First run: copy the shipped Starter profile into the user's profiles folder.
function C.ensure_starter()
  r.RecursiveCreateDirectory(C.profdir, 0)
  for _, n in ipairs({ "Starter", "Starter Stems" }) do
    local to = C.profdir .. "/" .. n .. ".lua"
    if not r.file_exists(to) then
      local d = read_file(C.script_dir .. "profiles/" .. n .. ".lua")
      if d then write_file(to, d) end
    end
  end
end

-- Which file to load: the active profile; else the older single Foldback_Config.lua;
-- else the Starter profile.
function C.config_path()
  local name = C.active_profile_name()
  if name and r.file_exists(C.profdir .. "/" .. name .. ".lua") then
    return C.profdir .. "/" .. name .. ".lua", name
  end
  if r.file_exists(C.dir .. "/Foldback_Config.lua") then
    return C.dir .. "/Foldback_Config.lua", "Foldback_Config (older single config)"
  end
  return C.profdir .. "/Starter.lua", "Starter"
end

function C.load_config()
  C.ensure_effects()
  C.ensure_starter()
  local path, name = C.config_path()
  local ok, cfg = pcall(dofile, path)
  if not ok or type(cfg) ~= "table" then
    return nil, "Couldn't read " .. path .. "\n\n" .. tostring(cfg)
  end
  cfg.stems = cfg.stems or {}
  cfg.rules = cfg.rules or {}
  cfg.options = cfg.options or {}
  -- Older profiles gave each cue a channel number (home) plus a channel -> output list.
  -- Now each cue names its output directly; convert on load.
  local legacy_outs = cfg.outputs or cfg.p16
  for _, st in ipairs(cfg.stems) do
    if st.output == nil and st.home and legacy_outs then st.output = legacy_outs[st.home] end
    st.home = nil
  end
  -- Optional features (track-name rules, cue reverb). A profile from before features
  -- existed keeps whatever it was already using.
  if cfg.features == nil then
    cfg.features = {
      name_rules = (#cfg.rules > 0) or nil,
      cue_reverb = (cfg.cue_reverb and cfg.cue_reverb.enabled) and true or nil,
    }
    if legacy_outs and cfg.options.enforce_send_mode == nil then cfg.options.enforce_send_mode = true end
  end
  cfg.outputs, cfg.p16, cfg.channel_count = nil, nil, nil
  -- device_label (optional, e.g. "P16") + a stem's channel (its first channel on that device)
  -- make the panel show "P16 1-2" instead of the raw output names. Profiles without them
  -- (e.g. the generic one) keep showing output names.
  if type(cfg.device_label) ~= "string" or cfg.device_label == "" then cfg.device_label = nil end
  cfg.options.pair_odd_channels = nil
  cfg.options.left_gutter = nil        -- no longer a setting (C.LEFT_GUTTER)
  for k, v in pairs(C.DEFAULT_OPTIONS) do
    if cfg.options[k] == nil then cfg.options[k] = v end
  end
  -- cue_mode: "stems" (each cue is a group of instruments, the musician blends them) or
  -- "mix" (each cue is one performer's complete stereo mix). Profiles without it are stem mode.
  cfg.cue_mode = (cfg.cue_mode == "mix") and "mix" or "stems"
  if cfg.cue_mode == "mix" then
    for _, st in ipairs(cfg.stems) do
      if not st.metronome then st.width = "stereo" end   -- mixes are always stereo
    end
  end
  cfg.profile = name
  cfg.path = path
  C.cfg_path, C.profile = path, name
  C.cfg = cfg
  return cfg
end

-- Panel colors: built-in defaults (any can be overridden with panel_colors in the profile)
C.LOOK_DEFAULTS = {
  { "bg", { 40, 40, 40 } }, { "popup", { 48, 48, 48 } }, { "panel", { 60, 60, 60 } },
  { "well", { 37, 37, 37 } }, { "edit", { 50, 50, 50 } }, { "text", { 210, 210, 210 } },
  { "dim", { 108, 108, 108 } }, { "divider", { 28, 28, 28 } }, { "teal", { 26, 188, 152 } },
  { "teal_dim", { 35, 103, 91 } }, { "listen_on", { 204, 51, 51 } }, { "clip", { 187, 37, 0 } }, { "vu_low", { 0, 191, 191 } },
  { "vu_mid", { 0, 218, 173 } }, { "vu_top", { 0, 254, 149 } }, { "muted", { 125, 56, 46 } },
  { "ink", { 34, 34, 34 } },
}
C.LOOK_LABELS = {
  bg = "Background", popup = "Pop-up background", panel = "Buttons", well = "Level box background",
  edit = "Text box background", text = "Text", dim = "Dim text", divider = "Dividers",
  teal = "Accent (ticks, highlights)", teal_dim = "Level fill / selection", listen_on = "Listen button (lit)", clip = "Meter: clip",
  vu_low = "Meter: low", vu_mid = "Meter: middle", vu_top = "Meter: high", muted = "Muted level",
  ink = "Text on cue name buttons",
}

---------------------------------------------------------------- saving a profile
local function is_ident(k) return type(k) == "string" and k:match("^[%a_][%w_]*$") ~= nil end

local function ser(v)
  local t = type(v)
  if t == "string" then return string.format("%q", v) end
  if t == "boolean" then return tostring(v) end
  if t == "number" then
    if v == math.floor(v) and math.abs(v) < 1e15 then return string.format("%d", math.floor(v)) end
    return string.format("%.6g", v)
  end
  if t ~= "table" then return "nil" end
  local parts, n = {}, #v
  for i = 1, n do parts[#parts + 1] = ser(v[i]) end
  local keys = {}
  for k in pairs(v) do
    if not (type(k) == "number" and k >= 1 and k <= n and k == math.floor(k)) then keys[#keys + 1] = k end
  end
  table.sort(keys, function(a, b)
    if type(a) == type(b) then return a < b end
    return type(a) == "number"
  end)
  for _, k in ipairs(keys) do
    local ks = is_ident(k) and k or ("[" .. ser(k) .. "]")
    parts[#parts + 1] = ks .. " = " .. ser(v[k])
  end
  if #parts == 0 then return "{}" end
  return "{ " .. table.concat(parts, ", ") .. " }"
end
C.serialize = ser

local SKIP = { p16 = true, path = true, profile = true }
local ORDER = { "profile_name", "cue_mode", "features", "monitor_output",
  "stems", "exclude", "rules", "cue_reverb", "options", "panel_colors" }

-- The whole profile as Lua text. stamp = date line for the header ("" = none, for comparing)
function C.profile_text(cfg, stamp)
  local o = {}
  local function w(x) o[#o + 1] = x end
  w("-- Foldback profile: " .. tostring(cfg.profile_name or cfg.profile or ""))
  w("-- Easiest to change in Foldback Settings (panel > Settings > Foldback settings...).")
  w("-- If you edit it by hand, keep the commas, quotes and braces exactly as they are.")
  if stamp and stamp ~= "" then w("-- Saved " .. stamp) end
  w("return {")
  local done = {}
  for _, k in ipairs(ORDER) do
    done[k] = true
    local v = cfg[k]
    if k == "stems" then
      w("  stems = {")
      for _, s in ipairs(v or {}) do
        local parts = {}
        for _, f in ipairs({ "id", "name", "width", "output" }) do
          if s[f] ~= nil then parts[#parts + 1] = f .. " = " .. ser(s[f]) end
        end
        local rest = {}
        for f in pairs(s) do
          if f ~= "id" and f ~= "name" and f ~= "width" and f ~= "output" then rest[#rest + 1] = f end
        end
        table.sort(rest, function(a, b) return tostring(a) < tostring(b) end)
        for _, f in ipairs(rest) do
          parts[#parts + 1] = (is_ident(f) and f or ("[" .. ser(f) .. "]")) .. " = " .. ser(s[f])
        end
        w("    { " .. table.concat(parts, ", ") .. " },")
      end
      w("  },")
    elseif k == "features" then
      local fs = {}
      for kk, vv in pairs(v or {}) do if vv then fs[#fs + 1] = kk .. " = true" end end
      table.sort(fs)
      if #fs > 0 then w("  features = { " .. table.concat(fs, ", ") .. " },") end
    elseif k == "exclude" or k == "rules" or k == "cue_reverb" then
      if C.feature(cfg, (k == "cue_reverb") and "cue_reverb" or "name_rules") and v ~= nil then
        if k == "exclude" then w("  exclude = " .. ser(v) .. ",")
        elseif k == "rules" then
          w("  rules = {")
          for _, rl in ipairs(v) do w("    { " .. ser(rl[1]) .. ", " .. ser(rl[2] or "") .. " },") end
          w("  },")
        else
          w("  cue_reverb = {")
          local ks = {}
          for kk in pairs(v) do ks[#ks + 1] = kk end
          table.sort(ks, function(x, y) return tostring(x) < tostring(y) end)
          for _, kk in ipairs(ks) do w("    " .. (is_ident(kk) and kk or ("[" .. ser(kk) .. "]")) .. " = " .. ser(v[kk]) .. ",") end
          w("  },")
        end
      end
    elseif k == "rules_unused" then
      w("  rules = {")
      for _, rl in ipairs(v or {}) do w("    { " .. ser(rl[1]) .. ", " .. ser(rl[2] or "") .. " },") end
      w("  },")
    elseif k == "options" or k == "panel_colors" then
      w("  " .. k .. " = {")
      local ks = {}
      for kk in pairs(v or {}) do ks[#ks + 1] = kk end
      table.sort(ks, function(a, b) return tostring(a) < tostring(b) end)
      for _, kk in ipairs(ks) do
        w("    " .. (is_ident(kk) and kk or ("[" .. ser(kk) .. "]")) .. " = " .. ser(v[kk]) .. ",")
      end
      w("  },")
    elseif v ~= nil then
      w("  " .. k .. " = " .. ser(v) .. ",")
    end
  end
  local extra = {}
  for k in pairs(cfg) do if not done[k] and not SKIP[k] then extra[#extra + 1] = k end end
  table.sort(extra, function(a, b) return tostring(a) < tostring(b) end)
  for _, k in ipairs(extra) do
    w("  " .. (is_ident(k) and k or ("[" .. ser(k) .. "]")) .. " = " .. ser(cfg[k]) .. ",")
  end
  w("}")
  return table.concat(o, "\n") .. "\n"
end

function C.profile_file(name) return C.profdir .. "/" .. name .. ".lua" end

-- Write a profile. The previous file is backed up first, and the new file is read back to
-- make sure it loads; if it doesn't, the old file is put back. returns ok, error
function C.save_profile(cfg, path)
  local text = C.profile_text(cfg, os.date("%Y-%m-%d %H:%M"))
  local old = read_file(path)
  if old then
    local bdir = C.dir .. "/backups/profiles"
    r.RecursiveCreateDirectory(bdir, 0)
    local base = path:match("([^/\\]+)%.lua$") or "profile"
    write_file(bdir .. "/" .. base .. " " .. os.date("%Y%m%d-%H%M%S") .. ".lua", old)
  end
  if not write_file(path, text) then return false, "Couldn't write " .. path end
  local ok, back = pcall(dofile, path)
  if not ok or type(back) ~= "table" then
    if old then write_file(path, old) end
    return false, "The saved file didn't read back correctly, so the previous version was kept.\n\n" .. tostring(back)
  end
  return true
end

function C.copy_file(from, to)
  local d = read_file(from)
  if not d then return false end
  return write_file(to, d)
end

-- profile file names: letters, numbers, spaces, - and _ only
function C.valid_profile_name(n)
  n = (n or ""):match("^%s*(.-)%s*$")
  if n == "" or #n > 60 or not n:match("^[%w _%-]+$") then return nil end
  return n
end

-- a stem id (no spaces) made from a name, unique within cfg
function C.new_stem_id(cfg, name)
  local base = (name or ""):lower():gsub("[^%w]", "")
  if base == "" then base = "stem" end
  local id, i = base, 2
  while C.stem_by_id(cfg, id) do id = base .. i; i = i + 1 end
  return id
end

-- send mode number for sends into cues (from options.send_mode)
function C.send_mode(cfg)
  local m = C.SEND_MODES[((cfg or C.cfg or {}).options or {}).send_mode or "prefader"]
  return m or C.SENDMODE_PREFADER_POSTFX
end

function C.opt(key)
  local o = (C.cfg and C.cfg.options) or {}
  if o[key] ~= nil then return o[key] end
  return C.DEFAULT_OPTIONS[key]
end

-- mix mode: each cue is one performer's complete stereo mix (see cue_mode)
function C.is_mix(cfg)
  return ((cfg or C.cfg or {}).cue_mode) == "mix"
end

-- level (dB) a newly made cue send starts at; -150 or lower means off (-inf)
function C.new_send_db(cfg)
  cfg = cfg or C.cfg or {}
  local o = cfg.options or {}
  if C.is_mix(cfg) then
    local v = tonumber(o.mix_send_db)
    if v == nil then v = C.DEFAULT_OPTIONS.mix_send_db end
    return v
  end
  return o.auto_send_db or 0.0
end

function C.fmt_start_db(db)
  if db <= -150 then return "off (-inf)" end
  return string.format("%.1f dB", db)
end

-- is an optional feature on in this profile? ("name_rules", "cue_reverb")
function C.feature(cfg, key)
  local f = (cfg or C.cfg or {}).features
  return f ~= nil and f[key] == true
end

function C.stem_by_id(cfg, id)
  for _, s in ipairs(cfg.stems) do if s.id == id then return s end end
end

function C.stem_by_name(cfg, name)
  local n = name:lower()
  for _, s in ipairs(cfg.stems) do
    if s.name:lower() == n or s.id == n then return s end
  end
end

-- REAPER output index (0-based) from an output name, or from a 1-based output number
function C.output_index(name)
  if not name then return nil end
  if type(name) == "number" then
    local i = math.floor(name) - 1
    if i >= 0 and i < r.GetNumAudioOutputs() then return i end
    return nil
  end
  for i = 0, r.GetNumAudioOutputs() - 1 do
    if r.GetOutputChannelName(i) == name then return i end
  end
  return nil
end

-- First hardware output (0-based) that the master track plays to, or nil if it has none
function C.master_out_index()
  local m = r.GetMasterTrack(0)
  if not m then return nil end
  for i = 0, (r.GetTrackNumSends(m, 1) or 0) - 1 do
    local d = r.GetTrackSendInfo_Value(m, 1, i, "I_DSTCHAN")
    if d and d >= 0 then return math.floor(d) & 1023 end
  end
  return nil
end

-- Where Listen plays: the output chosen in the profile, or (if none is chosen) wherever the
-- master track plays. returns index, "profile"|"master"   or   nil, reason
function C.listen_index(cfg)
  if cfg.monitor_output ~= nil then
    local i = C.output_index(cfg.monitor_output)
    if i then return i, "profile" end
    return nil, "the Listen output '" .. tostring(cfg.monitor_output) .. "' isn't one of this computer's outputs."
  end
  local i = C.master_out_index()
  if i and i + 1 < r.GetNumAudioOutputs() then return i, "master" end
  return nil, "no Listen output is chosen, and the master track has no hardware output to follow.\n\nChoose one in Settings > Foldback settings > Cues tab > Speaker outputs, save, then try again."
end

-- REAPER input index (0-based) from an input name, or from a 1-based input number
function C.input_index(name)
  if not name then return nil end
  local n = r.GetNumAudioInputs()
  if type(name) == "number" then
    local i = math.floor(name) - 1
    if i >= 0 and i < n then return i end
    return nil
  end
  for i = 0, n - 1 do
    if r.GetInputChannelName(i) == name then return i end
  end
  return nil
end

function C.find_tagged(key)
  for i = 0, r.CountTracks(0) - 1 do
    local tr = r.GetTrack(0, i)
    if C.get_ext(tr, key) then return tr end
  end
  return nil
end

-- The click track: an ordinary track (so it gets a send to every mix like any other track)
-- whose only content is a click generator. Never plays to the master. returns track or nil
function C.ensure_click()
  local tr = C.find_tagged(C.KEY_CLICK)
  r.PreventUIRefresh(1)
  if not tr then
    tr = C.new_track_at_end()
    C.set_ext(tr, C.KEY_CLICK, "1")
    r.GetSetMediaTrackInfo_String(tr, "P_NAME", "Click", true)
  end
  r.SetMediaTrackInfo_Value(tr, "B_MAINSEND", 0)
  -- REAPER skips a track that has no items and nothing recording into it. Arming it for
  -- monitoring only (it never records) keeps the click generator running during playback.
  r.SetMediaTrackInfo_Value(tr, "I_RECINPUT", -1)   -- no input: nothing but the click is ever heard
  r.SetMediaTrackInfo_Value(tr, "I_RECMODE", 2)
  r.SetMediaTrackInfo_Value(tr, "I_RECMON", 1)
  r.SetMediaTrackInfo_Value(tr, "I_RECARM", 1)
  local ok = C.add_fx(tr, C.CLICK_FX) ~= nil
  r.PreventUIRefresh(-1)
  r.TrackList_AdjustWindows(false)
  return ok and tr or nil
end

-- The TALKBACK track: takes the chosen mic input and has a (muted) send into every cue.
-- Never plays to the master. returns track or nil
function C.ensure_talkback(cfg, cues)
  local opt = cfg.options or {}
  local tr = C.find_tagged(C.KEY_TALK)
  r.PreventUIRefresh(1)
  if not tr then
    tr = C.new_track_at_end()
    C.set_ext(tr, C.KEY_TALK, "1")
  end
  r.GetSetMediaTrackInfo_String(tr, "P_NAME", "TALKBACK", true)
  r.SetMediaTrackInfo_Value(tr, "B_MAINSEND", 0)
  r.SetMediaTrackInfo_Value(tr, "B_SOLO_DEFEAT", 1)
  r.SetMediaTrackInfo_Value(tr, "I_NCHAN", 2)
  local inp = C.input_index(opt.talkback_input)
  if inp then
    r.SetMediaTrackInfo_Value(tr, "I_RECINPUT", inp)    -- one mono input
    r.SetMediaTrackInfo_Value(tr, "I_RECMODE", 2)       -- monitor only: never records
    r.SetMediaTrackInfo_Value(tr, "I_RECMON", 1)
    r.SetMediaTrackInfo_Value(tr, "I_RECARM", 1)
  end
  if opt.hide_cue_tracks_in_arrange ~= nil then r.SetMediaTrackInfo_Value(tr, "B_SHOWINTCP", opt.hide_cue_tracks_in_arrange and 0 or 1) end
  if opt.hide_cue_tracks_in_mixer ~= false then r.SetMediaTrackInfo_Value(tr, "B_SHOWINMIXER", 0) end
  for _, s in ipairs(cfg.stems or {}) do
    local cue = cues[s.id]
    if cue and not s.metronome then C.ensure_send(tr, cue, 0.0, C.SENDMODE_POSTFADER, true) end
  end
  r.PreventUIRefresh(-1)
  r.TrackList_AdjustWindows(false)
  return tr, inp ~= nil
end

-- open (true) or close (false) the talkback sends
function C.talkback_set(on)
  local tr = C.find_tagged(C.KEY_TALK)
  if not tr then return end
  for k = 0, r.GetTrackNumSends(tr, 0) - 1 do
    r.SetTrackSendInfo_Value(tr, 0, k, "B_MUTE", on and 0 or 1)
  end
end

-- REAPER output index (0-based) of a cue's output (the left side, for stereo), or nil +
-- reason (+ true if no output is chosen yet, which is allowed: the cue plays nowhere)
function C.stem_output(cfg, s)
  if s.output == nil then return nil, s.name .. " has no output chosen", true end
  local a = C.output_index(s.output)
  if not a then return nil, s.name .. "'s output '" .. tostring(s.output) .. "' isn't one of this computer's outputs" end
  if s.width == "stereo" and a + 1 >= r.GetNumAudioOutputs() then
    return nil, s.name .. " is stereo but '" .. tostring(s.output) .. "' is the last output (nothing after it for the right side)"
  end
  return a
end

-- set of REAPER output indexes a cue uses (empty if none / not found)
function C.stem_out_set(s)
  local t = {}
  local a = C.output_index(s.output)
  if a then t[a] = true; if s.width == "stereo" then t[a + 1] = true end end
  return t
end

-- short text for a cue's output(s): "X16 9", "X16 9-10", "Out A + Out B", or (profile with
-- device_label + stem channel) "P16 1-2". real = true always gives the REAPER output names.
function C.output_label(s, real)
  if not real and C.cfg and C.cfg.device_label and tonumber(s.channel) then
    local c = math.floor(tonumber(s.channel))
    return C.cfg.device_label .. " " .. c .. ((s.width == "stereo") and ("-" .. (c + 1)) or "")
  end
  if s.output == nil then return "no output" end
  local a = C.output_index(s.output)
  if not a then return "missing: " .. tostring(s.output) end
  local n1 = r.GetOutputChannelName(a) or tostring(a + 1)
  if s.width ~= "stereo" then return n1 end
  local n2 = r.GetOutputChannelName(a + 1) or tostring(a + 2)
  local p1, d1 = n1:match("^(.-)(%d+)$")
  local p2, d2 = n2:match("^(.-)(%d+)$")
  if p1 and p1 == p2 then return p1 .. d1 .. "-" .. d2 end
  return n1 .. " + " .. n2
end

---------------------------------------------------------------- migration from the
-- earlier "GSS Cue" test version: move old track tags to the new names.
local OLD_KEYS = {
  { "P_EXT:GSS_CUE", "P_EXT:FOLDBACK" }, { "P_EXT:GSS_CUE_LISTEN", "P_EXT:FOLDBACK_LISTEN" },
  { "P_EXT:GSS_CUE_TEST", "P_EXT:FOLDBACK_TEST" }, { "P_EXT:GSS_CUE_VERB", "P_EXT:FOLDBACK_VERB" },
  { "P_EXT:GSS_CUE_SEEN", "P_EXT:FOLDBACK_SEEN" },
}
function C.migrate()
  local n = 0
  for i = 0, r.CountTracks(0) - 1 do
    local tr = r.GetTrack(0, i)
    for _, k in ipairs(OLD_KEYS) do
      local v = C.get_ext(tr, k[1])
      if v then
        if not C.get_ext(tr, k[2]) then C.set_ext(tr, k[2], v) end
        C.set_ext(tr, k[1], "")
        n = n + 1
      end
    end
  end
  local ok, mm = r.GetProjExtState(0, "GSS_CUE", "master_mute_before")
  if ok == 1 and mm ~= "" then
    r.SetProjExtState(0, "FOLDBACK", "master_mute_before", mm)
    r.SetProjExtState(0, "GSS_CUE", "master_mute_before", "")
  end
  return n
end

-- Foldback tells other scripts (e.g. Q-Link) it just changed a send itself
function C.mark_busy()
  r.SetExtState("Foldback", "busy", tostring(r.time_precise()), false)
end

---------------------------------------------------------------- scanning
-- returns: cues (stem id -> track), listen track or nil, list of test tracks, verb track or nil
function C.scan()
  local cues, listen, tests, verb = {}, nil, {}, nil
  for i = 0, r.CountTracks(0) - 1 do
    local tr = r.GetTrack(0, i)
    local id = C.get_ext(tr, C.KEY_STEM)
    if id then cues[id] = tr end
    if C.get_ext(tr, C.KEY_LISTEN) then listen = tr end
    if C.get_ext(tr, C.KEY_TEST) then tests[#tests + 1] = tr end
    if C.get_ext(tr, C.KEY_VERB) then verb = tr end
  end
  return cues, listen, tests, verb
end

---------------------------------------------------------------- sends
function C.find_send(src, dest)
  local g = C.guid(dest)
  for i = 0, r.GetTrackNumSends(src, 0) - 1 do
    local d = r.GetTrackSendInfo_Value(src, 0, i, "P_DESTTRACK")
    if d and r.ValidatePtr2(0, d, "MediaTrack*") and C.guid(d) == g then return i end
  end
  return nil
end

-- Make sure src has a send to dest. Existing sends are left as they are.
-- returns send index, created(bool)
function C.ensure_send(src, dest, db, mode, muted)
  local s = C.find_send(src, dest)
  if s then return s, false end
  r.CreateTrackSend(src, dest)
  s = C.find_send(src, dest)
  if not s then return nil, false end
  r.SetTrackSendInfo_Value(src, 0, s, "D_VOL", C.db2lin(db))
  r.SetTrackSendInfo_Value(src, 0, s, "D_PAN", 0.0)
  r.SetTrackSendInfo_Value(src, 0, s, "B_MUTE", muted and 1 or 0)
  r.SetTrackSendInfo_Value(src, 0, s, "I_SENDMODE", mode)
  r.SetTrackSendInfo_Value(src, 0, s, "I_SRCCHAN", 0)  -- channels 1/2
  r.SetTrackSendInfo_Value(src, 0, s, "I_DSTCHAN", 0)  -- into 1/2
  return s, true
end

-- Replace all hardware outputs on tr with one (stereo pair or mono).
function C.set_hw_out(tr, out_idx, mono)
  for i = r.GetTrackNumSends(tr, 1) - 1, 0, -1 do r.RemoveTrackSend(tr, 1, i) end
  if not out_idx then return nil end
  r.CreateTrackSend(tr, nil)
  local s = r.GetTrackNumSends(tr, 1) - 1
  r.SetTrackSendInfo_Value(tr, 1, s, "I_SRCCHAN", mono and 1024 or 0)
  r.SetTrackSendInfo_Value(tr, 1, s, "I_DSTCHAN", mono and (out_idx | 1024) or out_idx)
  r.SetTrackSendInfo_Value(tr, 1, s, "D_VOL", 1.0)
  r.SetTrackSendInfo_Value(tr, 1, s, "D_PAN", 0.0)
  r.SetTrackSendInfo_Value(tr, 1, s, "B_MUTE", 0)
  r.SetTrackSendInfo_Value(tr, 1, s, "I_SENDMODE", C.SENDMODE_POSTFADER)
  return s
end

---------------------------------------------------------------- FX
local function add_fx(tr, names)
  for _, nm in ipairs(names) do
    local idx = r.TrackFX_AddByName(tr, nm, false, 1) -- 1 = add if not already there
    if idx >= 0 then return idx, nm end
  end
  return nil
end
C.add_fx = add_fx

function C.remove_mono_fx(tr)
  for i = r.TrackFX_GetCount(tr) - 1, 0, -1 do
    local _, n = r.TrackFX_GetFXName(tr, i, "")
    if n:find("Foldback mono sum", 1, true) or n:find("Foldback_MonoSum", 1, true)
       or n:find("GSS Cue mono sum", 1, true) or n:find("GSS_Cue_MonoSum", 1, true) then
      r.TrackFX_Delete(tr, i)
    end
  end
end

-- Put the limiter on a cue track (last in its chain) or take it off; set its ceiling.
-- Does nothing if the track is already right. returns false if the effect couldn't be loaded.
function C.sync_limiter(tr, on, ceiling_db)
  local found = {}
  for i = 0, r.TrackFX_GetCount(tr) - 1 do
    local _, n = r.TrackFX_GetFXName(tr, i, "")
    if n:find("Foldback limiter", 1, true) or n:find("Foldback_Limiter", 1, true) then found[#found + 1] = i end
  end
  if not on then
    for k = #found, 1, -1 do r.TrackFX_Delete(tr, found[k]) end
    return true
  end
  if not (#found == 1 and found[1] == r.TrackFX_GetCount(tr) - 1) then
    for k = #found, 1, -1 do r.TrackFX_Delete(tr, found[k]) end
    if not add_fx(tr, C.LIMITER_FX) then return false end
  end
  local idx = r.TrackFX_GetCount(tr) - 1
  local want = math.max(-24, math.min(0, tonumber(ceiling_db) or -3))
  local cur = r.TrackFX_GetParam(tr, idx, 0)
  if math.abs((cur or 99) - want) > 0.01 then r.TrackFX_SetParam(tr, idx, 0, want) end
  -- the cue fader comes AFTER plugins, so a fader above 0 dB would push past the ceiling
  if r.GetMediaTrackInfo_Value(tr, "D_VOL") > 1.0 then r.SetMediaTrackInfo_Value(tr, "D_VOL", 1.0) end
  return true
end

function C.apply_limiter_all(cfg)
  local o = cfg.options or {}
  local cues = C.scan()
  for _, tr in pairs(cues) do C.sync_limiter(tr, o.limiter == true, o.limiter_ceiling_db) end
end

---------------------------------------------------------------- tracks
function C.new_track_at_end()
  local n = r.CountTracks(0)
  r.InsertTrackAtIndex(n, false)
  local tr = r.GetTrack(0, n)
  r.SetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH", 0)
  return tr
end

-- Configure a cue track for a stem. out_idx may be nil (no hardware output).
-- returns true if everything (incl. mono FX) was set up
function C.configure_cue(tr, stem, out_idx, opts)
  opts = opts or {}
  r.GetSetMediaTrackInfo_String(tr, "P_NAME", (opts.prefix or C.opt("cue_prefix")) .. stem.name, true)
  r.SetMediaTrackInfo_Value(tr, "I_NCHAN", 2)
  r.SetMediaTrackInfo_Value(tr, "B_MAINSEND", 0)     -- never feeds the mix
  r.SetMediaTrackInfo_Value(tr, "B_SOLO_DEFEAT", 1)  -- your solos never silence it
  local sc = C.stem_color(stem)
  if sc then
    r.SetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR", r.ColorToNative(sc[1], sc[2], sc[3]) | 0x1000000)
  end
  if opts.hide_tcp ~= nil then
    r.SetMediaTrackInfo_Value(tr, "B_SHOWINTCP", opts.hide_tcp and 0 or 1)
  end
  if opts.hide_mixer ~= nil then
    r.SetMediaTrackInfo_Value(tr, "B_SHOWINMIXER", opts.hide_mixer and 0 or 1)
  end
  local ok = true
  if stem.width == "mono" then
    for i = r.TrackFX_GetCount(tr) - 1, 0, -1 do       -- remove the older GSS Cue version
      local _, n = r.TrackFX_GetFXName(tr, i, "")
      if n:find("GSS Cue mono sum", 1, true) or n:find("GSS_Cue_MonoSum", 1, true) then r.TrackFX_Delete(tr, i) end
    end
    ok = add_fx(tr, C.MONO_FX) ~= nil
  else
    C.remove_mono_fx(tr)
  end
  if opts.limiter ~= nil then ok = C.sync_limiter(tr, opts.limiter, opts.ceiling) and ok end
  C.set_hw_out(tr, out_idx, stem.width == "mono")
  return ok
end

function C.configure_listen(tr, mon_idx, hide_tcp, hide_mixer)
  r.GetSetMediaTrackInfo_String(tr, "P_NAME", C.opt("listen_name"), true)
  r.SetMediaTrackInfo_Value(tr, "I_NCHAN", 2)
  r.SetMediaTrackInfo_Value(tr, "B_MAINSEND", 0)
  r.SetMediaTrackInfo_Value(tr, "B_SOLO_DEFEAT", 1)
  local lc = C.opt("listen_color")
  r.SetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR", r.ColorToNative(lc[1], lc[2], lc[3]) | 0x1000000)
  if hide_tcp ~= nil then r.SetMediaTrackInfo_Value(tr, "B_SHOWINTCP", hide_tcp and 0 or 1) end
  if hide_mixer ~= nil then r.SetMediaTrackInfo_Value(tr, "B_SHOWINMIXER", hide_mixer and 0 or 1) end
  C.set_hw_out(tr, mon_idx, false)
end

---------------------------------------------------------------- cue reverb
-- Set a plugin parameter so its DISPLAYED value is as close as possible to target
-- (searches the 0..1 range; works for any plugin whose display is a number).
local function display_number(tr, fx, p)
  local _, txt = r.TrackFX_GetFormattedParamValue(tr, fx, p, "")
  local t = txt:lower()
  if t:find("inf", 1, true) then return -math.huge, txt end
  local n = tonumber(t:match("[-+]?%d+%.?%d*"))
  if n and t:match("%d%s*k") then n = n * 1000 end
  return n, txt
end

function C.set_param_display(tr, fx, p, target)
  if target == "min" then
    r.TrackFX_SetParamNormalized(tr, fx, p, 0)
    local _, txt = display_number(tr, fx, p)
    return true, txt
  end
  r.TrackFX_SetParamNormalized(tr, fx, p, 0)
  local lo_v = display_number(tr, fx, p)
  r.TrackFX_SetParamNormalized(tr, fx, p, 1)
  local hi_v = display_number(tr, fx, p)
  if not lo_v or not hi_v then return false, "display not numeric" end
  local increasing = hi_v >= lo_v
  local lo, hi = 0.0, 1.0
  for _ = 1, 30 do
    local mid = (lo + hi) / 2
    r.TrackFX_SetParamNormalized(tr, fx, p, mid)
    local v = display_number(tr, fx, p)
    if not v then return false, "display not numeric" end
    if (v < target) == increasing then lo = mid else hi = mid end
  end
  r.TrackFX_SetParamNormalized(tr, fx, p, (lo + hi) / 2)
  local _, txt = display_number(tr, fx, p)
  return true, txt
end

C.VERB_NAME = "Foldback reverb"

function C.display_number(tr, fx, p) return display_number(tr, fx, p) end

-- index of the cue reverb on a cue track, or nil
function C.find_cue_verb(tr)
  for i = 0, r.TrackFX_GetCount(tr) - 1 do
    local ok, rn = r.TrackFX_GetNamedConfigParm(tr, i, "renamed_name")
    if ok and rn == C.VERB_NAME then return i end
    if ok and rn == "GSS Cue reverb" then          -- older name
      r.TrackFX_SetNamedConfigParm(tr, i, "renamed_name", C.VERB_NAME)
      return i
    end
  end
  return nil
end

-- first parameter whose name contains key (lowercase)
function C.find_param(tr, fx, key)
  for p = 0, r.TrackFX_GetNumParams(tr, fx) - 1 do
    local _, pn = r.TrackFX_GetParamName(tr, fx, p, "")
    if pn:lower():find(key, 1, true) then return p, pn end
  end
  return nil
end

function C.apply_settings(tr, fx, settings, log)
  for _, st in ipairs(settings or {}) do
    local p, pn = C.find_param(tr, fx, st[1]:lower())
    if p then
      local ok, shown = C.set_param_display(tr, fx, p, st[2])
      if log then log.w(string.format("    %-14s -> %s %s", pn, tostring(shown), ok and "" or "(couldn't set)")) end
    elseif log then
      log.warn("reverb has no parameter matching", st[1])
    end
  end
end

-- Add the cue reverb to a cue track (first in the chain, before the mono sum).
-- Starting settings are applied only when it's newly added. returns fx index, added(bool)
function C.add_cue_verb(tr, rv, log)
  local fx = C.find_cue_verb(tr)
  if fx then return fx, false end
  fx = r.TrackFX_AddByName(tr, rv.plugin, false, -1)
  if fx < 0 then
    if log then log.err("Couldn't load reverb plugin:", rv.plugin) end
    return nil, false
  end
  r.TrackFX_SetNamedConfigParm(tr, fx, "renamed_name", C.VERB_NAME)
  if fx ~= 0 then
    r.TrackFX_CopyToTrack(tr, fx, tr, 0, true)
    fx = 0
  end
  if log then
    local okp, pdc = r.TrackFX_GetNamedConfigParm(tr, fx, "pdc")
    log.w("    reverb added to " .. C.name(tr) .. " (" .. rv.plugin .. ", latency " .. (okp and pdc or "?") .. " samples)")
  end
  C.apply_settings(tr, fx, rv.settings, log)
  return fx, true
end

function C.remove_cue_verb(tr)
  local fx = C.find_cue_verb(tr)
  if fx then r.TrackFX_Delete(tr, fx) end
end

---------------------------------------------------------------- listen
-- set of stem ids currently being listened to
function C.listen_state(cues, listen)
  local on = {}
  if not listen then return on end
  for id, cue in pairs(cues) do
    local s = C.find_send(cue, listen)
    if s and r.GetTrackSendInfo_Value(cue, 0, s, "B_MUTE") == 0 then on[id] = true end
  end
  return on
end

-- ids = set of stem ids to listen to; empty table = back to your mix
function C.listen_apply(cues, listen, ids)
  if not listen then return end
  local master = r.GetMasterTrack(0)
  local was = next(C.listen_state(cues, listen)) ~= nil
  local want = next(ids) ~= nil
  if want and not was then
    r.SetProjExtState(0, "FOLDBACK", "master_mute_before",
      tostring(math.floor(r.GetMediaTrackInfo_Value(master, "B_MUTE"))))
  end
  for id, cue in pairs(cues) do
    local s = C.find_send(cue, listen)
    if s then r.SetTrackSendInfo_Value(cue, 0, s, "B_MUTE", ids[id] and 0 or 1) end
  end
  if want then
    r.SetMediaTrackInfo_Value(master, "B_MUTE", 1)
  elseif was then
    local _, prev = r.GetProjExtState(0, "FOLDBACK", "master_mute_before")
    r.SetMediaTrackInfo_Value(master, "B_MUTE", (prev == "1") and 1 or 0)
    r.SetProjExtState(0, "FOLDBACK", "master_mute_before", "")
  end
end

-- Make sure this project has its Listen track, with a muted send from every cue into it.
-- Needs a Listen output in the profile. returns the Listen track, or nil + the reason
function C.ensure_listen(cfg, cues)
  local mon, why = C.listen_index(cfg)
  if not mon then return nil, why end
  local opt = cfg.options or {}
  local _, listen = C.scan()
  r.PreventUIRefresh(1)
  if not listen then
    listen = C.new_track_at_end()
    C.set_ext(listen, C.KEY_LISTEN, "1")
  end
  C.configure_listen(listen, mon, opt.hide_cue_tracks_in_arrange, opt.hide_cue_tracks_in_mixer ~= false)
  for _, cue in pairs(cues) do C.ensure_send(cue, listen, 0.0, C.SENDMODE_POSTFADER, true) end
  r.PreventUIRefresh(-1)
  r.TrackList_AdjustWindows(false)
  return listen
end

---------------------------------------------------------------- undo
-- REAPER doesn't always notice a send/mute change made in the same instant as the undo
-- point is requested, so undo points are committed a moment later (the panel calls
-- C.undo_flush() every frame).
local pending_undo
function C.undo_later(desc)
  if pending_undo and pending_undo.desc ~= desc then C.undo_flush(true) end
  pending_undo = { desc = desc, t = r.time_precise() }
end

function C.undo_flush(force)
  if pending_undo and (force or r.time_precise() - pending_undo.t >= 0.08) then
    local d = pending_undo.desc
    pending_undo = nil
    -- 1 = track config (volume, pan, mute, routing/sends, master), 2 = track FX (cue reverb).
    -- (Plain Undo_OnStateChange only covers media items, so it missed send/mute changes.)
    r.Undo_OnStateChangeEx(d, 1 | 2, -1)
  end
end

function C.raw_name(tr)
  local _, n = r.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
  return n or ""
end

---------------------------------------------------------------- auto-assign
-- Each normal track remembers which stems it has already been checked against
-- (P_EXT:FOLDBACK_SEEN = "drums guitars ..."), so a send you removed on purpose
-- isn't put back, but a stem added later is still offered to matching tracks.
function C.seen_set(tr)
  local t = {}
  for id in (C.get_ext(tr, C.KEY_SEEN) or ""):gmatch("[%w_]+") do
    if id ~= "1" then t[id] = true end   -- "1" = older format, treated as nothing checked
  end
  return t
end

function C.set_seen(tr, set)
  local l = {}
  for k in pairs(set) do l[#l + 1] = k end
  table.sort(l)
  C.set_ext(tr, C.KEY_SEEN, (#l > 0) and table.concat(l, " ") or "1")
end

function C.forget_stem_everywhere(id)
  for i = 0, r.CountTracks(0) - 1 do
    local tr = r.GetTrack(0, i)
    if C.get_ext(tr, C.KEY_SEEN) then
      local s = C.seen_set(tr)
      if s[id] then s[id] = nil; C.set_seen(tr, s) end
    end
  end
end

function C.needs_assign(tr, cues)
  local raw = C.raw_name(tr)
  if raw == "" then return false end
  if C.get_ext(tr, C.KEY_NAME) ~= raw then return true end   -- new name (first time, or renamed)
  local seen = C.seen_set(tr)
  for id in pairs(cues) do if not seen[id] then return true end end
  return false
end

-- Decide and apply the automatic cue send for one track.
-- returns a log message, or nil if nothing new happened
function C.auto_assign(tr, cfg, cues)
  local raw = C.raw_name(tr)
  if raw == "" then return nil end                 -- wait until the track is named
  local seen = C.seen_set(tr)
  local function mark()
    for id in pairs(cues) do seen[id] = true end
    C.set_seen(tr, seen)
    C.set_ext(tr, C.KEY_NAME, raw)
  end
  local opt = cfg.options or {}

  -- Renamed? If the new name belongs to a different stem, move the send this script made.
  local prev = C.get_ext(tr, C.KEY_NAME)
  local carry, removed_from
  if prev and prev ~= raw then
    local old_id = C.get_ext(tr, C.KEY_AUTO)
    local s2 = C.assign_stem(raw, cfg, cues)
    local new_id = s2 and s2.id or nil
    if new_id ~= old_id then
      if old_id and cues[old_id] then
        local oi = C.find_send(tr, cues[old_id])
        if oi then
          carry = { vol = r.GetTrackSendInfo_Value(tr, 0, oi, "D_VOL"),
                    mute = r.GetTrackSendInfo_Value(tr, 0, oi, "B_MUTE") }
          r.RemoveTrackSend(tr, 0, oi)
          removed_from = C.name(cues[old_id])
        end
      end
      C.set_ext(tr, C.KEY_AUTO, "")
      seen = {}                                     -- look at every stem again for the new name
    end
  end

  if opt.skip_folder_tracks and r.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH") == 1 then
    local first = next(cues) and not C.get_ext(tr, C.KEY_SEEN)
    mark()
    return first and "skipped (folder track)" or nil
  end
  local s, why = C.assign_stem(raw, cfg, cues)
  if not s then
    local new = (prev ~= raw)
    for id in pairs(cues) do if not seen[id] then new = true end end
    mark()
    if removed_from then return "renamed: removed send to " .. removed_from .. " (new name: " .. why .. ")" end
    return new and ("no cue send: " .. why) or nil
  end
  if seen[s.id] then
    -- decided before; your edits stand. (Older tracks: remember the send as ours.)
    if not C.get_ext(tr, C.KEY_AUTO) and C.find_send(tr, cues[s.id]) then C.set_ext(tr, C.KEY_AUTO, s.id) end
    mark()
    return nil
  end
  local idx, created = C.ensure_send(tr, cues[s.id], opt.auto_send_db or 0.0, C.send_mode(cfg), false)
  local msg
  if not idx then
    msg = "ERROR: couldn't create send to " .. C.name(cues[s.id])
  elseif created then
    C.set_ext(tr, C.KEY_AUTO, s.id)
    msg = "-> " .. C.name(cues[s.id]) .. " (" .. why .. ")"
    if carry then
      r.SetTrackSendInfo_Value(tr, 0, idx, "D_VOL", carry.vol)
      r.SetTrackSendInfo_Value(tr, 0, idx, "B_MUTE", carry.mute)
      msg = msg .. ", moved from " .. removed_from .. " (renamed; level kept)"
    end
    -- the track's own stem now exists: move it off the fallback cue it was given before
    if s.fallback and cues[s.fallback] and seen[s.fallback] then
      local fi = C.find_send(tr, cues[s.fallback])
      if fi then
        r.RemoveTrackSend(tr, 0, fi)
        msg = msg .. ", moved off " .. C.name(cues[s.fallback]) .. " (was the fallback)"
      end
    end
  else
    msg = "already sends to " .. C.name(cues[s.id])
  end
  mark()
  return msg
end

---------------------------------------------------------------- mix mode
-- Mix mode: does this track still need a look (a cue it hasn't been offered yet)?
function C.mix_needs(tr, cues)
  local seen = C.seen_set(tr)
  for id in pairs(cues) do if not seen[id] then return true end end
  return false
end

-- Mix mode: give a track a send to every cue it hasn't been offered yet, starting at the
-- profile's mix start level (off by default). A send you removed on purpose isn't put back:
-- the track remembers it has already been offered that cue. With mix_new_tracks = "pick"
-- nothing is added (the cues are just remembered, so switching to "all" later only affects
-- tracks made after that). returns a log message, or nil if nothing new happened
function C.mix_assign(tr, cfg, cues)
  local opt = cfg.options or {}
  local seen = C.seen_set(tr)
  local function mark()
    for id in pairs(cues) do seen[id] = true end
    C.set_seen(tr, seen)
  end
  if opt.mix_new_tracks == "pick" then mark() return nil end
  if opt.skip_folder_tracks and r.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH") == 1 then
    mark()
    return nil
  end
  local db = C.new_send_db(cfg)
  local made = {}
  for _, s in ipairs(cfg.stems) do
    local cue = cues[s.id]
    if cue and not seen[s.id] then
      local _, created = C.ensure_send(tr, cue, db, C.send_mode(cfg), false)
      if created then made[#made + 1] = s.name end
    end
  end
  mark()
  if #made > 0 then
    return "-> " .. table.concat(made, ", ") .. " (mix mode; sends start " .. C.fmt_start_db(db) .. ")"
  end
  return nil
end

-- "Start from my mix": copy each track's fader level, pan and mute into its send to this cue.
-- A one-time copy (later fader moves don't reach the cue). Only tracks that already have a
-- send to the cue are changed. tracks = list of the project's own tracks. returns how many
function C.start_from_mix(cue, tracks)
  local n = 0
  for _, tr in ipairs(tracks) do
    local idx = C.find_send(tr, cue)
    if idx then
      r.SetTrackSendInfo_Value(tr, 0, idx, "D_VOL", r.GetMediaTrackInfo_Value(tr, "D_VOL"))
      r.SetTrackSendInfo_Value(tr, 0, idx, "D_PAN", r.GetMediaTrackInfo_Value(tr, "D_PAN"))
      r.SetTrackSendInfo_Value(tr, 0, idx, "B_MUTE", r.GetMediaTrackInfo_Value(tr, "B_MUTE"))
      n = n + 1
    end
  end
  C.mark_busy()
  return n
end

---------------------------------------------------------------- name matching
function C.tokens(name)
  local t = {}
  for w in name:lower():gmatch("%a+") do t[#t + 1] = w end
  return t
end

local function word_matches(w, tk)
  if w:sub(1, 1) == "=" then return tk == w:sub(2) end
  return tk:sub(1, #w) == w
end

-- Is the track name excluded (effect return, bus ...)? returns the word or nil
function C.excluded(name, cfg)
  local toks = C.tokens(name)
  for w in (cfg.exclude or ""):lower():gmatch("%S+") do
    for _, tk in ipairs(toks) do
      if tk == w:gsub("^=", "") then return w end
    end
  end
  return nil
end

-- First rule line (top to bottom) with a word matching any word of the name.
-- returns stem (from config), matched word, or nil
function C.match_rule(name, cfg)
  local toks = C.tokens(name)
  for _, rule in ipairs(cfg.rules or {}) do
    local s = C.stem_by_id(cfg, rule[1])
    if s then
      for w in rule[2]:lower():gmatch("%S+") do
        for _, tk in ipairs(toks) do
          if word_matches(w, tk) then return s, w end
        end
      end
    end
  end
  return nil
end

-- Decide which cue a track should go to in THIS session.
-- cues = stem id -> cue track (stems present in the session)
-- returns stem or nil, plus a short explanation
function C.assign_stem(name, cfg, cues)
  local ex = C.excluded(name, cfg)
  if ex then return nil, "excluded (\"" .. ex .. "\")" end
  local s, w = C.match_rule(name, cfg)
  if not s then return nil, "no rule matched" end
  if cues[s.id] then return s, "matched \"" .. w .. "\"" end
  local fb = s.fallback and C.stem_by_id(cfg, s.fallback)
  if fb and cues[fb.id] then
    return fb, "matched \"" .. w .. "\" (" .. s.name .. " not in session, fallback " .. fb.name .. ")"
  end
  return nil, "matches " .. s.name .. " (\"" .. w .. "\"), but " .. s.name .. " isn't in this session"
end

return C
