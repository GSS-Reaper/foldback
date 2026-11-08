-- Foldback - Copyright (C) 2026 Franktree. Free software under the GNU General Public License v3.0 (see LICENSE).
-- @description Foldback: set up this session (choose the cues, then which tracks feed them)
-- Creates / repairs / removes CUE tracks for the cues you tick, the CUE LISTEN track, and the
-- sends from your tracks into the cues (as ticked in the grid). Writes Foldback/logs/setup.txt
local r = reaper
local script_dir = ({ r.get_action_context() })[2]:match("^(.*[/\\])")
local C = dofile(script_dir .. "Foldback_Core.lua")
local TITLE = "Foldback: set up this session"

local log = C.new_log("setup.txt")
local cfg, cerr = C.load_config()
if not cfg then
  r.ShowMessageBox(cerr, TITLE, 0)
  return
end
local opt = cfg.options
local MODE = C.send_mode(cfg)
local MIX = C.is_mix(cfg)                              -- mix mode: cues are performers' mixes
local NAMES = C.feature(cfg, "name_rules") and not MIX   -- (track-name rules aren't used in mix mode)
local VERB = C.feature(cfg, "cue_reverb")
log.w("Profile:", cfg.profile, "(" .. cfg.path .. ")")
local migrated = C.migrate()
if migrated > 0 then log.w("Migrated", migrated, "track tags from the older GSS Cue version") end

---------------------------------------------------------------- check the profile
local ids = {}
for _, s in ipairs(cfg.stems) do
  if ids[s.id] then log.err("Duplicate cue id in profile:", s.id) end
  ids[s.id] = true
  if s.width ~= "stereo" and s.width ~= "mono" then log.err("Cue", s.name, "width must be \"stereo\" or \"mono\"") end
end
log.w("")
log.w("Cue outputs:")
for _, s in ipairs(cfg.stems) do
  local o, why = C.stem_output(cfg, s)
  log.w(string.format("  %-10s %-6s %s", s.name, s.width, o and (C.output_label(s, true) .. " (REAPER output " .. (o + 1) ..
    (s.width == "stereo" and ("/" .. (o + 2)) or "") .. ")") or ("(" .. tostring(why) .. ")")))
end
local mon, mon_how = C.listen_index(cfg)
log.w("Listen output:", tostring(cfg.monitor_output or "(follows the master track)"), mon and ("(REAPER outputs " .. (mon + 1) .. "/" .. (mon + 2) .. (mon_how == "master" and ", same as the master" or "") .. ")") or "(NOT FOUND)")
if not mon then
  if cfg.monitor_output == nil then log.warn("No Listen output chosen and the master has no hardware output, so Listen isn't set up")
  else log.err("Listen output not found:", cfg.monitor_output) end
end

local function cue_list() local t = {} for _, s in ipairs(cfg.stems) do if not s.metronome then t[#t + 1] = s end end return t end

-- the project's own tracks (not Foldback's), with folder depth for indenting
local function project_tracks()
  local t = {}
  for i = 0, r.CountTracks(0) - 1 do
    local tr = r.GetTrack(0, i)
    if not C.is_system(tr) then
      t[#t + 1] = { tr = tr, guid = C.guid(tr), num = i + 1, name = C.name(tr),
        depth = r.GetTrackDepth(tr), folder = r.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH") == 1 }
    end
  end
  return t
end

-- two cues on the same output (incl. the click), or a missing output. returns problem text or nil
local function conflicts(want)
  local used = {}
  for _, s in ipairs(cfg.stems) do
    if s.metronome or want[s.id] then
      for o in pairs(C.stem_out_set(s)) do
        if used[o] then return "REAPER output " .. (o + 1) .. " is used by both " .. used[o] .. " and " .. s.name end
        used[o] = s.name
      end
      if want[s.id] then
        local _, why, unassigned = C.stem_output(cfg, s)
        if why and not unassigned then return why end
      end
    end
  end
  return nil
end

---------------------------------------------------------------- do it
-- want = set of cue ids; grid = [track guid][cue id] = true/false, or nil (leave sends alone,
-- except that profiles with track-name rules then use them)
local function apply(want, grid)
  local cues, listen = C.scan()
  local wanted = {}
  for _, s in ipairs(cue_list()) do if want[s.id] then wanted[#wanted + 1] = s end end
  local problem = conflicts(want)
  if problem then r.ShowMessageBox("Can't set up: " .. problem, TITLE, 0) return end

  local to_remove = {}
  for id, tr in pairs(cues) do
    if not want[id] then to_remove[#to_remove + 1] = { id = id, tr = tr } end
  end
  if #to_remove > 0 and not rawget(_G, "FOLDBACK_SILENT") then
    local names = {}
    for _, x in ipairs(to_remove) do names[#names + 1] = C.name(x.tr) end
    if r.ShowMessageBox("Remove these cue tracks (and every send into them)?\n\n" .. table.concat(names, "\n"), TITLE, 4) ~= 6 then
      r.ShowMessageBox("Nothing changed.", TITLE, 0)
      return
    end
  end

  r.Undo_BeginBlock()
  r.PreventUIRefresh(1)
  local names = {}
  for _, s in ipairs(wanted) do names[#names + 1] = s.name end
  log.w("")
  log.w("Cues for this session:", table.concat(names, ", "))
  for _, x in ipairs(to_remove) do
    log.w("Removed cue track:", C.name(x.tr))
    r.DeleteTrack(x.tr)
    if NAMES or MIX then C.forget_stem_everywhere(x.id) end
  end

  cues, listen = C.scan()
  log.w("")
  log.w("Cue tracks:")
  for _, s in ipairs(wanted) do
    local tr, made = cues[s.id], false
    if not tr then
      tr = C.new_track_at_end()
      C.set_ext(tr, C.KEY_STEM, s.id)
      cues[s.id] = tr
      made = true
    end
    local out, why = C.stem_output(cfg, s)
    local fx_ok = C.configure_cue(tr, s, out, { hide_tcp = opt.hide_cue_tracks_in_arrange, hide_mixer = opt.hide_cue_tracks_in_mixer ~= false, limiter = opt.limiter == true, ceiling = opt.limiter_ceiling_db })
    if out then
      log.w(string.format("  %s %-14s %-6s -> %s%s", made and "created " or "repaired", C.name(tr), s.width, C.output_label(s, true),
        (s.width == "mono" and fx_ok) and "  [mono sum FX ok]" or ""))
    else
      log.warn(string.format("%s %s: %s - it plays nowhere until you choose an output in Foldback settings", made and "created" or "repaired", C.name(tr), tostring(why)))
    end
    if not fx_ok then log.err("Mono sum JSFX could not be loaded on", C.name(tr)) end
  end

  if mon then
    local made = false
    if not listen then
      listen = C.new_track_at_end()
      C.set_ext(listen, C.KEY_LISTEN, "1")
      made = true
    end
    C.configure_listen(listen, mon, opt.hide_cue_tracks_in_arrange, opt.hide_cue_tracks_in_mixer ~= false)
    log.w(string.format("  %s %s -> REAPER outputs %d/%d (%s)", made and "created " or "repaired", C.opt("listen_name"), mon + 1, mon + 2, tostring(cfg.monitor_output or "master")))
    for _, s in ipairs(wanted) do
      local _, created = C.ensure_send(cues[s.id], listen, 0.0, C.SENDMODE_POSTFADER, true)
      if created then log.w("    listen send from", C.name(cues[s.id]), "(muted until you press Listen)") end
    end
  end

  -- cue reverb (profiles with that feature only), inside the cue tracks
  if VERB then
    local _, _, _, oldverb = C.scan()
    if oldverb then log.w("  removed old CUE VERB track"); r.DeleteTrack(oldverb) end
    local rv = cfg.cue_reverb
    if rv and rv.enabled then
      for id in (rv.on_cues or ""):gmatch("%S+") do
        if cues[id] and want[id] then
          local fx, added = C.add_cue_verb(cues[id], rv, log)
          if fx and not added then log.w("    " .. C.name(cues[id]) .. " already has its reverb (settings kept)") end
        end
      end
    end
  end

  if MIX and opt.click_track == true then
    local ck = C.ensure_click()
    if ck then log.w("  click track ready (follows the project tempo; gets a send to every mix like any other track)")
    else log.err("Click effect could not be loaded") end
  end
  if opt.talkback == true then
    local tb, has_in = C.ensure_talkback(cfg, cues)
    if tb then log.w("  TALKBACK track ready" .. (has_in and "" or " (no microphone input chosen yet - pick one in Foldback settings > Options)")) end
  end

  -- sends from your tracks into the cues
  local n_add, n_del = 0, 0
  log.w("")
  if grid then
    log.w("Track sends (from the grid):")
    for _, t in ipairs(project_tracks()) do
      local row = grid[t.guid]
      if row then
        for _, s in ipairs(wanted) do
          local cue = cues[s.id]
          local has = C.find_send(t.tr, cue)
          if row[s.id] and not has then
            C.ensure_send(t.tr, cue, C.new_send_db(cfg), MODE, false)
            n_add = n_add + 1
            log.w("  + " .. t.name .. " -> " .. C.name(cue))
          elseif row[s.id] == false and has then
            r.RemoveTrackSend(t.tr, 0, has)
            n_del = n_del + 1
            log.w("  - " .. t.name .. " -/-> " .. C.name(cue))
          end
        end
        if NAMES then   -- remember the choices, so automatic sends don't undo them
          local seen = C.seen_set(t.tr)
          for id in pairs(cues) do seen[id] = true end
          C.set_seen(t.tr, seen)
          local raw = C.raw_name(t.tr)
          if raw ~= "" then C.set_ext(t.tr, C.KEY_NAME, raw) end
          local pick = (raw ~= "") and C.assign_stem(raw, cfg, cues) or nil
          C.set_ext(t.tr, C.KEY_AUTO, (pick and C.find_send(t.tr, cues[pick.id])) and pick.id or "")
        elseif MIX then   -- remember the choices, so automatic sends don't undo them
          local seen = C.seen_set(t.tr)
          for id in pairs(cues) do seen[id] = true end
          C.set_seen(t.tr, seen)
        end
      end
    end
  elseif MIX then
    log.w("Automatic sends (mix mode, starting " .. C.fmt_start_db(C.new_send_db(cfg)) .. "):")
    for _, t in ipairs(project_tracks()) do
      local msg = C.mix_assign(t.tr, cfg, cues)
      if msg then
        n_add = n_add + 1
        log.w(string.format("  %-28s %s", t.name, msg))
      end
    end
  elseif NAMES then
    log.w("Automatic sends by track name:")
    for _, t in ipairs(project_tracks()) do
      if C.raw_name(t.tr) ~= "" then
        local msg = C.auto_assign(t.tr, cfg, cues)
        if msg then
          if msg:sub(1, 2) == "->" then n_add = n_add + 1 end
          if msg:sub(1, 5) == "ERROR" then log.err(t.name, msg) end
          log.w(string.format("  %-28s %s", t.name, msg))
        end
      end
    end
  end

  -- optional: every send into a cue gets the profile's send mode
  local fixed = 0
  if opt.enforce_send_mode then
    local cue_guid = {}
    for id, tr in pairs(cues) do cue_guid[C.guid(tr)] = id end
    for _, t in ipairs(project_tracks()) do
      for k = 0, r.GetTrackNumSends(t.tr, 0) - 1 do
        local d = r.GetTrackSendInfo_Value(t.tr, 0, k, "P_DESTTRACK")
        if d and r.ValidatePtr2(0, d, "MediaTrack*") and cue_guid[C.guid(d)]
           and r.GetTrackSendInfo_Value(t.tr, 0, k, "I_SENDMODE") ~= MODE then
          r.SetTrackSendInfo_Value(t.tr, 0, k, "I_SENDMODE", MODE)
          fixed = fixed + 1
          log.w("  send mode -> " .. C.SEND_MODE_NAMES[MODE] .. ":", t.name, "->", C.name(d))
        end
      end
    end
  end

  for _, s in ipairs(cfg.stems) do
    if s.metronome then
      local o = C.output_index(s.output)
      log.w("")
      log.w(string.format("%s: set REAPER's metronome output to %s (REAPER output %s).", s.name, tostring(s.output), o and (o + 1) or "?"))
    end
  end

  r.PreventUIRefresh(-1)
  r.TrackList_AdjustWindows(false)
  r.UpdateArrange()
  r.Undo_EndBlock("Foldback: set up this session", -1)
  log.w("")
  log.w(string.format("Summary: %d cues, %d sends added, %d sends removed, %d send modes changed, %d errors, %d warnings",
    #wanted, n_add, n_del, fixed, log.errors, log.warnings))
  log.save()
  if not rawget(_G, "FOLDBACK_SILENT") then
    r.ShowMessageBox(string.format("Done.\n\n%d cues\n%d sends added\n%d sends removed\n%d errors, %d warnings\n\nDetails: %s",
      #wanted, n_add, n_del, log.errors, log.warnings, log.path), TITLE, 0)
  end
end

---------------------------------------------------------------- silent (new empty project) / no ReaImGui
local SILENT = rawget(_G, "FOLDBACK_SILENT")
local function want_from_words(str)
  local t = {}
  for w in (str or ""):gmatch("%S+") do
    local s = C.stem_by_name(cfg, w)
    if s and not s.metronome then t[s.id] = true end
  end
  return t
end
if SILENT then apply(want_from_words(SILENT), nil) return end

if not r.APIExists("ImGui_GetBuiltinPath") then
  local avail, cur = {}, {}
  local cues0 = C.scan()
  for _, s in ipairs(cue_list()) do avail[#avail + 1] = s.id; if cues0[s.id] then cur[#cur + 1] = s.id end end
  local ok, input = r.GetUserInputs("Foldback cues: " .. table.concat(avail, " "), 1, "Cues for this session (spaces):,extrawidth=300",
    (#cur > 0) and table.concat(cur, " ") or (opt.default_stems or ""))
  if ok then apply(want_from_words(input), nil) end
  return
end

---------------------------------------------------------------- the window
if rawget(_G, "FOLDBACK_SETUP_OPEN") then return end
package.path = r.ImGui_GetBuiltinPath() .. '/?.lua'
local ImGui = require 'imgui' '0.10'
local ctx = ImGui.CreateContext("Foldback session setup")

local cues_now = C.scan()
local want = {}
do
  local any = next(cues_now) ~= nil
  local def = want_from_words(opt.default_stems)
  for _, s in ipairs(cue_list()) do
    if any then want[s.id] = cues_now[s.id] ~= nil else want[s.id] = def[s.id] == true end
  end
end
local tracks = project_tracks()
local grid, suggested = {}, {}

-- a cue's column starts from the sends that exist (plus track-name suggestions, if used)
local function init_column(s)
  local cue = cues_now[s.id]
  local present = {}
  for id, w in pairs(want) do if w then present[id] = true end end
  for _, t in ipairs(tracks) do
    grid[t.guid] = grid[t.guid] or {}
    suggested[t.guid] = suggested[t.guid] or {}
    if grid[t.guid][s.id] == nil then
      local has = cue and C.find_send(t.tr, cue) ~= nil
      local sug = false
      if not has and not (opt.skip_folder_tracks and t.folder) and not C.seen_set(t.tr)[s.id] then
        if MIX then
          sug = (opt.mix_new_tracks ~= "pick")        -- mix mode: every track feeds every mix (silent until raised)
        elseif NAMES then
          local raw = C.raw_name(t.tr)
          local pick = (raw ~= "") and C.assign_stem(raw, cfg, present) or nil
          sug = pick ~= nil and pick.id == s.id
        end
      end
      grid[t.guid][s.id] = has or sug
      suggested[t.guid][s.id] = sug
    end
  end
end
for _, s in ipairs(cue_list()) do if want[s.id] then init_column(s) end end

local GREEN, RED, ORANGE = 0x7FD6A8FF, 0xFF6A6AFF, 0xFFB050FF
FOLDBACK_SETUP_OPEN = true

local function frame()
  local done
  ImGui.SetNextWindowSize(ctx, 860, 600, ImGui.Cond_FirstUseEver)
  local visible, open = ImGui.Begin(ctx, TITLE, true, ImGui.WindowFlags_NoCollapse)
  if visible then
    ImGui.SeparatorText(ctx, MIX and "1. Mixes for this session" or "1. Cues for this session")
    local n = 0
    for _, s in ipairs(cue_list()) do
      if n > 0 then ImGui.SameLine(ctx, 0, 18) end
      n = n + 1
      local ch, v = ImGui.Checkbox(ctx, s.name .. "##w" .. s.id, want[s.id] == true)
      if ch then want[s.id] = v; if v then init_column(s) end end
      if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, s.width .. ", " .. C.output_label(s)) end
    end
    local problem = conflicts(want)
    local gone = {}
    for _, s in ipairs(cue_list()) do if cues_now[s.id] and not want[s.id] then gone[#gone + 1] = s.name end end
    if problem then ImGui.TextColored(ctx, RED, problem)
    elseif #gone > 0 then ImGui.TextColored(ctx, ORANGE, "Will remove (with their sends): " .. table.concat(gone, ", ")) end

    ImGui.Spacing(ctx)
    ImGui.SeparatorText(ctx, "2. Which tracks feed which cues")
    local cols = {}
    for _, s in ipairs(cue_list()) do if want[s.id] then cols[#cols + 1] = s end end
    if #tracks == 0 then
      ImGui.TextDisabled(ctx, "This project has no tracks yet. Add sends later from the panel's Selected tracks box.")
    elseif #cols == 0 then
      ImGui.TextDisabled(ctx, "Tick at least one cue above.")
    else
      if NAMES then ImGui.TextDisabled(ctx, "Green ticks are suggestions from your track-name rules. Untick any you don't want.")
      elseif MIX and opt.mix_new_tracks ~= "pick" then
        ImGui.TextDisabled(ctx, "Green ticks are new sends to every mix; each starts at " .. C.fmt_start_db(C.new_send_db(cfg)) .. ". Untick any you don't want.")
      end
      local footer = ImGui.GetFrameHeightWithSpacing(ctx) + 10
      local flags = ImGui.TableFlags_ScrollY | ImGui.TableFlags_ScrollX | ImGui.TableFlags_RowBg | ImGui.TableFlags_BordersInnerH
        | ImGui.TableFlags_SizingFixedFit
      if ImGui.BeginTable(ctx, "grid", #cols + 1, flags, 0, -footer) then
        ImGui.TableSetupScrollFreeze(ctx, 1, 2)
        ImGui.TableSetupColumn(ctx, "Track", ImGui.TableColumnFlags_WidthFixed, 230)
        for _, s in ipairs(cols) do ImGui.TableSetupColumn(ctx, s.name, ImGui.TableColumnFlags_WidthFixed, 78) end
        ImGui.TableHeadersRow(ctx)
        ImGui.TableNextRow(ctx)          -- all / none per cue
        ImGui.TableNextColumn(ctx)
        ImGui.TextDisabled(ctx, #tracks .. " tracks")
        for _, s in ipairs(cols) do
          ImGui.TableNextColumn(ctx)
          if ImGui.SmallButton(ctx, "All##a" .. s.id) then for _, t in ipairs(tracks) do grid[t.guid][s.id] = true end end
          ImGui.SameLine(ctx, 0, 3)
          if ImGui.SmallButton(ctx, "None##n" .. s.id) then for _, t in ipairs(tracks) do grid[t.guid][s.id] = false end end
        end
        for _, t in ipairs(tracks) do
          ImGui.TableNextRow(ctx)
          ImGui.TableNextColumn(ctx)
          ImGui.AlignTextToFramePadding(ctx)
          ImGui.Text(ctx, string.rep("   ", t.depth) .. t.num .. "  " .. t.name)
          for _, s in ipairs(cols) do
            ImGui.TableNextColumn(ctx)
            local sug = suggested[t.guid][s.id] and grid[t.guid][s.id]
            if sug then ImGui.PushStyleColor(ctx, ImGui.Col_CheckMark, GREEN) end
            local ch, v = ImGui.Checkbox(ctx, "##" .. t.guid .. s.id, grid[t.guid][s.id] == true)
            if sug then ImGui.PopStyleColor(ctx) end
            if ch then grid[t.guid][s.id] = v; suggested[t.guid][s.id] = false end
          end
        end
        ImGui.EndTable(ctx)
      end
    end

    ImGui.BeginDisabled(ctx, problem ~= nil)
    if ImGui.Button(ctx, "Set up") then done = "ok" end
    ImGui.EndDisabled(ctx)
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Cancel") then done = "cancel" end
    ImGui.SameLine(ctx, 0, 20)
    ImGui.TextDisabled(ctx, "New sends: " .. C.SEND_MODE_NAMES[MODE] .. ", " .. C.fmt_start_db(C.new_send_db(cfg)))
    ImGui.End(ctx)
  end
  if not open then done = "cancel" end
  return done
end

local function loop()
  local ok, done = xpcall(frame, debug.traceback)
  if not ok then
    FOLDBACK_SETUP_OPEN = nil
    r.ShowMessageBox("Foldback session setup hit an error:\n\n" .. tostring(done), TITLE, 0)
    return
  end
  if done == "ok" then
    FOLDBACK_SETUP_OPEN = nil
    local okm, err = pcall(apply, want, grid)
    if not okm then
      r.PreventUIRefresh(-1)
      r.Undo_EndBlock("Foldback: set up this session (stopped by an error - Undo reverses it)", -1)
      r.ShowMessageBox("Foldback setup hit an error. Edit > Undo reverses whatever it had done.\n\n" .. tostring(err), TITLE, 0)
    end
  elseif done == "cancel" then
    FOLDBACK_SETUP_OPEN = nil
  else
    r.defer(loop)
  end
end
r.defer(loop)
