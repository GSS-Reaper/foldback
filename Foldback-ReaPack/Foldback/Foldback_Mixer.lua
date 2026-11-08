-- Foldback - Copyright (C) 2026 Greater Society Studios. Free software under the GNU General Public License v3.0 (see LICENSE).
-- @description Foldback: cue mixer panel (with automatic cue sends for new tracks)
-- Left:  one column per cue - name (click = everything feeding it), output,
--        cue level + meter, reverb (if the profile uses it), Listen.
-- Right: the SELECTED tracks, one row each, with their send into every cue,
--        plus an "All selected" row that moves them together.
-- Level controls: drag = adjust, double-click = 0 dB, Shift-click = mute/unmute,
-- right-click = menu. While open, newly NAMED tracks get their cue sends automatically.
local r = reaper
local script_path = ({ r.get_action_context() })[2]
local script_dir = script_path:match("^(.*[/\\])")
local C = dofile(script_dir .. "Foldback_Core.lua")
local TITLE = "Foldback"

if not r.APIExists("ImGui_GetBuiltinPath") then
  r.ShowMessageBox("ReaImGui isn't installed (Extensions > ReaPack > Browse packages).", TITLE, 0)
  return
end
package.path = r.ImGui_GetBuiltinPath() .. '/?.lua'
local ImGui = require 'imgui' '0.10'

local cfg, cerr = C.load_config()
if not cfg then r.ShowMessageBox(cerr, TITLE, 0) return end
local function IS_MIX() return C.is_mix(cfg) end   -- mix mode: each cue is one performer's stereo mix

local ctx   -- created further down, AFTER the slow font lookup (ReaImGui discards a context that sits unused for a moment)
local EXT = "FOLDBACK_MIXER"
local LV_MIN, LV_MAX = -60.0, 12.0
local COL_W = 118     -- cue column width (left section)
local LABEL_W = 80    -- label column (left section)
local SEL_NAME_W = 150
local SEL_W = 92      -- per-cue column width (selected-tracks section)
local PAN_W = 46      -- per-send pan box (mix mode, selected-tracks section)
local SEL_PAD = 6     -- empty padding column at each side of the selected-tracks box (+ cell padding = about 10 px)
local HAS_JS = r.APIExists("JS_Window_SetFocus")

---------------------------------------------------------------- state
local st = {
  proj = nil, cc = -1,
  cues = {}, listen = nil,
  stems = {}, tracks = {},
  detail = nil, open_detail = false, open_settings = false,
  dock_req = nil,
  auto = r.GetExtState(EXT, "auto") ~= "0",
  last_watch = 0,
  shift_drag = nil,     -- id of a control that was Shift-clicked (ignore its drag)
  group = {},           -- stem id -> current offset of the "All selected" drag
  strip_h = 150,
  linked = {}, linked_cue = nil,   -- tracks ticked in the cue pop-up (move together)
  opened = {}, setup_done = {},    -- projects already checked on open / auto-set-up
}

---------------------------------------------------------------- look (built-in; any color can be changed with panel_colors in the profile)
local function rgba(red, green, blue, a) return (red << 24) | (green << 16) | (blue << 8) | (a or 255) end
local LOOK = {}
local THEME_COLORS
-- (re)builds the panel colors from the profile; run at start and again whenever the profile is reloaded or saved
local function build_look()
  for k in pairs(LOOK) do LOOK[k] = nil end
  for _, e in ipairs(C.LOOK_DEFAULTS) do LOOK[e[1]] = rgba(e[2][1], e[2][2], e[2][3]) end
  for k, v in pairs(cfg.panel_colors or {}) do
    if LOOK[k] and type(v) == "table" and #v >= 3 then LOOK[k] = rgba(v[1], v[2], v[3], v[4]) end
  end
  THEME_COLORS = {
    { "Col_WindowBg", LOOK.bg }, { "Col_ChildBg", LOOK.bg }, { "Col_PopupBg", LOOK.popup },
    { "Col_Border", LOOK.divider }, { "Col_Text", LOOK.text }, { "Col_TextDisabled", LOOK.dim },
    { "Col_FrameBg", LOOK.edit }, { "Col_FrameBgHovered", rgba(62, 62, 62) }, { "Col_FrameBgActive", rgba(72, 72, 72) },
    { "Col_TitleBg", LOOK.bg }, { "Col_TitleBgActive", LOOK.bg }, { "Col_TitleBgCollapsed", LOOK.bg },
    { "Col_Button", LOOK.panel }, { "Col_ButtonHovered", rgba(78, 78, 78) }, { "Col_ButtonActive", rgba(92, 92, 92) },
    { "Col_CheckMark", LOOK.teal }, { "Col_SliderGrab", LOOK.teal },
    { "Col_Header", LOOK.teal_dim }, { "Col_HeaderHovered", rgba(45, 125, 110) }, { "Col_HeaderActive", rgba(26, 150, 122) },
    { "Col_Separator", LOOK.divider },
    { "Col_TableHeaderBg", rgba(50, 50, 50) }, { "Col_TableBorderStrong", LOOK.divider }, { "Col_TableBorderLight", rgba(34, 34, 34) },
    { "Col_TableRowBg", rgba(0, 0, 0, 0) }, { "Col_TableRowBgAlt", rgba(255, 255, 255, 9) },
    { "Col_ScrollbarBg", LOOK.well }, { "Col_ScrollbarGrab", rgba(80, 80, 80) },
    { "Col_ResizeGrip", LOOK.teal_dim }, { "Col_DockingEmptyBg", LOOK.bg },
  }
end
build_look()
local THEME_VARS = {
  { "StyleVar_WindowRounding", 3 }, { "StyleVar_FrameRounding", 3 }, { "StyleVar_PopupRounding", 3 },
  { "StyleVar_GrabRounding", 3 }, { "StyleVar_ScrollbarRounding", 3 },
  { "StyleVar_FrameBorderSize", 0 }, { "StyleVar_WindowBorderSize", 0 },
  -- spacing: x values = horizontal (kept as approved), y values = vertical (loosened)
  { "StyleVar_ItemSpacing", 3, 5 }, { "StyleVar_FramePadding", 5, 3 },
  { "StyleVar_WindowPadding", 4, 8 }, { "StyleVar_CellPadding", 2, 4 },
}

---------------------------------------------------------------- font: the one your REAPER theme uses
local function hex_bytes(h)
  local t = {}
  for i = 1, #h - 1, 2 do t[#t + 1] = tonumber(h:sub(i, i + 1), 16) or 0 end
  return t
end

-- reads a theme font entry (a Windows LOGFONT stored as hex): returns family, pixel size
local function decode_font(hex)
  local b = hex_bytes(hex)
  if #b < 60 then return nil end
  local h = b[1] | (b[2] << 8) | (b[3] << 16) | (b[4] << 24)
  if h >= 2 ^ 31 then h = h - 2 ^ 32 end
  local face = {}
  for i = 29, 60 do
    if b[i] == 0 then break end
    face[#face + 1] = string.char(b[i])
  end
  if #face == 0 then return nil end
  return table.concat(face), math.abs(h)
end

local function theme_font()
  local fn = r.GetLastColorThemeFile and r.GetLastColorThemeFile() or ""
  if fn == "" then return nil end
  local txt
  local f = io.open(fn, "rb")
  if f then txt = f:read("a"); f:close() end
  if not txt then   -- packed themes: REAPER reads them straight from the .ReaperThemeZip
    local zip = fn:gsub("%.ReaperTheme$", ".ReaperThemeZip")
    local zf = io.open(zip, "rb")
    if zf and r.ExecProcess then
      zf:close()
      local win = r.GetOS():find("Win", 1, true)
      -- Mac/Linux: unzip. Windows 10 and later ship tar.exe, which can read zip files too.
      local cmd = win and ('tar -xOf "' .. zip .. '" "*.ReaperTheme"')
                      or ("/usr/bin/unzip -p '" .. zip .. "' '*.ReaperTheme'")
      local out = r.ExecProcess(cmd, 5000)
      if out and out:match("^0") then txt = out end
    end
  end
  if not txt then return nil end
  for _, key in ipairs({ "user_font2", "lb_font" }) do   -- the size REAPER uses for track names / labels
    local hex = txt:match("\n" .. key .. "=(%x+)") or txt:match("^" .. key .. "=(%x+)")
    if hex then
      local family, size = decode_font(hex)
      if family then return family, size end
    end
  end
  return nil
end

local FONT, FONT_SIZE
do
  local opt = cfg.options or {}
  local family, size = opt.font, opt.font_size
  if not family then
    local okf, fam, sz = pcall(theme_font)
    if okf then family, size = fam, sz end
  end
  size = math.max(11, math.min(16, tonumber(size) or 12))
  local okc, font = pcall(ImGui.CreateFont, family or "sans-serif")
  ctx = ImGui.CreateContext(TITLE)          -- created last, right before it is first used
  if okc and font then
    local oka = pcall(ImGui.Attach, ctx, font)
    if not oka then                         -- the context was discarded anyway: make a fresh one and retry once
      ctx = ImGui.CreateContext(TITLE)
      oka = pcall(ImGui.Attach, ctx, font)
    end
    if oka then FONT, FONT_SIZE = font, size end
  end
  C.font_used = (family or "sans-serif") .. " " .. size
end

-- push everything this ReaImGui knows about; returns how many of each to pop
local function push_theme()
  local nc, nv = 0, 0
  for _, t in ipairs(THEME_COLORS) do
    local c = ImGui[t[1]]
    if c then ImGui.PushStyleColor(ctx, c, t[2]); nc = nc + 1 end
  end
  for _, t in ipairs(THEME_VARS) do
    local v = ImGui[t[1]]
    if v then ImGui.PushStyleVar(ctx, v, t[2], t[3]); nv = nv + 1 end
  end
  return nc, nv
end

local function stem_rgba(s)
  local c = C.stem_color(s)
  if c then return rgba(c[1], c[2], c[3]) end
  return 0x888888FF
end

-- a lighter shade of an rgba color (for hover)
local function lighten(col, amt)
  local red, green, blue = (col >> 24) & 255, (col >> 16) & 255, (col >> 8) & 255
  local function up(x) return math.min(255, math.floor(x + (255 - x) * amt)) end
  return rgba(up(red), up(green), up(blue))
end

do   -- note which font was chosen (logs/font.txt) so a mismatch is easy to diagnose
  r.RecursiveCreateDirectory(C.logdir, 0)
  local f = io.open(C.logdir .. "/font.txt", "w")
  if f then f:write(os.date("%Y-%m-%d %H:%M:%S") .. "  panel font: " .. tostring(C.font_used) ..
    "  (theme file: " .. tostring(r.GetLastColorThemeFile and r.GetLastColorThemeFile() or "?") .. ")\n") f:close() end
end

local function rescan()
  C.migrate()
  st.cues, st.listen = C.scan()
  st.stems = {}
  for _, s in ipairs(cfg.stems) do
    if st.cues[s.id] then st.stems[#st.stems + 1] = s end
  end
  -- (cues appear in the order they're listed in the profile)
  st.tracks = {}
  for i = 0, r.CountTracks(0) - 1 do
    local tr = r.GetTrack(0, i)
    if not C.is_system(tr) then st.tracks[#st.tracks + 1] = tr end
  end
end

local function all_valid()
  for _, tr in pairs(st.cues) do if not r.ValidatePtr2(0, tr, "MediaTrack*") then return false end end
  for _, tr in ipairs(st.tracks) do if not r.ValidatePtr2(0, tr, "MediaTrack*") then return false end end
  if st.listen and not r.ValidatePtr2(0, st.listen, "MediaTrack*") then return false end
  return true
end

---------------------------------------------------------------- automatic cue sends
local function append_auto_log(line)
  r.RecursiveCreateDirectory(C.logdir, 0)
  local f = io.open(C.logdir .. "/auto.txt", "a")
  if f then f:write(os.date("%Y-%m-%d %H:%M:%S") .. "  " .. line .. "\n") f:close() end
end

local function watch()
  local mix = IS_MIX()
  if not (mix or C.feature(cfg, "name_rules")) or not st.auto or next(st.cues) == nil then return end
  local changed = false
  for _, tr in ipairs(st.tracks) do
    local needs = (mix and C.mix_needs(tr, st.cues)) or (not mix and C.needs_assign(tr, st.cues))
    if needs then
      local msg
      if mix then msg = C.mix_assign(tr, cfg, st.cues) else msg = C.auto_assign(tr, cfg, st.cues) end
      if msg then
        append_auto_log(C.name(tr) .. ": " .. msg)
        if msg:sub(1, 2) == "->" or msg:sub(1, 8) == "renamed:" then changed = true end
      end
    end
  end
  if changed then C.undo_later("Foldback: automatic cue sends") end
end

---------------------------------------------------------------- the level control
-- A fader-style drag box: drag up/down/left/right = adjust (no jumping to the click
-- point), double-click = default, Shift-click = toggle mute, right-click = menu.
-- returns: changed, new_db, shift_clicked, double_clicked
local function level_box(id, db, width, opts)
  opts = opts or {}
  local min, max = opts.min or LV_MIN, opts.max or LV_MAX
  db = math.max(min, math.min(max, db))
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local h = ImGui.GetFrameHeight(ctx)
  local dl = ImGui.GetWindowDrawList(ctx)
  ImGui.DrawList_AddRectFilled(dl, x, y, x + width, y + h, LOOK.well, 3)
  local frac = (db - min) / (max - min)
  local fill = opts.muted and LOOK.muted or (opts.fill or LOOK.teal_dim)
  if frac > 0 then ImGui.DrawList_AddRectFilled(dl, x, y, x + width * frac, y + h, fill, 3) end
  if opts.unity and min < 0 and max > 0 then               -- tick at 0 dB
    local ux = x + width * ((0 - min) / (max - min))
    ImGui.DrawList_AddLine(dl, ux, y, ux, y + h, 0xFFFFFF50, 1)
  end
  ImGui.PushStyleColor(ctx, ImGui.Col_FrameBg, 0x00000000)
  ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgHovered, 0xFFFFFF18)
  ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgActive, 0xFFFFFF28)
  ImGui.SetNextItemWidth(ctx, width)
  local fmt
  if opts.text then fmt = opts.text            -- literal text to show instead of the number (e.g. a pan "L30")
  elseif db <= min then fmt = opts.off_text or "-inf"
  else fmt = (opts.fmt or "%.1f dB") .. (opts.muted and "  M" or "") end
  local ch, v = ImGui.DragDouble(ctx, id, db, opts.speed or 0.2, min, max, fmt,
    ImGui.SliderFlags_NoInput | ImGui.SliderFlags_AlwaysClamp)
  ImGui.PopStyleColor(ctx, 3)
  local shift_clicked, dbl = false, false
  if ImGui.IsItemClicked(ctx, ImGui.MouseButton_Left) and (ImGui.GetKeyMods(ctx) & ImGui.Mod_Shift) ~= 0 then
    shift_clicked = true
    st.shift_drag = id
  end
  if st.shift_drag == id then
    ch = false
    if not ImGui.IsItemActive(ctx) then st.shift_drag = nil end
  end
  if ImGui.IsItemHovered(ctx) and ImGui.IsMouseDoubleClicked(ctx, ImGui.MouseButton_Left) then
    dbl = true
    ch, v = true, (opts.default or 0.0)
  end
  return ch, v, shift_clicked, dbl
end

local send_menu
local HELP = "Drag to adjust (Alt = fine). Double-click = 0 dB. Shift-click = mute/unmute. Right-click = menu."

-- control for one existing send
local function send_control(id, src, idx, width)
  ImGui.PushID(ctx, id)
  local db = C.lin2db(r.GetTrackSendInfo_Value(src, 0, idx, "D_VOL"))
  local muted = r.GetTrackSendInfo_Value(src, 0, idx, "B_MUTE") ~= 0
  local ch, ndb, shift = level_box("##lvl", db, width, { muted = muted, unity = true })
  if shift then
    r.SetTrackSendInfo_Value(src, 0, idx, "B_MUTE", muted and 0 or 1)
    C.mark_busy()
    C.undo_later("Foldback: cue send mute")
  elseif ch then
    r.SetTrackSendInfo_Value(src, 0, idx, "D_VOL", (ndb <= LV_MIN) and 0 or C.db2lin(ndb))
    C.mark_busy()
  end
  if ImGui.IsItemDeactivatedAfterEdit(ctx) then C.undo_later("Foldback: cue send level") end
  if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, HELP) end
  send_menu(src, idx, muted)
  ImGui.PopID(ctx)
end

-- mix mode: pan of one send (L100 ... C ... R100). Double-click = center.
local function pan_text(p)
  local a = math.floor(math.abs(p) + 0.5)
  if a == 0 then return "C" end
  return (p < 0 and "L" or "R") .. a
end

local function pan_control(id, src, idx, width)
  ImGui.PushID(ctx, id)
  local p = r.GetTrackSendInfo_Value(src, 0, idx, "D_PAN") * 100
  local ch, np = level_box("##pan", p, width,
    { min = -100, max = 100, speed = 1.0, text = pan_text(p), fill = 0x00000000, unity = true, default = 0.0 })
  if ch then
    r.SetTrackSendInfo_Value(src, 0, idx, "D_PAN", math.max(-1, math.min(1, np / 100)))
    C.mark_busy()
  end
  if ImGui.IsItemDeactivatedAfterEdit(ctx) then C.undo_later("Foldback: cue send pan") end
  if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, "Pan in this cue. Drag to adjust (Alt = fine). Double-click = center.") end
  ImGui.PopID(ctx)
end

send_menu = function(src, idx, muted)
  if ImGui.BeginPopupContextItem(ctx, "ctx") then
    if ImGui.MenuItem(ctx, "Set to 0 dB") then
      r.SetTrackSendInfo_Value(src, 0, idx, "D_VOL", 1.0); C.mark_busy()
      C.undo_later("Foldback: cue send level")
    end
    if ImGui.MenuItem(ctx, muted and "Unmute send" or "Mute send") then
      r.SetTrackSendInfo_Value(src, 0, idx, "B_MUTE", muted and 0 or 1); C.mark_busy()
      C.undo_later("Foldback: cue send mute")
    end
    if ImGui.MenuItem(ctx, "Remove send") then
      r.RemoveTrackSend(src, 0, idx); C.mark_busy()
      C.undo_later("Foldback: remove cue send")
    end
    ImGui.EndPopup(ctx)
  end
end

local function add_button(id, src, dest, width, label)
  ImGui.PushStyleColor(ctx, ImGui.Col_Button, 0x00000000)
  if ImGui.Button(ctx, (label or "+") .. "##" .. id, width, 0) then
    C.ensure_send(src, dest, IS_MIX() and C.new_send_db(cfg) or 0.0, C.send_mode(cfg), false)
    C.mark_busy()
    C.undo_later("Foldback: add cue send")
  end
  ImGui.PopStyleColor(ctx, 1)
  if ImGui.IsItemHovered(ctx) then
    ImGui.SetTooltip(ctx, "No send. Click to add one at " .. (IS_MIX() and C.fmt_start_db(C.new_send_db(cfg)) or "0 dB") .. ".")
  end
end

local function verb_control(id, cue, width)
  local fx = C.find_cue_verb(cue)
  if not fx then return false end
  local rv = cfg.cue_reverb or {}
  local p = C.find_param(cue, fx, (rv.amount_param or "wet"):lower())
  if not p then ImGui.TextDisabled(ctx, "no amount control") return true end
  local v = C.display_number(cue, fx, p)
  local val = (not v or v == -math.huge) and LV_MIN or v
  local default = -8
  for _, s in ipairs(rv.settings or {}) do
    if s[1]:lower() == (rv.amount_param or "wet"):lower() and type(s[2]) == "number" then default = s[2] end
  end
  local enabled = r.TrackFX_GetEnabled(cue, fx)
  local ch, nv, shift = level_box("##verb" .. id, val, width,
    { max = 0, off_text = "off", muted = not enabled, default = default, fill = rgba(74, 98, 112) })
  if shift then
    r.TrackFX_SetEnabled(cue, fx, not enabled)
    C.undo_later("Foldback: cue reverb bypass")
  elseif ch then
    if nv <= LV_MIN then r.TrackFX_SetParamNormalized(cue, fx, p, 0)
    else C.set_param_display(cue, fx, p, nv) end
  end
  if ImGui.IsItemDeactivatedAfterEdit(ctx) then C.undo_later("Foldback: cue reverb amount") end
  if ImGui.IsItemHovered(ctx) then
    ImGui.SetTooltip(ctx, "Reverb in this cue. Drag to adjust, double-click = default, Shift-click = bypass.\nClick the cue name to turn reverb on/off or open it.")
  end
  return true
end

-- mix mode: one-time copy of every track's fader level, pan and mute into this cue's sends
local function start_cue_from_mix(s, cue)
  local ans = r.ShowMessageBox("Copy every track's fader level, pan and mute from your mix into " .. cfg.options.cue_prefix .. s.name ..
    "?\n\nThis REPLACES the levels, pans and mutes now in this cue. It's a one-time copy: later fader moves won't reach the cue.\n\n(Edit > Undo puts the cue back.)", TITLE, 1)
  if ans ~= 1 then return end
  local n = C.start_from_mix(cue, st.tracks)
  C.undo_later("Foldback: start " .. s.name .. " from my mix")
  st.pop_note = { text = n .. " sends set from your mix.", t = r.time_precise() }
end

local function track_label(tr)
  return math.floor(r.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER")) .. "  " .. C.name(tr)
end

---------------------------------------------------------------- popups
local function detail_popup()
  if st.open_detail then ImGui.OpenPopup(ctx, "cue_detail"); st.open_detail = false end
  if not ImGui.BeginPopup(ctx, "cue_detail") then return end
  local s = st.detail and C.stem_by_id(cfg, st.detail)
  local cue = s and st.cues[s.id]
  if not cue then ImGui.EndPopup(ctx) return end
  ImGui.TextColored(ctx, stem_rgba(s), cfg.options.cue_prefix .. s.name .. "   " .. C.output_label(s))
  if C.feature(cfg, "cue_reverb") then
    local has_verb = C.find_cue_verb(cue) ~= nil
    local chv, nvv = ImGui.Checkbox(ctx, "Reverb in this cue", has_verb)
    if chv then
      if nvv then C.add_cue_verb(cue, cfg.cue_reverb or { plugin = "ReaVerbate" }, nil)
      else C.remove_cue_verb(cue) end
      C.undo_later("Foldback: cue reverb on/off")
    end
    if has_verb then
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, "Open reverb") then
        local fx = C.find_cue_verb(cue)
        if fx then r.TrackFX_Show(cue, fx, 3) end
      end
    end
  end
  if IS_MIX() then
    if ImGui.Button(ctx, "Start from my mix") then start_cue_from_mix(s, cue) end
    if ImGui.IsItemHovered(ctx) then
      ImGui.SetTooltip(ctx, "One-time copy of each track's fader level, pan and mute into this cue,\nas a starting point for this performer's mix. Replaces what's there now.")
    end
    if st.pop_note and r.time_precise() - st.pop_note.t < 8 then
      ImGui.SameLine(ctx)
      ImGui.TextColored(ctx, 0x7FD6A8FF, st.pop_note.text)
    end
  end
  ImGui.Separator(ctx)
  local rows, missing = {}, {}
  for _, tr in ipairs(st.tracks) do
    local idx = C.find_send(tr, cue)
    if idx then rows[#rows + 1] = { tr = tr, idx = idx } else missing[#missing + 1] = tr end
  end
  if st.linked_cue ~= s.id then st.linked, st.linked_cue = {}, s.id end
  ImGui.TextDisabled(ctx, #rows .. " tracks feed this cue. Each level moves only its own track;")
  ImGui.TextDisabled(ctx, "tick tracks to move them together (same dB change, double-click, Shift-click mute).")
  if ImGui.Button(ctx, "Tick all") then for _, row in ipairs(rows) do st.linked[C.guid(row.tr)] = true end end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Tick none") then st.linked = {} end
  local h = math.min(380, (ImGui.GetFrameHeight(ctx) + 8) * #rows + 8)
  local mixp = IS_MIX()
  if ImGui.BeginTable(ctx, "feeds", mixp and 4 or 3, ImGui.TableFlags_RowBg | ImGui.TableFlags_ScrollY | ImGui.TableFlags_SizingFixedFit, mixp and 600 or 490, h) then
    ImGui.TableSetupColumn(ctx, "Link", ImGui.TableColumnFlags_WidthFixed, 24)
    ImGui.TableSetupColumn(ctx, "Track", ImGui.TableColumnFlags_WidthFixed, 210)
    ImGui.TableSetupColumn(ctx, "Level", ImGui.TableColumnFlags_WidthFixed, 230)
    if mixp then ImGui.TableSetupColumn(ctx, "Pan", ImGui.TableColumnFlags_WidthFixed, 90) end
    for _, row in ipairs(rows) do
      local g = C.guid(row.tr)
      ImGui.PushID(ctx, "d" .. g)
      ImGui.TableNextRow(ctx)
      ImGui.TableNextColumn(ctx)
      local chk, nv = ImGui.Checkbox(ctx, "##lk", st.linked[g] == true)
      if chk then st.linked[g] = nv or nil end
      ImGui.TableNextColumn(ctx)
      ImGui.Text(ctx, track_label(row.tr))
      ImGui.TableNextColumn(ctx)
      local vol = r.GetTrackSendInfo_Value(row.tr, 0, row.idx, "D_VOL")
      local db = math.max(LV_MIN, C.lin2db(vol))
      local muted = r.GetTrackSendInfo_Value(row.tr, 0, row.idx, "B_MUTE") ~= 0
      local ch, ndb, shift, dbl = level_box("##lvl", db, 220, { muted = muted, unity = true })
      local targets = { row }
      if st.linked[g] then
        targets = {}
        for _, o in ipairs(rows) do if st.linked[C.guid(o.tr)] then targets[#targets + 1] = o end end
      end
      if shift then
        for _, t in ipairs(targets) do r.SetTrackSendInfo_Value(t.tr, 0, t.idx, "B_MUTE", muted and 0 or 1) end
        C.mark_busy()
        C.undo_later("Foldback: cue send mute")
      elseif dbl then
        for _, t in ipairs(targets) do r.SetTrackSendInfo_Value(t.tr, 0, t.idx, "D_VOL", 1.0) end
        C.mark_busy()
        C.undo_later("Foldback: cue send level")
      elseif ch then
        local k = 10 ^ ((ndb - db) / 20)
        for _, t in ipairs(targets) do
          if t == row then
            r.SetTrackSendInfo_Value(t.tr, 0, t.idx, "D_VOL", (ndb <= LV_MIN) and 0 or C.db2lin(ndb))
          else
            local v = r.GetTrackSendInfo_Value(t.tr, 0, t.idx, "D_VOL")
            r.SetTrackSendInfo_Value(t.tr, 0, t.idx, "D_VOL", math.min(C.db2lin(LV_MAX), v * k))
          end
        end
        C.mark_busy()
      end
      if ImGui.IsItemDeactivatedAfterEdit(ctx) then C.undo_later("Foldback: cue send level") end
      if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, HELP .. (st.linked[g] and "\n(ticked: moves all ticked tracks)" or "")) end
      send_menu(row.tr, row.idx, muted)
      if mixp then
        ImGui.TableNextColumn(ctx)
        pan_control("pan" .. g, row.tr, row.idx, 80)
      end
      ImGui.PopID(ctx)
    end
    ImGui.EndTable(ctx)
  end
  if #missing > 0 then
    ImGui.SetNextItemWidth(ctx, 300)
    if ImGui.BeginCombo(ctx, "##addtrack", "+ Add a track to this cue...") then
      for _, tr in ipairs(missing) do
        if ImGui.Selectable(ctx, track_label(tr) .. "##add" .. C.guid(tr), false) then
          C.ensure_send(tr, cue, IS_MIX() and C.new_send_db(cfg) or 0.0, C.send_mode(cfg), false)
          C.mark_busy()
          C.undo_later("Foldback: add cue send")
        end
      end
      ImGui.EndCombo(ctx)
    end
  end
  ImGui.EndPopup(ctx)
end

local function set_note(text) st.note = { text = text, t = r.time_precise() } end

-- Open the active profile in a text editor. A plain "open this file" does nothing on a Mac
-- that has no app set for .lua files, so on macOS ask for the default text editor (-t).
local function open_config_file()
  local path = cfg.path
  if not r.file_exists(path) then
    set_note("Can't find " .. path)
    return
  end
  local os_name = r.GetOS():lower()
  if os_name:find("osx", 1, true) or os_name:find("mac", 1, true) then
    r.ExecProcess('/usr/bin/open -t "' .. path .. '"', -1)
    set_note("Opening the profile in your default text editor...")
  elseif r.APIExists("CF_ShellExecute") then
    r.CF_ShellExecute(path)
    set_note("Opening the profile...")
  elseif os_name:find("win", 1, true) then
    r.ExecProcess('notepad.exe "' .. path:gsub("/", "\\") .. '"', -1)
    set_note("Opening the profile in Notepad...")
  else
    set_note("Can't open it from here. The file is: " .. path)
  end
end

local function settings_popup()
  if st.open_settings then ImGui.OpenPopup(ctx, "settings"); st.open_settings = false end
  if not ImGui.BeginPopup(ctx, "settings") then return end
  if ImGui.Button(ctx, "Foldback settings...") then
    ImGui.CloseCurrentPopup(ctx)
    dofile(script_dir .. "Foldback_Settings.lua")
  end
  if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, "Cues and their outputs, Listen, options and colors") end
  if ImGui.Button(ctx, "Set up this session (cues and tracks)...") then
    ImGui.CloseCurrentPopup(ctx)
    dofile(script_dir .. "Foldback_Setup.lua")
    st.cc = -1
  end
  if C.feature(cfg, "name_rules") or IS_MIX() then
    local ch, v = ImGui.Checkbox(ctx, IS_MIX() and "Automatic sends to every mix for new tracks" or "Automatic cue sends for newly named tracks", st.auto)
    if ch then st.auto = v; r.SetExtState(EXT, "auto", v and "1" or "0", true) end
  end
  ImGui.Separator(ctx)
  if ImGui.Button(ctx, "Dock in REAPER docker") then st.dock_req = -1 end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Float") then st.dock_req = 0 end
  ImGui.Separator(ctx)
  -- profile chooser
  local profs = C.list_profiles()
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, "Profile:")
  ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, 220)
  if ImGui.BeginCombo(ctx, "##profile", cfg.profile) then
    for _, nm in ipairs(profs) do
      if ImGui.Selectable(ctx, nm, nm == cfg.profile) and nm ~= cfg.profile then
        local old = C.active_profile_name()
        C.set_active_profile(nm)
        local ncfg, err = C.load_config()
        if ncfg then
          cfg = ncfg; st.cc = -1; build_look(); C.apply_limiter_all(cfg)
          set_note("Switched to profile \"" .. nm .. "\". Run Set up this session to apply its outputs to this project.")
        else
          if old then C.set_active_profile(old) end
          C.load_config()
          set_note("Profile \"" .. nm .. "\" has a mistake - kept " .. tostring(old) .. ".")
          r.ShowMessageBox(err, TITLE, 0)
        end
      end
    end
    ImGui.EndCombo(ctx)
  end
  if ImGui.IsItemHovered(ctx) then
    ImGui.SetTooltip(ctx, "Profiles are files in " .. C.profdir .. "\nDuplicate one in Finder/Explorer to make a new profile.")
  end
  if ImGui.Button(ctx, "Open profile file") then open_config_file() end
  ImGui.SameLine(ctx)
  if r.APIExists("CF_ShellExecute") then
    if ImGui.Button(ctx, "Open logs folder") then r.CF_ShellExecute(C.logdir) end
    ImGui.SameLine(ctx)
  end
  if ImGui.Button(ctx, "Reload profile") then
    local ncfg, err = C.load_config()
    if ncfg then
      cfg = ncfg; st.cc = -1; build_look(); C.apply_limiter_all(cfg)
      set_note(string.format("Profile reloaded at %s (%d stems, %d name rules).",
        os.date("%H:%M:%S"), #(cfg.stems or {}), #(cfg.rules or {})))
    else
      set_note("Profile NOT reloaded - it has a mistake. See the message box.")
      r.ShowMessageBox(err, TITLE, 0)
    end
  end
  if st.note and r.time_precise() - st.note.t < 12 then
    ImGui.TextColored(ctx, 0x7FD6A8FF, st.note.text)
  end
  ImGui.TextDisabled(ctx, "Foldback " .. C.VERSION .. "   profile: " .. cfg.path)
  ImGui.EndPopup(ctx)
end

---------------------------------------------------------------- REAPER's metronome settings
-- Opens REAPER's "Show metronome/pre-roll settings" window. The action's number is looked up by its
-- name (once), so nothing here depends on remembering the number; if it can't be found, say how to open it by hand.
local function open_metronome_settings()
  if st.met_cmd == nil then
    st.met_cmd = false
    if r.APIExists("kbd_getTextFromCmd") and r.APIExists("SectionFromUniqueID") then
      local sec = r.SectionFromUniqueID(0)
      local fallback, fallback_txt
      for id = 40000, 43000 do
        local ok, txt = pcall(r.kbd_getTextFromCmd, id, sec)
        if ok and type(txt) == "string" then
          local l = txt:lower()
          if l:find("metronome", 1, true) and l:find("settings", 1, true) then
            if l:find("show", 1, true) and not l:find("toggle", 1, true) then st.met_cmd, st.met_txt = id, txt; break end
            if not fallback and not l:find("toggle", 1, true) then fallback, fallback_txt = id, txt end
          end
        end
      end
      if not st.met_cmd and fallback then st.met_cmd, st.met_txt = fallback, fallback_txt end
    end
    append_auto_log("metronome settings action: " .. tostring(st.met_cmd) .. " " .. tostring(st.met_txt))
  end
  if st.met_cmd then
    -- open it a moment AFTER the click: opened in the same instant, the window opened and was closed again
    -- by the mouse-release that finished the click
    local cmd, t0 = st.met_cmd, r.time_precise()
    local function go()
      if r.time_precise() - t0 < 0.25 then r.defer(go) else r.Main_OnCommand(cmd, 0) end
    end
    r.defer(go)
  else
    r.ShowMessageBox("Foldback couldn't find REAPER's metronome settings action.\n\nOpen them by right-clicking the metronome button on REAPER's toolbar.", "Foldback", 0)
  end
end

---------------------------------------------------------------- left: the cues
local function cues_section()
  local n = #st.stems
  local listening = C.listen_state(st.cues, st.listen)
  -- stems mode: a Click (metronome) entry is not a cue, but it is shown at the end so you can see which output
  -- REAPER's metronome is meant to use (and open REAPER's metronome settings)
  local met = {}
  if not IS_MIX() then for _, m in ipairs(cfg.stems) do if m.metronome then met[#met + 1] = m end end end
  local w = LABEL_W + (n + #met) * COL_W + (n + #met + 1) * 10
  local flags = ImGui.TableFlags_SizingFixedFit | ImGui.TableFlags_BordersInnerV
  if not ImGui.BeginTable(ctx, "cues", n + #met + 1, flags, w, 0) then return end
  ImGui.TableSetupColumn(ctx, "##labels", ImGui.TableColumnFlags_WidthFixed, LABEL_W)
  for _, s in ipairs(st.stems) do ImGui.TableSetupColumn(ctx, s.id, ImGui.TableColumnFlags_WidthFixed, COL_W) end
  for _, m in ipairs(met) do ImGui.TableSetupColumn(ctx, "met_" .. m.id, ImGui.TableColumnFlags_WidthFixed, COL_W) end

  local function row(label, fn, tip, fn_met)
    ImGui.TableNextRow(ctx, 0, ImGui.GetFrameHeight(ctx))   -- every row exactly one control tall
    ImGui.TableNextColumn(ctx)
    ImGui.AlignTextToFramePadding(ctx)
    if type(label) == "function" then label() else ImGui.TextDisabled(ctx, label) end
    if tip and ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, tip) end
    for _, s in ipairs(st.stems) do
      ImGui.TableNextColumn(ctx)
      ImGui.PushID(ctx, s.id)
      fn(s, st.cues[s.id])
      ImGui.PopID(ctx)
    end
    for _, m in ipairs(met) do
      ImGui.TableNextColumn(ctx)
      ImGui.PushID(ctx, "met_" .. m.id)
      if fn_met then fn_met(m) end
      ImGui.PopID(ctx)
    end
  end

  row(function()
    if ImGui.Button(ctx, "Settings", LABEL_W, 0) then st.open_settings = true end
  end, function(s)
    local col = stem_rgba(s)
    ImGui.PushStyleColor(ctx, ImGui.Col_Button, col)
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, lighten(col, 0.18))
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, LOOK.ink)
    if ImGui.Button(ctx, s.name .. "##name", COL_W, 0) then st.detail = s.id; st.open_detail = true end
    ImGui.PopStyleColor(ctx, 3)
    if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, (C.feature(cfg, "cue_reverb") and "Every track feeding this cue, and reverb on/off" or "Every track feeding this cue") .. (IS_MIX() and ". Also: Start from my mix" or "")) end
  end, nil, function(m)
    local mlabel = (m.name and m.name:match("%S")) and m.name or "Metronome"   -- the row's name; "Metronome" unless the user renamed it
    if ImGui.Button(ctx, mlabel .. "##metname", COL_W, 0) then open_metronome_settings() end
    if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, "Click for metronome settings") end
  end)
  row(cfg.device_label or "Output", function(s)
    ImGui.TextDisabled(ctx, C.output_label(s))
  end, "Where this cue plays (chosen in Foldback settings)")
  row("Cue level", function(s, cue)
    local db = C.lin2db(r.GetMediaTrackInfo_Value(cue, "D_VOL"))
    local ch, ndb = level_box("##fader", db, COL_W, { unity = true })
    if ch then
      if (cfg.options or {}).limiter == true then ndb = math.min(ndb, 0.0) end   -- the limiter sits before this fader
      r.SetMediaTrackInfo_Value(cue, "D_VOL", (ndb <= LV_MIN) and 0 or C.db2lin(ndb))
    end
    if ImGui.IsItemDeactivatedAfterEdit(ctx) then C.undo_later("Foldback: cue level") end
    if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, "Whole cue level (what the artists receive). Drag; double-click = 0 dB." .. (((cfg.options or {}).limiter == true) and " The limiter keeps this at 0 dB or lower." or "")) end
    local pk = math.max(r.Track_GetPeakInfo(cue, 0), r.Track_GetPeakInfo(cue, 1))
    local pdb = C.lin2db(pk)
    local frac = (pdb == -math.huge) and 0 or math.min(1, math.max(0, (pdb + 60) / 60))
    local mc = (pdb > -0.5) and LOOK.clip or ((pdb > -12) and LOOK.vu_top or ((pdb > -30) and LOOK.vu_mid or LOOK.vu_low))
    ImGui.PushStyleColor(ctx, ImGui.Col_PlotHistogram, mc)
    ImGui.ProgressBar(ctx, frac, COL_W, 3, "")
    ImGui.PopStyleColor(ctx, 1)
  end)
  if C.feature(cfg, "cue_reverb") then
    row("Reverb", function(s, cue)
      if not verb_control(s.id, cue, COL_W) then ImGui.TextDisabled(ctx, "-") end
    end)
  end
  local function listen_label()
    if (cfg.options or {}).talkback ~= true then ImGui.TextDisabled(ctx, "Listen"); return end
    local down = st.talk
    if down then
      ImGui.PushStyleColor(ctx, ImGui.Col_Button, LOOK.listen_on)
      ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, LOOK.listen_on)
      ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive, LOOK.listen_on)   -- the colour while the mouse is held down
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xFFFFFFFF)
    end
    ImGui.Button(ctx, "Talkback###talk", LABEL_W, 0)   -- "###": the ID must not change with the label, or REAPER drops the hold the moment the label changes
    local held = ImGui.IsItemActive(ctx)
    if down then ImGui.PopStyleColor(ctx, 4) end
    if held ~= (st.talk or false) then
      if held then
        if not C.find_tagged(C.KEY_TALK) then C.ensure_talkback(cfg, st.cues); st.cc = -1 end
        C.talkback_sync_input(cfg)
        C.talkback_set(true)
      else
        C.talkback_set(false)
      end
      st.talk = held
    end
    if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, "Hold the mouse button down to talk into every cue. Let go and the cues close again." .. (C.input_index((cfg.options or {}).talkback_input) and "" or "\n\nNo microphone input is chosen yet (or it was not found): pick one in Settings > Options > Talkback.")) end
  end
  row(listen_label, function(s)
    local on = listening[s.id]
    if on then
      ImGui.PushStyleColor(ctx, ImGui.Col_Button, LOOK.listen_on)
      ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, lighten(LOOK.listen_on, 0.18))
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xFFFFFFFF)
    end
    if ImGui.Button(ctx, (on and "LISTENING" or "Listen") .. "##listen", COL_W, 0) then
      if not st.listen then            -- project made before a Listen output was chosen: add the Listen track now
        local lt, why = C.ensure_listen(cfg, st.cues)
        if lt then
          st.listen = lt
          st.cc = -1
          C.undo_later("Foldback: add Listen track")
        else
          r.ShowMessageBox("Listen can't start: " .. tostring(why), TITLE, 0)
        end
      end
      if st.listen then
        local ids = {}
        if (ImGui.GetKeyMods(ctx) & ImGui.Mod_Shift) ~= 0 then
          for k in pairs(listening) do ids[k] = true end
          if on then ids[s.id] = nil else ids[s.id] = true end
        elseif not on then
          ids[s.id] = true
        end
        C.listen_apply(st.cues, st.listen, ids)
        C.undo_later("Foldback: listen")
      end
    end
    if on then ImGui.PopStyleColor(ctx, 3) end
    if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, "Hear only this cue on your speakers. Click again for your mix. Shift-click to combine cues." .. (st.listen and "" or "\n(This project has no Listen track yet; the first click adds one.)")) end
  end)
  ImGui.EndTable(ctx)
  local _, h = ImGui.GetItemRectSize(ctx)
  if h and h > 40 then st.strip_h = h end
end

---------------------------------------------------------------- right: selected tracks
local function selected_section()
  local sel = {}
  for i = 0, r.CountSelectedTracks(0) - 1 do
    local tr = r.GetSelectedTrack(0, i)
    if not C.is_system(tr) then sel[#sel + 1] = tr end
  end
  local n = #st.stems
  local mixp = IS_MIX()
  local cw = mixp and (SEL_W + 3 + PAN_W) or SEL_W     -- cue column width (mix mode adds a pan box)
  local flags = ImGui.TableFlags_SizingFixedFit | ImGui.TableFlags_RowBg | ImGui.TableFlags_ScrollY
    | ImGui.TableFlags_ScrollX | ImGui.TableFlags_BordersOuter
  -- an empty narrow column at each end = padding inside the box
  if not ImGui.BeginTable(ctx, "sel", n + 3, flags, 0, 0) then return end   -- height 0 = fill the rest of the window
  ImGui.TableSetupScrollFreeze(ctx, 2, 1)
  ImGui.TableSetupColumn(ctx, "##padL", ImGui.TableColumnFlags_WidthFixed, SEL_PAD)
  ImGui.TableSetupColumn(ctx, "##track", ImGui.TableColumnFlags_WidthFixed, SEL_NAME_W)
  for _, s in ipairs(st.stems) do ImGui.TableSetupColumn(ctx, s.id, ImGui.TableColumnFlags_WidthFixed, cw) end
  ImGui.TableSetupColumn(ctx, "##padR", ImGui.TableColumnFlags_WidthFixed, SEL_PAD)

  -- header: cue names in their colors
  -- header row: same height and text position as the cue row on the left, so they line up
  ImGui.TableNextRow(ctx, ImGui.TableRowFlags_Headers, ImGui.GetFrameHeight(ctx))
  ImGui.TableNextColumn(ctx)   -- skip the left padding column
  ImGui.TableNextColumn(ctx)
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, (#sel == 0) and "Selected tracks" or (#sel == 1 and "Selected track" or (#sel .. " selected tracks")))
  for _, s in ipairs(st.stems) do
    ImGui.TableNextColumn(ctx)
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.TextColored(ctx, stem_rgba(s), s.name)
  end

  if #sel == 0 then
    ImGui.TableNextRow(ctx)
    ImGui.TableNextColumn(ctx)   -- skip the left padding column
    ImGui.TableNextColumn(ctx)
    ImGui.TextDisabled(ctx, "Select tracks to see their cue sends")
    ImGui.EndTable(ctx)
    return
  end

  -- "All selected": moves every selected track's send to that cue by the same amount
  if #sel > 1 then
    ImGui.TableNextRow(ctx, 0, ImGui.GetFrameHeight(ctx))
    ImGui.TableNextColumn(ctx)   -- skip the left padding column
    ImGui.TableNextColumn(ctx)
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.TextColored(ctx, 0xFFFFFFFF, "All selected")
    if ImGui.IsItemHovered(ctx) then
      ImGui.SetTooltip(ctx, "Drag to move every selected track's send into that cue by the same amount.\nDouble-click = all to 0 dB. Shift-click = mute/unmute them all.")
    end
    for _, s in ipairs(st.stems) do
      ImGui.TableNextColumn(ctx)
      local cue = st.cues[s.id]
      local list, any_unmuted = {}, false
      for _, tr in ipairs(sel) do
        local idx = C.find_send(tr, cue)
        if idx then
          list[#list + 1] = { tr = tr, idx = idx }
          if r.GetTrackSendInfo_Value(tr, 0, idx, "B_MUTE") == 0 then any_unmuted = true end
        end
      end
      if #list == 0 then
        ImGui.TextDisabled(ctx, "-")
      else
        ImGui.PushID(ctx, "grp" .. s.id)
        local cur = st.group[s.id] or 0
        local ch, nv, shift, dbl = level_box("##grp", cur, SEL_W,
          { min = -30, max = 30, fmt = "%+.1f dB", off_text = "-30.0 dB", fill = 0x00000000, unity = true,
            muted = not any_unmuted, default = 0 })
        if shift then
          for _, e in ipairs(list) do r.SetTrackSendInfo_Value(e.tr, 0, e.idx, "B_MUTE", any_unmuted and 1 or 0) end
          C.mark_busy()
          C.undo_later("Foldback: mute selected cue sends")
        elseif dbl then
          for _, e in ipairs(list) do r.SetTrackSendInfo_Value(e.tr, 0, e.idx, "D_VOL", 1.0) end
          C.mark_busy()
          st.group[s.id] = 0
          C.undo_later("Foldback: selected cue sends to 0 dB")
        elseif ch then
          local delta = nv - cur
          local k = 10 ^ (delta / 20)
          for _, e in ipairs(list) do
            local v = r.GetTrackSendInfo_Value(e.tr, 0, e.idx, "D_VOL")
            r.SetTrackSendInfo_Value(e.tr, 0, e.idx, "D_VOL", math.min(C.db2lin(LV_MAX), v * k))
          end
          C.mark_busy()
          st.group[s.id] = nv
        end
        if ImGui.IsItemDeactivated(ctx) then
          if (st.group[s.id] or 0) ~= 0 then C.undo_later("Foldback: move selected cue sends") end
          st.group[s.id] = 0
        end
        ImGui.PopID(ctx)
      end
    end
  end

  for _, tr in ipairs(sel) do
    ImGui.TableNextRow(ctx, 0, ImGui.GetFrameHeight(ctx))
    ImGui.TableNextColumn(ctx)   -- skip the left padding column
    ImGui.TableNextColumn(ctx)
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, track_label(tr))
    local g = C.guid(tr)
    for _, s in ipairs(st.stems) do
      ImGui.TableNextColumn(ctx)
      local cue = st.cues[s.id]
      local idx = C.find_send(tr, cue)
      if idx then
        send_control("s" .. g .. s.id, tr, idx, SEL_W)
        if mixp then
          ImGui.SameLine(ctx, 0, 3)
          pan_control("p" .. g .. s.id, tr, idx, PAN_W)
        end
      else add_button("a" .. g .. s.id, tr, cue, cw) end
    end
  end
  ImGui.EndTable(ctx)
end

---------------------------------------------------------------- keyboard: keep REAPER's shortcuts working
local function keyboard_passthrough()
  if not ImGui.IsWindowFocused(ctx, ImGui.FocusedFlags_RootAndChildWindows) then return end
  if ImGui.IsAnyItemActive(ctx) then return end
  if ImGui.IsPopupOpen(ctx, "", ImGui.PopupFlags_AnyPopupId) then return end
  if HAS_JS then
    -- hand the keyboard straight back to REAPER whenever nothing in the panel needs it,
    -- so every REAPER shortcut (Space, ?, ...) keeps working
    if not ImGui.IsMouseDown(ctx, ImGui.MouseButton_Left) and not ImGui.IsMouseDown(ctx, ImGui.MouseButton_Right) then
      r.JS_Window_SetFocus(r.GetMainHwnd())
    end
    return
  end
  if ImGui.IsKeyPressed(ctx, ImGui.Key_Space, false) then
    r.Main_OnCommand(40044, 0)              -- fallback: Transport: Play/stop
  end
end

---------------------------------------------------------------- main loop
r.atexit(function() pcall(C.talkback_set, false) end)   -- never leave the talkback open

local function frame()
  local proj = r.EnumProjects(-1)
  local cc = r.GetProjectStateChangeCount(0)
  if proj ~= st.proj or cc ~= st.cc or not all_valid() then
    st.proj, st.cc = proj, cc
    rescan()
    if not st.opened[proj] then
      st.opened[proj] = true
      local opt = cfg.options or {}
      C.talkback_set(false)
      -- Listen saved "on" with the project: switch it off so the master isn't left muted
      if opt.listen_off_on_open ~= false and st.listen and next(C.listen_state(st.cues, st.listen)) then
        C.listen_apply(st.cues, st.listen, {})
        append_auto_log("project opened with Listen on: switched it off (master mute restored)")
      end
      -- cue tracks stay out of REAPER's own mixer (this panel is their mixer)
      if opt.hide_cue_tracks_in_mixer ~= false then
        local touched = false
        for _, tr in pairs(st.cues) do
          if r.GetMediaTrackInfo_Value(tr, "B_SHOWINMIXER") ~= 0 then r.SetMediaTrackInfo_Value(tr, "B_SHOWINMIXER", 0); touched = true end
        end
        if st.listen and r.GetMediaTrackInfo_Value(st.listen, "B_SHOWINMIXER") ~= 0 then
          r.SetMediaTrackInfo_Value(st.listen, "B_SHOWINMIXER", 0); touched = true
        end
        if touched then r.TrackList_AdjustWindows(false) end
      end
      -- brand-new, unsaved, empty project: create the default cue stems automatically
      local _, fn = r.EnumProjects(-1, "")
      if opt.auto_setup_new_projects ~= false and #st.stems == 0 and r.CountTracks(0) == 0
         and (fn == nil or fn == "") and not st.setup_done[proj] then
        st.setup_done[proj] = true
        FOLDBACK_SILENT = opt.default_stems or "Drums Bass Guitars Vocals"
        local ok2, err2 = pcall(dofile, script_dir .. "Foldback_Setup.lua")
        FOLDBACK_SILENT = nil
        append_auto_log(ok2 and "new empty project: default stems created" or ("auto setup failed: " .. tostring(err2)))
        st.cc = -1                                  -- force a rescan next frame
      end
    end
  end
  C.undo_flush()
  local now = r.time_precise()
  if now - st.last_watch > 0.5 then
    st.last_watch = now
    watch()
  end
  do
    local sig = r.GetExtState("Foldback", "profile_changed")
    if sig ~= "" and sig ~= st.profile_sig then
      local first = (st.profile_sig == nil)
      st.profile_sig = sig
      if not first then
        local ncfg = C.load_config()
        if ncfg then cfg = ncfg; st.cc = -1; build_look(); C.apply_limiter_all(cfg) end
      end
    end
  end
  if st.dock_req then
    ImGui.SetNextWindowDockID(ctx, st.dock_req)
    st.dock_req = nil
  end
  ImGui.SetNextWindowSize(ctx, 1400, 210, ImGui.Cond_FirstUseEver)
  if FONT then ImGui.PushFont(ctx, FONT, FONT_SIZE) end
  local nc, nv = push_theme()
  local visible, open = ImGui.Begin(ctx, TITLE, true, ImGui.WindowFlags_NoCollapse)
  if visible then
    local gutter = C.LEFT_GUTTER
    if gutter > 0 then ImGui.Indent(ctx, gutter) end   -- extra dead space on the left edge only
    if #st.stems == 0 then
      if ImGui.Button(ctx, "Settings") then st.open_settings = true end
      ImGui.SameLine(ctx)
      ImGui.Text(ctx, "No cues in this project yet. Settings > Set up this session.")
    else
      cues_section()
      ImGui.SameLine(ctx, 0, 18)
      selected_section()
    end
    if gutter > 0 then ImGui.Unindent(ctx, gutter) end
    detail_popup()
    settings_popup()
    keyboard_passthrough()
    ImGui.End(ctx)
  end
  ImGui.PopStyleVar(ctx, nv)
  ImGui.PopStyleColor(ctx, nc)
  if FONT then ImGui.PopFont(ctx) end
  return open
end

local function loop()
  local ok, res = xpcall(frame, debug.traceback)
  if not ok then
    r.RecursiveCreateDirectory(C.logdir, 0)
    local f = io.open(C.logdir .. "/mixer_error.txt", "w")
    if f then f:write(os.date("%Y-%m-%d %H:%M:%S") .. "\n" .. tostring(res) .. "\n") f:close() end
    r.ShowMessageBox("Foldback hit an error and closed.\nDetails were saved to:\n" .. C.logdir .. "/mixer_error.txt", TITLE, 0)
    return
  end
  if res then r.defer(loop) else C.undo_flush(true) end
end

r.defer(loop)
