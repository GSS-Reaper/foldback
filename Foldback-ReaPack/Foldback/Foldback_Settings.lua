-- Foldback - Copyright (C) 2026 Franktree. Free software under the GNU General Public License v3.0 (see LICENSE).
-- @description Foldback: settings (cues and their outputs, Listen, options, colors)
-- Edits the ACTIVE profile (Foldback/profiles/<name>.lua) through menus, so nobody has to
-- edit the file by hand. Nothing is written until you press Save.
local r = reaper
local script_dir = ({ r.get_action_context() })[2]:match("^(.*[/\\])")
local C = dofile(script_dir .. "Foldback_Core.lua")
local TITLE = "Foldback settings"

if not r.APIExists("ImGui_GetBuiltinPath") then
  r.ShowMessageBox("Foldback settings needs the ReaImGui extension.\n\nInstall it with Extensions > ReaPack > Browse packages (search for ReaImGui), then restart REAPER.", TITLE, 0)
  return
end
if rawget(_G, "FOLDBACK_SETTINGS_OPEN") then return end   -- already open from the panel
package.path = r.ImGui_GetBuiltinPath() .. '/?.lua'
local ImGui = require 'imgui' '0.10'
local ctx   -- the window's ImGui context (created at the bottom, used by every helper)

---------------------------------------------------------------- state
local S = {
  ed = nil,             -- the profile being edited (a copy)
  saved = "",           -- its text as last loaded/saved (to spot unsaved changes)
  legacy = false,       -- true = editing the older single Foldback_Config.lua
  modal = nil,          -- "name" / "delete" / "unsaved"
  modal_open = false,
  name_mode = nil,      -- "new" / "duplicate" / "rename"
  name_buf = "",
  then_do = nil,        -- what to do after the unsaved-changes question
  msg = nil, msg_t = 0, msg_bad = false,
  new_stem = "",
  tester = "Gtr Room",
  quit = false,
}
local outs = {}         -- { i = 0-based output index, name = "X16 9" }
local name_count = {}

local function note(t, bad) S.msg, S.msg_t, S.msg_bad = t, r.time_precise(), bad end

local function deepcopy(t)
  if type(t) ~= "table" then return t end
  local o = {}
  for k, v in pairs(t) do o[k] = deepcopy(v) end
  return o
end

local function refresh_outputs()
  outs, name_count = {}, {}
  for i = 0, r.GetNumAudioOutputs() - 1 do
    local nm = r.GetOutputChannelName(i) or ("Output " .. (i + 1))
    outs[#outs + 1] = { i = i, name = nm }
    name_count[nm] = (name_count[nm] or 0) + 1
  end
end

local function text_now() return C.profile_text(S.ed, "") end
local function dirty() return S.ed ~= nil and text_now() ~= S.saved end

local function signal() r.SetExtState("Foldback", "profile_changed", tostring(r.time_precise()), false) end

local function load_active()
  local cfg, err = C.load_config()
  if not cfg then
    r.ShowMessageBox(err, TITLE, 0)
    return false
  end
  S.ed = deepcopy(cfg)
  S.ed.panel_colors = S.ed.panel_colors or {}
  S.ed.cue_reverb = S.ed.cue_reverb or { enabled = false, on_cues = "", plugin = "ReaVerbate", settings = {}, amount_param = "wet" }
  S.ed.cue_reverb.settings = S.ed.cue_reverb.settings or {}
  S.legacy = not (cfg.path:sub(1, #C.profdir) == C.profdir)
  S.saved = text_now()
  return true
end

---------------------------------------------------------------- small helpers
local function rgb_int(c) c = c or { 128, 128, 128 }; return ((c[1] & 255) << 16) | ((c[2] & 255) << 8) | (c[3] & 255) end
local function int_rgb(n) return { (n >> 16) & 255, (n >> 8) & 255, n & 255 } end
local RED, ORANGE, GREEN = 0xFF6A6AFF, 0xFFB050FF, 0x7FD6A8FF

local function help(t)
  ImGui.SameLine(ctx)
  ImGui.TextDisabled(ctx, "(?)")
  if ImGui.IsItemHovered(ctx) then
    ImGui.BeginTooltip(ctx)
    ImGui.PushTextWrapPos(ctx, 380)
    ImGui.Text(ctx, t)
    ImGui.PopTextWrapPos(ctx)
    ImGui.EndTooltip(ctx)
  end
end

local function out_label(i)
  local o = outs[i + 1]
  return o and string.format("%d: %s", i + 1, o.name) or ("REAPER output " .. (i + 1))
end

local function stored_label(v)
  if v == nil then return "(none)" end
  local idx = C.output_index(v)
  if idx then return out_label(idx) end
  return "NOT FOUND: " .. tostring(v)
end

-- what to store for an output: its name, or its number if two outputs share the name
local function store_value(o)
  if name_count[o.name] == 1 then return o.name end
  return o.i + 1
end

-- dropdown of REAPER outputs. stereo = choose the first output of a pair
local function output_combo(id, v, width, stereo, none_label)
  local changed, nv = false, v
  local preview = stored_label(v)
  if v == nil and none_label then preview = none_label end
  if stereo and v ~= nil then
    local idx = C.output_index(v)
    if idx and outs[idx + 2] then preview = string.format("%d/%d: %s + %s", idx + 1, idx + 2, outs[idx + 1].name, outs[idx + 2].name) end
  end
  ImGui.SetNextItemWidth(ctx, width)
  if ImGui.BeginCombo(ctx, id, preview, ImGui.ComboFlags_HeightLarge) then
    if ImGui.Selectable(ctx, none_label or "(none)", v == nil) then changed, nv = true, nil end
    local cur = C.output_index(v)
    for k, o in ipairs(outs) do
      local lab
      if stereo then
        local o2 = outs[k + 1]
        if o2 then lab = string.format("%d/%d: %s + %s", o.i + 1, o.i + 2, o.name, o2.name) end
      else
        lab = out_label(o.i)
      end
      if lab and ImGui.Selectable(ctx, lab .. "##o" .. o.i, cur == o.i) then changed, nv = true, store_value(o) end
    end
    ImGui.EndCombo(ctx)
  end
  return changed, nv
end

local function stem_combo(id, cur_id, width, allow_none, skip_id)
  local changed, nv = false, cur_id
  local s = cur_id and C.stem_by_id(S.ed, cur_id)
  ImGui.SetNextItemWidth(ctx, width)
  if ImGui.BeginCombo(ctx, id, s and s.name or (allow_none and "(nothing)" or "(choose)")) then
    if allow_none and ImGui.Selectable(ctx, "(nothing)", cur_id == nil) then changed, nv = true, nil end
    for _, st in ipairs(S.ed.stems) do
      if not st.metronome and st.id ~= skip_id then
        if ImGui.Selectable(ctx, st.name .. "##" .. st.id, st.id == cur_id) then changed, nv = true, st.id end
      end
    end
    ImGui.EndCombo(ctx)
  end
  return changed, nv
end

local function id_set(str)
  local t = {}
  for w in (str or ""):gmatch("%S+") do
    local s = C.stem_by_name(S.ed, w)
    if s then t[s.id] = true end
  end
  return t
end

local function set_to_str(set)
  local l = {}
  for _, s in ipairs(S.ed.stems) do if set[s.id] then l[#l + 1] = s.id end end
  return table.concat(l, " ")
end

local function move(list, i, d)
  local j = i + d
  if j < 1 or j > #list then return end
  list[i], list[j] = list[j], list[i]
end

---------------------------------------------------------------- problems with the profile
local function problems()
  local ed = S.ed
  local bad, warn = {}, {}
  local used = {}
  for _, s in ipairs(ed.stems) do
    if (s.name or ""):match("^%s*$") then bad[#bad + 1] = "A cue has no name." end
    local _, why, unassigned = C.stem_output(ed, s)
    if why and not unassigned then warn[#warn + 1] = why .. "." end
    for o in pairs(C.stem_out_set(s)) do
      if used[o] then warn[#warn + 1] = "REAPER output " .. (o + 1) .. " is used by both " .. used[o] .. " and " .. s.name .. " (they can't both be in one session)." end
      used[o] = used[o] or s.name
    end
  end
  if ed.monitor_output ~= nil and not C.output_index(ed.monitor_output) then
    warn[#warn + 1] = "Listen output '" .. tostring(ed.monitor_output) .. "' isn't one of this computer's outputs."
  end
  return bad, warn
end

---------------------------------------------------------------- tab: cues
local EXAMPLE_MIXES = {
  { id = "artist1", name = "Artist 1", width = "stereo", ui_color = { 116, 128, 180 } },
  { id = "artist2", name = "Artist 2", width = "stereo", ui_color = { 169, 157,  96 } },
  { id = "artist3", name = "Artist 3", width = "stereo", ui_color = { 166,  92,  89 } },
  { id = "artist4", name = "Artist 4", width = "stereo", ui_color = { 148, 116, 180 } },
}

local function tab_cues()
  local ed = S.ed
  local MIX = C.is_mix(ed)
  local NAMES = C.feature(ed, "name_rules") and not MIX
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, "Cue type:")
  ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, 330)
  if ImGui.BeginCombo(ctx, "##cuemode", MIX and "Mixes (one stereo mix per performer)" or "Stems (groups of instruments)") then
    if ImGui.Selectable(ctx, "Stems (groups of instruments)", not MIX) and MIX then
      ed.cue_mode = "stems"
      note("Cue type: stems. Cue widths stay as they are now; set any you want mono in the list below.")
    end
    if ImGui.Selectable(ctx, "Mixes (one stereo mix per performer)", MIX) and not MIX then
      ed.cue_mode = "mix"
      for _, st in ipairs(ed.stems) do if not st.metronome then st.width = "stereo" end end
      note("Cue type: mixes. Every cue is now stereo. Rename the cues below to your performers (or use the Artist 1-4 button).")
    end
    ImGui.EndCombo(ctx)
  end
  help("Stems: each cue is a group of instruments (Drums, Guitars...) and the musician blends the groups on a personal mixer. Mixes: each cue is one performer's complete stereo mix; every track can feed every mix, and you set the levels and pans for each performer.")
  ImGui.Spacing(ctx)
  if MIX then
    ImGui.TextWrapped(ctx, "Each cue is one performer's headphone mix (always stereo). Choose which REAPER outputs it plays from. In the panel, every track gets a send to every mix, and you set each performer's levels and pans. \"Set up this session\" picks which mixes a session uses.")
  else
    ImGui.TextWrapped(ctx, "Each cue is a headphone feed: choose whether it's stereo or mono and which REAPER output it plays from. Pick which cues a session uses, and which tracks feed them, with \"Set up this session\" in the panel.")
  end
  ImGui.Spacing(ctx)
  local defaults = id_set(ed.options.default_stems)
  local remove
  local ncols = NAMES and 8 or 7
  local flags = ImGui.TableFlags_RowBg | ImGui.TableFlags_BordersInnerH | ImGui.TableFlags_SizingFixedFit
  if ImGui.BeginTable(ctx, "cues", ncols, flags) then
    ImGui.TableSetupColumn(ctx, "Order", ImGui.TableColumnFlags_WidthFixed, 52)
    ImGui.TableSetupColumn(ctx, "Color", ImGui.TableColumnFlags_WidthFixed, 40)
    ImGui.TableSetupColumn(ctx, "Name", ImGui.TableColumnFlags_WidthFixed, 120)
    ImGui.TableSetupColumn(ctx, "Type", ImGui.TableColumnFlags_WidthFixed, 140)
    ImGui.TableSetupColumn(ctx, "Output", ImGui.TableColumnFlags_WidthFixed, 300)
    if NAMES then ImGui.TableSetupColumn(ctx, "If not in session, use", ImGui.TableColumnFlags_WidthFixed, 150) end
    ImGui.TableSetupColumn(ctx, "New projects", ImGui.TableColumnFlags_WidthFixed, 90)
    ImGui.TableSetupColumn(ctx, "", ImGui.TableColumnFlags_WidthFixed, 70)
    ImGui.TableHeadersRow(ctx)
    for i, s in ipairs(ed.stems) do
      ImGui.PushID(ctx, "cue" .. i)
      ImGui.TableNextRow(ctx)
      ImGui.TableNextColumn(ctx)
      if ImGui.ArrowButton(ctx, "up", ImGui.Dir_Up) then move(ed.stems, i, -1) end
      ImGui.SameLine(ctx, 0, 2)
      if ImGui.ArrowButton(ctx, "dn", ImGui.Dir_Down) then move(ed.stems, i, 1) end
      ImGui.TableNextColumn(ctx)
      if s.metronome then
        ImGui.AlignTextToFramePadding(ctx); ImGui.TextDisabled(ctx, "-")
      else
        local chc, col = ImGui.ColorEdit3(ctx, "##col", rgb_int(C.stem_color(s)), ImGui.ColorEditFlags_NoInputs)
        if chc then s.ui_color = int_rgb(col) end
      end
      ImGui.TableNextColumn(ctx)
      ImGui.SetNextItemWidth(ctx, 112)
      local chn, nv = ImGui.InputText(ctx, "##name", s.name)
      if chn then s.name = nv end
      ImGui.TableNextColumn(ctx)
      local kind = s.metronome and "Click (metronome)" or (s.width == "stereo" and "Stereo" or "Mono")
      ImGui.SetNextItemWidth(ctx, 132)
      if ImGui.BeginCombo(ctx, "##type", kind) then
        if ImGui.Selectable(ctx, "Stereo", kind == "Stereo") then s.width = "stereo"; s.metronome = nil end
        if not MIX and ImGui.Selectable(ctx, "Mono", kind == "Mono") then s.width = "mono"; s.metronome = nil end
        if ImGui.Selectable(ctx, "Click (metronome)", s.metronome == true) then s.width = "mono"; s.metronome = true end
        ImGui.EndCombo(ctx)
      end
      if ImGui.IsItemHovered(ctx) and s.metronome then
        ImGui.SetTooltip(ctx, "Not a cue track: Foldback only keeps this output free so no cue is put on it.\nPoint REAPER's metronome output at it in REAPER's metronome settings.")
      end
      ImGui.TableNextColumn(ctx)
      local v0 = s.output
      local missing = v0 ~= nil and not C.output_index(v0)
      if missing then ImGui.PushStyleColor(ctx, ImGui.Col_Text, RED) end
      local cho, no = output_combo("##out", v0, 290, s.width == "stereo")
      if missing then ImGui.PopStyleColor(ctx) end
      if cho then s.output = no end
      if NAMES then
        ImGui.TableNextColumn(ctx)
        if s.metronome then
          ImGui.TextDisabled(ctx, "-")
        else
          local chf, fb = stem_combo("##fb", s.fallback, 142, true, s.id)
          if chf then s.fallback = fb end
        end
      end
      ImGui.TableNextColumn(ctx)
      if not s.metronome then
        local chd, dv = ImGui.Checkbox(ctx, "##def", defaults[s.id] == true)
        if chd then defaults[s.id] = dv or nil; ed.options.default_stems = set_to_str(defaults) end
        if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, "Ticked to start with in \"Set up this session\", and given to new empty projects\nwhen \"Set up new projects automatically\" is on (Options).") end
      end
      ImGui.TableNextColumn(ctx)
      if ImGui.SmallButton(ctx, "Remove") then remove = i end
      ImGui.PopID(ctx)
    end
    ImGui.EndTable(ctx)
  end

  if remove then
    local s = table.remove(ed.stems, remove)
    local n_rules = 0
    for k = #(ed.rules or {}), 1, -1 do
      if ed.rules[k][1] == s.id then table.remove(ed.rules, k); n_rules = n_rules + 1 end
    end
    for _, o in ipairs(ed.stems) do if o.fallback == s.id then o.fallback = nil end end
    local d = id_set(ed.options.default_stems); d[s.id] = nil; ed.options.default_stems = set_to_str(d)
    note("Removed " .. s.name .. (n_rules > 0 and (" and its " .. n_rules .. " track-name rule(s)") or "") ..
      ". Not saved yet: Revert brings it back. Projects that already have this cue keep their cue track.")
  end

  ImGui.Spacing(ctx)
  ImGui.SetNextItemWidth(ctx, 160)
  local _, nb = ImGui.InputTextWithHint(ctx, "##newcue", "New cue name", S.new_stem)
  S.new_stem = nb
  ImGui.SameLine(ctx)
  local nm = S.new_stem:match("^%s*(.-)%s*$")
  ImGui.BeginDisabled(ctx, nm == "")
  if ImGui.Button(ctx, "Add cue") then
    local id = C.new_stem_id(ed, nm)
    ed.stems[#ed.stems + 1] = { id = id, name = nm, width = MIX and "stereo" or "mono", ui_color = { 150, 150, 150 } }
    S.new_stem = ""
    note("Added " .. nm .. ". Choose its output in the list above.")
  end
  ImGui.EndDisabled(ctx)
  if MIX then
    ImGui.SameLine(ctx, 0, 24)
    if ImGui.Button(ctx, "Replace cues with Artist 1-4") then
      local keep = {}
      for _, st in ipairs(ed.stems) do if st.metronome then keep[#keep + 1] = st end end
      ed.stems = deepcopy(EXAMPLE_MIXES)
      for _, st in ipairs(keep) do ed.stems[#ed.stems + 1] = st end
      ed.options.default_stems = "artist1 artist2 artist3 artist4"
      note("Cues replaced with Artist 1 to Artist 4. Choose each one's output above. Not saved yet: Revert brings the old list back.")
    end
    help("Replaces the cue list with four mixes named Artist 1 to Artist 4 (the click entry, if any, is kept). You can rename, add and remove cues afterwards.")
  end
  ImGui.SameLine(ctx, 0, 24)
  if ImGui.Button(ctx, "Refresh output list") then refresh_outputs(); note("Output list refreshed (" .. #outs .. " outputs).") end
  help("Use this after changing your audio device, or renaming outputs in REAPER's Preferences > Audio > Device.")

  local bad, warn = problems()
  if #bad + #warn > 0 then
    ImGui.Spacing(ctx)
    for _, t in ipairs(bad) do ImGui.TextColored(ctx, RED, t) end
    for _, t in ipairs(warn) do ImGui.TextColored(ctx, ORANGE, t) end
  end

  ImGui.Spacing(ctx)
  ImGui.SeparatorText(ctx, "Listen")
  ImGui.TextWrapped(ctx, "Listen plays one cue on your speakers so you hear what the musicians hear. By default it uses the same outputs as your master track.")
  local mi = C.master_out_index()
  local follow = (mi and outs[mi + 2]) and string.format("Same as master (%d/%d: %s + %s)", mi + 1, mi + 2, outs[mi + 1].name, outs[mi + 2].name) or "Same as master (no master output found)"
  local chm, mm = output_combo("Speaker outputs##mon", ed.monitor_output, 330, true, follow)
  if chm then ed.monitor_output = mm end
  help("By default Listen plays on whatever output pair your master track plays to (your speakers). Pick a different pair here only if your speakers are on another output.")
end

---------------------------------------------------------------- tab: track names
local function tab_names()
  local ed = S.ed
  ImGui.TextWrapped(ctx, "When a track is named, Foldback sends it to a cue using these rules, checked from the top: the first line with a matching word wins. A word matches the START of any word in the track name (\"gtr\" matches \"Gtrs\"). Put = in front for an exact whole word (\"=kit\" won't match \"Kitchen\"). Upper/lower case doesn't matter.")
  ImGui.Spacing(ctx)
  local remove
  local flags = ImGui.TableFlags_RowBg | ImGui.TableFlags_BordersInnerH | ImGui.TableFlags_SizingFixedFit
  if ImGui.BeginTable(ctx, "rules", 4, flags) then
    ImGui.TableSetupColumn(ctx, "#", ImGui.TableColumnFlags_WidthFixed, 24)
    ImGui.TableSetupColumn(ctx, "Order", ImGui.TableColumnFlags_WidthFixed, 52)
    ImGui.TableSetupColumn(ctx, "Cue", ImGui.TableColumnFlags_WidthFixed, 130)
    ImGui.TableSetupColumn(ctx, "Words (separated by spaces)", ImGui.TableColumnFlags_WidthStretch)
    ImGui.TableHeadersRow(ctx)
    for i, rl in ipairs(ed.rules) do
      ImGui.PushID(ctx, "rule" .. i)
      ImGui.TableNextRow(ctx)
      ImGui.TableNextColumn(ctx)
      ImGui.AlignTextToFramePadding(ctx)
      ImGui.Text(ctx, tostring(i))
      ImGui.TableNextColumn(ctx)
      if ImGui.ArrowButton(ctx, "up", ImGui.Dir_Up) then move(ed.rules, i, -1) end
      ImGui.SameLine(ctx, 0, 2)
      if ImGui.ArrowButton(ctx, "dn", ImGui.Dir_Down) then move(ed.rules, i, 1) end
      ImGui.TableNextColumn(ctx)
      local chs, sid = stem_combo("##stem", rl[1], 122, false)
      if chs then rl[1] = sid end
      ImGui.TableNextColumn(ctx)
      ImGui.SetNextItemWidth(ctx, -70)
      local chw, words = ImGui.InputText(ctx, "##words", rl[2] or "")
      if chw then rl[2] = words end
      ImGui.SameLine(ctx)
      if ImGui.SmallButton(ctx, "Remove") then remove = i end
      ImGui.PopID(ctx)
    end
    ImGui.EndTable(ctx)
  end
  if remove then table.remove(ed.rules, remove) end
  if ImGui.Button(ctx, "Add a rule line") then
    local first
    for _, s in ipairs(ed.stems) do if not s.metronome then first = s.id; break end end
    ed.rules[#ed.rules + 1] = { first or "", "" }
  end
  help("New lines go at the bottom (lowest priority). Use the arrows to move a line up.")

  ImGui.Spacing(ctx)
  ImGui.SeparatorText(ctx, "Never send automatically")
  ImGui.TextWrapped(ctx, "Tracks with any of these whole words get no automatic cue send (effect returns, buses, prints...). You can still add a send by hand in the panel.")
  ImGui.SetNextItemWidth(ctx, -1)
  local che, ex = ImGui.InputText(ctx, "##exclude", ed.exclude or "")
  if che then ed.exclude = ex end
  local chk, v = ImGui.Checkbox(ctx, "Folder tracks never get cue sends", ed.options.skip_folder_tracks == true)
  if chk then ed.options.skip_folder_tracks = v end

  ImGui.Spacing(ctx)
  ImGui.SeparatorText(ctx, "Try a track name")
  ImGui.SetNextItemWidth(ctx, 240)
  local _, tb = ImGui.InputText(ctx, "##tester", S.tester)
  S.tester = tb
  local cues = {}
  for _, s in ipairs(ed.stems) do if not s.metronome then cues[s.id] = true end end
  local s, why = C.assign_stem(S.tester, ed, cues)
  ImGui.SameLine(ctx)
  if s then ImGui.TextColored(ctx, GREEN, "-> " .. s.name .. "  (" .. why .. ")") else ImGui.TextDisabled(ctx, "-> no cue  (" .. tostring(why) .. ")") end
  help("Assumes every stem is in the session. Uses the rules as they are on screen, saved or not.")
end

---------------------------------------------------------------- tab: cue reverb
local function tab_reverb()
  local rv = S.ed.cue_reverb
  ImGui.TextWrapped(ctx, "A reverb inside the cue tracks only, so musicians can have some in their headphones without it ever reaching your mix. Turn it on or off for any cue in the panel (click the cue's name).")
  ImGui.Spacing(ctx)
  local ch, v = ImGui.Checkbox(ctx, "Add a reverb to new cue tracks", rv.enabled == true)
  if ch then rv.enabled = v end
  ImGui.BeginDisabled(ctx, not rv.enabled)
  ImGui.SetNextItemWidth(ctx, 300)
  local chp, p = ImGui.InputText(ctx, "Plugin", rv.plugin or "")
  if chp then rv.plugin = p end
  help("The plugin's name as REAPER's FX browser shows it, e.g. ReaVerbate (comes with REAPER). Choose a plugin with low or no latency, or the musicians will hear the reverb late.")
  ImGui.Text(ctx, "Which cues get it:")
  local on = id_set(rv.on_cues)
  for _, s in ipairs(S.ed.stems) do
    if not s.metronome then
      ImGui.SameLine(ctx)
      local chc, cv = ImGui.Checkbox(ctx, s.name .. "##rv" .. s.id, on[s.id] == true)
      if chc then on[s.id] = cv or nil; rv.on_cues = set_to_str(on) end
    end
  end
  ImGui.SetNextItemWidth(ctx, 160)
  local cha, ap = ImGui.InputText(ctx, "Parameter the panel's Reverb control moves", rv.amount_param or "")
  if cha then rv.amount_param = ap end
  help("Part of the parameter's name, e.g. \"wet\". The panel's Reverb box moves this parameter.")

  ImGui.Spacing(ctx)
  ImGui.SeparatorText(ctx, "Starting settings")
  ImGui.TextWrapped(ctx, "Applied when the reverb is first added to a cue. Parameter = part of its name as the plugin shows it; value = the number the plugin displays (dB, %, Hz ...).")
  local remove
  if ImGui.BeginTable(ctx, "rvset", 3, ImGui.TableFlags_SizingFixedFit | ImGui.TableFlags_RowBg) then
    ImGui.TableSetupColumn(ctx, "Parameter", ImGui.TableColumnFlags_WidthFixed, 170)
    ImGui.TableSetupColumn(ctx, "Value", ImGui.TableColumnFlags_WidthFixed, 140)
    ImGui.TableSetupColumn(ctx, "", ImGui.TableColumnFlags_WidthFixed, 70)
    ImGui.TableHeadersRow(ctx)
    for i, e in ipairs(rv.settings) do
      ImGui.PushID(ctx, "rvs" .. i)
      ImGui.TableNextRow(ctx)
      ImGui.TableNextColumn(ctx)
      ImGui.SetNextItemWidth(ctx, 160)
      local chn, nm = ImGui.InputText(ctx, "##p", tostring(e[1] or ""))
      if chn then e[1] = nm end
      ImGui.TableNextColumn(ctx)
      ImGui.SetNextItemWidth(ctx, 130)
      if type(e[2]) == "number" then
        local chv, nv = ImGui.InputDouble(ctx, "##v", e[2], 0, 0, "%.2f")
        if chv then e[2] = nv end
      else
        local chv, nv = ImGui.InputText(ctx, "##v", tostring(e[2] or ""))
        if chv then e[2] = tonumber(nv) or nv end
      end
      ImGui.TableNextColumn(ctx)
      if ImGui.SmallButton(ctx, "Remove") then remove = i end
      ImGui.PopID(ctx)
    end
    ImGui.EndTable(ctx)
  end
  if remove then table.remove(rv.settings, remove) end
  if ImGui.Button(ctx, "Add a setting") then rv.settings[#rv.settings + 1] = { "", 0 } end
  ImGui.EndDisabled(ctx)
end

---------------------------------------------------------------- tab: options
local SEND_MODES = { { "prefader", "Pre-fader, after plugins (recommended)" }, { "prefx", "Before the track's plugins" },
  { "postfader", "Post-fader (follows your mix faders)" } }

local function tab_options()
  local ed, o = S.ed, S.ed.options
  ImGui.SeparatorText(ctx, "Cue sends")
  local cur = "?"
  for _, m in ipairs(SEND_MODES) do if m[1] == o.send_mode then cur = m[2] end end
  ImGui.SetNextItemWidth(ctx, 300)
  if ImGui.BeginCombo(ctx, "Where sends into the cues come from", cur) then
    for _, m in ipairs(SEND_MODES) do
      if ImGui.Selectable(ctx, m[2], m[1] == o.send_mode) then o.send_mode = m[1] end
    end
    ImGui.EndCombo(ctx)
  end
  help("Used for every send Foldback makes. Pre-fader: your fader, mute and solo never change what the musicians hear (Foldback's tested setting). Before plugins: also keeps plugin latency and processing out of the cues. Post-fader: cues follow your mix.")
  local che, ve = ImGui.Checkbox(ctx, "\"Set up this session\" also changes existing cue sends to this", o.enforce_send_mode == true)
  if che then o.enforce_send_mode = ve end
  help("Off: sends you've set yourself (for example, one cue send left post-fader on purpose) are never changed. On: every send into a cue is reset to the mode above each time you run \"Set up this session\".")
  if C.is_mix(ed) then
    local off = (tonumber(o.mix_send_db) or -150) <= -150
    local cho, vo = ImGui.Checkbox(ctx, "New mix sends start off (silent)", off)
    if cho then o.mix_send_db = vo and -150 or 0.0 end
    help("Recommended. A new send makes no sound until you raise it, so nothing unexpected reaches a performer's headphones when you add or name a track during tracking.")
    if not off then
      ImGui.SetNextItemWidth(ctx, 120)
      local chd, db = ImGui.InputDouble(ctx, "Level new mix sends start at (dB)", tonumber(o.mix_send_db) or 0, 0.5, 3, "%.1f")
      if chd then o.mix_send_db = math.max(-60, math.min(12, db)) end
    end
    local pick = o.mix_new_tracks == "pick"
    ImGui.SetNextItemWidth(ctx, 330)
    if ImGui.BeginCombo(ctx, "New tracks get", pick and "No sends until I add them" or "A send to every mix") then
      if ImGui.Selectable(ctx, "A send to every mix", not pick) then o.mix_new_tracks = "all" end
      if ImGui.Selectable(ctx, "No sends until I add them", pick) then o.mix_new_tracks = "pick" end
      ImGui.EndCombo(ctx)
    end
    local chk_, vc = ImGui.Checkbox(ctx, "Add a click track that feeds every mix", o.click_track == true)
    if chk_ then o.click_track = vc end
    help("\"Set up this session\" adds a track named Click that makes a click on every beat of the project's tempo and time signature (it follows tempo changes). It gets its own send to every mix, off at first, so each performer has their own click level and pan. It does NOT use REAPER's metronome settings (sound, volume, count-in, on/off); it only follows the tempo and time signature.")
    help("A send to every mix: each new track appears in every performer's mix, ready to raise (it starts at the level above). No sends until I add them: nothing is created; add sends yourself with + in the panel or in Set up this session. A send you delete on purpose is never put back.")
  else
    ImGui.SetNextItemWidth(ctx, 120)
    local chd, db = ImGui.InputDouble(ctx, "Level of new cue sends (dB)", o.auto_send_db or 0, 0.5, 3, "%.1f")
    if chd then o.auto_send_db = math.max(-60, math.min(12, db)) end
  end

  ImGui.Spacing(ctx)
  ImGui.SeparatorText(ctx, "Talkback")
  local cht, vt = ImGui.Checkbox(ctx, "Add a talkback button", o.talkback == true)
  if cht then o.talkback = vt end
  help("Adds a TALKBACK track with a send to every cue, and a \"Hold to talk\" button in the panel (left of the Listen row). The sends are only open while you hold the button down. Choose the microphone input below, then run \"Set up this session\" (or just press the button once).")
  if o.talkback == true then
    local ni = C.input_index(o.talkback_input)
    local nin = r.GetNumAudioInputs()
    local prev = o.talkback_input == nil and "(none chosen)" or (ni and string.format("%d: %s", ni + 1, r.GetInputChannelName(ni) or "") or ("NOT FOUND: " .. tostring(o.talkback_input)))
    ImGui.SetNextItemWidth(ctx, 330)
    if ImGui.BeginCombo(ctx, "Microphone input##tb", prev, ImGui.ComboFlags_HeightLarge) then
      if ImGui.Selectable(ctx, "(none chosen)", o.talkback_input == nil) then o.talkback_input = nil end
      for i = 0, nin - 1 do
        local nm = r.GetInputChannelName(i) or ("Input " .. (i + 1))
        local dup = 0
        for j = 0, nin - 1 do if r.GetInputChannelName(j) == nm then dup = dup + 1 end end
        if ImGui.Selectable(ctx, string.format("%d: %s##tbin%d", i + 1, nm, i), ni == i) then o.talkback_input = (dup == 1) and nm or (i + 1) end
      end
      ImGui.EndCombo(ctx)
    end
    help("A mono input. Foldback arms the TALKBACK track for monitoring only; it never records.")
  end

  ImGui.Spacing(ctx)
  ImGui.SeparatorText(ctx, "Safety limiter")
  local chl, vl = ImGui.Checkbox(ctx, "Limit the loudest peaks in every cue", o.limiter == true)
  if chl then o.limiter = vl end
  help("Puts a limiter last on each cue track, so a sudden loud peak (feedback, a plugged-in cable, a bad fader move) can't go above the ceiling you set. It protects hearing; it is not a compressor and does nothing to normal levels. While it is on, each cue's level fader can't go above 0 dB, because that fader sits after the limiter. Applies when you Save.")
  if o.limiter == true then
    ImGui.SetNextItemWidth(ctx, 120)
    local chc, cdb = ImGui.InputDouble(ctx, "Ceiling (dB)", tonumber(o.limiter_ceiling_db) or -3, 0.5, 3, "%.1f")
    if chc then o.limiter_ceiling_db = math.max(-24, math.min(0, cdb)) end
    help("The loudest the cue is allowed to get, in dB below digital full scale. -3 is a gentle default; lower is quieter and safer. This is the level in the cue before your interface's headphone volume.")
  end

  ImGui.Spacing(ctx)
  ImGui.SeparatorText(ctx, "Projects")
  local cha, va = ImGui.Checkbox(ctx, "Set up new projects automatically", o.auto_setup_new_projects == true)
  if cha then o.auto_setup_new_projects = va end
  help("When the panel is open and you start an empty project, it gets the cues ticked under \"New projects\" on the Cues tab.")
  local chl, vl = ImGui.Checkbox(ctx, "Turn Listen off when a project opens", o.listen_off_on_open ~= false)
  if chl then o.listen_off_on_open = vl end
  help("Listen mutes your master output and plays one cue on your speakers. If a project is saved while Listen is on, it would open with your speakers silent. With this on, Foldback switches Listen off when the project opens and puts the master mute back the way it was.")

  ImGui.Spacing(ctx)
  ImGui.SeparatorText(ctx, "Cue tracks")
  local cht, vt = ImGui.Checkbox(ctx, "Hide cue tracks in the arrange view", o.hide_cue_tracks_in_arrange == true)
  if cht then o.hide_cue_tracks_in_arrange = vt end
  help("Keeps the cue tracks (and the Listen track) out of your track list so they don't clutter the session. They still work, and Foldback's panel is where you mix them. Takes effect the next time you run \"Set up this session\".")
  local chm, vm = ImGui.Checkbox(ctx, "Hide cue tracks in REAPER's mixer", o.hide_cue_tracks_in_mixer ~= false)
  if chm then o.hide_cue_tracks_in_mixer = vm end
  help("Hiding changes only what you see; the cues still play. Takes effect the next time you run \"Set up this session\".")
  ImGui.SetNextItemWidth(ctx, 120)
  local chp, vp = ImGui.InputText(ctx, "Cue track name prefix", o.cue_prefix or "")
  if chp then o.cue_prefix = vp end
  help("Cue tracks are named prefix + cue, e.g. \"CUE Drums\". Existing cue tracks are renamed the next time you run \"Set up this session\".")
  ImGui.SetNextItemWidth(ctx, 160)
  local chn, vn = ImGui.InputText(ctx, "Listen track name", o.listen_name or "")
  if chn then o.listen_name = vn end
  local chc, cc = ImGui.ColorEdit3(ctx, "Listen track color", rgb_int(o.listen_color or { 220, 40, 40 }), ImGui.ColorEditFlags_NoInputs)
  if chc then o.listen_color = int_rgb(cc) end

  ImGui.Spacing(ctx)
  ImGui.SeparatorText(ctx, "Panel")
  ImGui.Text(ctx, "Panel colors (applied to the open panel as soon as you Save):")
  help("These change the colors of the Foldback panel only: background, buttons, level boxes, meters and the lit Listen button. They don't change your REAPER theme or your track colors (cue colors are set on the Cues tab). Each swatch changes one part; Reset puts that one back.")
  if ImGui.BeginTable(ctx, "look", 4, ImGui.TableFlags_SizingFixedFit) then
    for k, e in ipairs(C.LOOK_DEFAULTS) do
      if (k - 1) % 2 == 0 then ImGui.TableNextRow(ctx) end
      local key = e[1]
      ImGui.TableNextColumn(ctx)
      local val = ed.panel_colors[key] or e[2]
      local ch1, nv = ImGui.ColorEdit3(ctx, (C.LOOK_LABELS[key] or key) .. "##lk" .. key, rgb_int(val), ImGui.ColorEditFlags_NoInputs)
      if ch1 then ed.panel_colors[key] = int_rgb(nv) end
      ImGui.TableNextColumn(ctx)
      if ed.panel_colors[key] then
        if ImGui.SmallButton(ctx, "Reset##rs" .. key) then ed.panel_colors[key] = nil end
      else
        ImGui.Dummy(ctx, 40, 1)
      end
    end
    ImGui.EndTable(ctx)
  end
  if ImGui.Button(ctx, "Reset all panel colors") then ed.panel_colors = {} end
end

---------------------------------------------------------------- profiles
local function switch_to(name)
  C.set_active_profile(name)
  if load_active() then signal(); note("Now using profile \"" .. name .. "\".") end
end

-- run fn now, or first ask about unsaved changes
local function guarded(fn)
  if dirty() then S.then_do = fn; S.modal = "unsaved" else fn() end
end

local function do_name_action()
  local nm = C.valid_profile_name(S.name_buf)
  if not nm then note("Use letters, numbers, spaces, - and _ only.", true) return false end
  local to = C.profile_file(nm)
  if r.file_exists(to) then note("There's already a profile called \"" .. nm .. "\".", true) return false end
  if S.name_mode == "new" then
    if not C.copy_file(C.script_dir .. "profiles/Starter.lua", to) and not C.copy_file(C.profile_file("Starter"), to) then
      note("Couldn't find the Starter profile to copy.", true) return false
    end
    switch_to(nm)
    S.ed.profile_name = nm
    local ok, err = C.save_profile(S.ed, to)
    if ok then S.saved = text_now() else note(err, true) end
  elseif S.name_mode == "duplicate" then
    local copy = deepcopy(S.ed)
    copy.profile_name = nm
    local ok, err = C.save_profile(copy, to)
    if not ok then note(err, true) return false end
    switch_to(nm)
  elseif S.name_mode == "rename" then
    local from = S.ed.path
    local ok = os.rename(from, to)
    if not ok then note("Couldn't rename the profile file.", true) return false end
    C.set_active_profile(nm)
    load_active()
    S.ed.profile_name = nm
    local ok2, err = C.save_profile(S.ed, to)
    if ok2 then S.saved = text_now() else note(err, true) end
    signal()
    note("Renamed to \"" .. nm .. "\".")
  end
  return true
end

local function profile_bar()
  local names = C.list_profiles()
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, "Profile:")
  ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, 240)
  local shown = S.legacy and "(older single config file)" or S.ed.profile
  if ImGui.BeginCombo(ctx, "##prof", shown) then
    for _, nm in ipairs(names) do
      if ImGui.Selectable(ctx, nm, nm == S.ed.profile) and nm ~= S.ed.profile then
        guarded(function() switch_to(nm) end)
      end
    end
    ImGui.EndCombo(ctx)
  end
  help("A profile holds all of a studio's (or setup's) Foldback settings. The one chosen here is the one Foldback uses.")
  ImGui.SameLine(ctx, 0, 16)
  if ImGui.Button(ctx, "New") then guarded(function() S.name_mode = "new"; S.name_buf = ""; S.modal = "name" end) end
  if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, "Start a new profile from the neutral Starter settings") end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Duplicate") then S.name_mode = "duplicate"; S.name_buf = S.ed.profile .. " copy"; S.modal = "name" end
  if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, "Copy this profile (including unsaved changes) under a new name") end
  ImGui.SameLine(ctx)
  ImGui.BeginDisabled(ctx, S.legacy)
  if ImGui.Button(ctx, "Rename") then guarded(function() S.name_mode = "rename"; S.name_buf = S.ed.profile; S.modal = "name" end) end
  ImGui.SameLine(ctx)
  ImGui.BeginDisabled(ctx, #names < 2)
  if ImGui.Button(ctx, "Delete") then S.modal = "delete" end
  ImGui.EndDisabled(ctx)
  ImGui.EndDisabled(ctx)
  if S.legacy then
    ImGui.TextColored(ctx, ORANGE, "You're using the older single config file. Saving turns it into a profile.")
  end
end

local function modals()
  if S.modal and not S.modal_open then
    ImGui.OpenPopup(ctx, S.modal)
    S.modal_open = true
  end
  local flags = ImGui.WindowFlags_AlwaysAutoResize
  if ImGui.BeginPopupModal(ctx, "name", nil, flags) then
    local lab = ({ new = "Name for the new profile:", duplicate = "Name for the copy:", rename = "New name:" })[S.name_mode] or "Name:"
    ImGui.Text(ctx, lab)
    if ImGui.IsWindowAppearing(ctx) then ImGui.SetKeyboardFocusHere(ctx) end
    ImGui.SetNextItemWidth(ctx, 260)
    local _, b = ImGui.InputText(ctx, "##nm", S.name_buf)
    S.name_buf = b
    if S.msg_bad and S.msg and r.time_precise() - S.msg_t < 8 then ImGui.TextColored(ctx, RED, S.msg) end
    if ImGui.Button(ctx, "OK") then
      if do_name_action() then S.modal, S.modal_open = nil, false; ImGui.CloseCurrentPopup(ctx) end
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Cancel") then S.modal, S.modal_open = nil, false; ImGui.CloseCurrentPopup(ctx) end
    ImGui.EndPopup(ctx)
  end
  if ImGui.BeginPopupModal(ctx, "delete", nil, flags) then
    ImGui.Text(ctx, "Delete the profile \"" .. tostring(S.ed.profile) .. "\"?")
    ImGui.TextDisabled(ctx, "A backup copy is kept in Foldback/backups/profiles.")
    if ImGui.Button(ctx, "Delete") then
      local path, gone = S.ed.path, S.ed.profile
      C.save_profile(S.ed, path)            -- writes a dated backup of it first
      os.remove(path)
      local rest = C.list_profiles()
      local nextp = rest[1]
      for _, n in ipairs(rest) do if n == "Starter" then nextp = n end end
      if nextp then switch_to(nextp) end
      note("Deleted \"" .. gone .. "\".")
      S.modal, S.modal_open = nil, false
      ImGui.CloseCurrentPopup(ctx)
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Cancel") then S.modal, S.modal_open = nil, false; ImGui.CloseCurrentPopup(ctx) end
    ImGui.EndPopup(ctx)
  end
  if ImGui.BeginPopupModal(ctx, "unsaved", nil, flags) then
    ImGui.Text(ctx, "Save your changes to \"" .. tostring(S.ed.profile) .. "\" first?")
    local go
    if ImGui.Button(ctx, "Save") then go = "save" end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Don't save") then go = "discard" end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Cancel") then go = "cancel" end
    if go then
      S.modal, S.modal_open = nil, false
      ImGui.CloseCurrentPopup(ctx)
      local fn = S.then_do
      S.then_do = nil
      if go == "save" then
        if S.save() and fn then fn() end
      elseif go == "discard" then
        load_active()
        if fn then fn() end
      end
    end
    ImGui.EndPopup(ctx)
  end
end

function S.save()
  local bad = problems()
  if #bad > 0 then
    r.ShowMessageBox("Can't save yet:\n\n" .. table.concat(bad, "\n"), TITLE, 0)
    return false
  end
  local path = S.ed.path
  if S.legacy then
    local base = C.valid_profile_name(S.ed.profile_name) or "My studio"
    local nm, i = base, 2
    while r.file_exists(C.profile_file(nm)) do nm = base .. " " .. i; i = i + 1 end
    path = C.profile_file(nm)
    S.ed.profile_name = S.ed.profile_name or nm
    local ok, err = C.save_profile(S.ed, path)
    if not ok then r.ShowMessageBox(err, TITLE, 0) return false end
    C.set_active_profile(nm)
  else
    local ok, err = C.save_profile(S.ed, path)
    if not ok then r.ShowMessageBox(err, TITLE, 0) return false end
  end
  load_active()
  signal()
  note("Saved at " .. os.date("%H:%M:%S") .. ". To use new outputs or cues in this project, press \"Set up this session\".")
  return true
end

---------------------------------------------------------------- window
ctx = ImGui.CreateContext(TITLE)

local function frame()
  ImGui.SetNextWindowSize(ctx, 980, 640, ImGui.Cond_FirstUseEver)
  local visible, open = ImGui.Begin(ctx, TITLE, true, ImGui.WindowFlags_NoCollapse)
  if visible then
    profile_bar()
    ImGui.Separator(ctx)
    local footer = ImGui.GetFrameHeightWithSpacing(ctx) * 2 + 8
    -- The tab row stays put; only the chosen tab's contents scroll (in their own area).
    local NOSCROLL = ImGui.WindowFlags_NoScrollbar | ImGui.WindowFlags_NoScrollWithMouse
    if ImGui.BeginChild(ctx, "body", 0, -footer, ImGui.ChildFlags_None, NOSCROLL) then
      if ImGui.BeginTabBar(ctx, "tabs") then
        local pages = { { "Cues", tab_cues } }
        if C.feature(S.ed, "name_rules") and not C.is_mix(S.ed) then pages[#pages + 1] = { "Track names", tab_names } end
        if C.feature(S.ed, "cue_reverb") then pages[#pages + 1] = { "Cue reverb", tab_reverb } end
        pages[#pages + 1] = { "Options", tab_options }
        for _, t in ipairs(pages) do
          if ImGui.BeginTabItem(ctx, t[1]) then
            if ImGui.BeginChild(ctx, "page_" .. t[1], 0, 0) then
              t[2]()
              ImGui.EndChild(ctx)
            end
            ImGui.EndTabItem(ctx)
          end
        end
        ImGui.EndTabBar(ctx)
      end
      ImGui.EndChild(ctx)
    end
    ImGui.Separator(ctx)
    local d = dirty()
    ImGui.BeginDisabled(ctx, not d)
    if ImGui.Button(ctx, "Save") then S.save() end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Revert") then load_active(); note("Changes thrown away.") end
    ImGui.EndDisabled(ctx)
    ImGui.SameLine(ctx)
    ImGui.BeginDisabled(ctx, d)
    if ImGui.Button(ctx, "Set up this session...") then
      local ok, err = pcall(dofile, script_dir .. "Foldback_Setup.lua")
      if not ok then r.ShowMessageBox("Couldn't start Set up this session:\n\n" .. tostring(err), TITLE, 0) end
    end
    ImGui.EndDisabled(ctx)
    if ImGui.IsItemHovered(ctx, ImGui.HoveredFlags_AllowWhenDisabled) then
      ImGui.SetTooltip(ctx, d and "Save first." or "Choose this project's cues and which tracks feed them, using the saved settings.")
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Close") then guarded(function() S.quit = true end) end
    ImGui.SameLine(ctx, 0, 20)
    if d then ImGui.TextColored(ctx, ORANGE, "Unsaved changes") end
    if S.msg and r.time_precise() - S.msg_t < 10 then
      ImGui.SameLine(ctx, 0, 20)
      ImGui.TextColored(ctx, S.msg_bad and RED or GREEN, S.msg)
    end
    ImGui.TextDisabled(ctx, "File: " .. tostring(S.ed.path))
    modals()
    ImGui.End(ctx)
  end
  if not open then guarded(function() S.quit = true end) end
  return not S.quit
end

local function loop()
  local ok, res = xpcall(frame, debug.traceback)
  if not ok then
    FOLDBACK_SETTINGS_OPEN = nil
    r.RecursiveCreateDirectory(C.logdir, 0)
    local f = io.open(C.logdir .. "/settings_error.txt", "w")
    if f then f:write(os.date("%Y-%m-%d %H:%M:%S") .. "\n" .. tostring(res) .. "\n"); f:close() end
    r.ShowMessageBox("Foldback settings hit an error and closed. Nothing unsaved was written.\nDetails: " .. C.logdir .. "/settings_error.txt", TITLE, 0)
    return
  end
  if res then r.defer(loop) else FOLDBACK_SETTINGS_OPEN = nil end
end

refresh_outputs()
if load_active() then
  FOLDBACK_SETTINGS_OPEN = true
  r.defer(loop)
end
