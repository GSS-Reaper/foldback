-- Foldback - Copyright (C) 2026 Greater Society Studios. Free software under the GNU General Public License v3.0 (see LICENSE).
-- @description Foldback: mix mode automated test
-- Builds temporary tracks (a -18 dBFS 440 Hz tone, one stereo test mix with NO hardware output,
-- and one spare track), then checks mix mode: new sends start off, a send you removed isn't put
-- back, "pick" mode adds nothing, "Start from my mix" copies fader/pan/mute, and (during playback)
-- the send's level and pan do what they should and the source fader/mute don't change the cue.
-- Run it in an EMPTY project tab. Removes its temporary tracks when finished. Writes logs/mixtest.txt
local r = reaper
local script_dir = ({ r.get_action_context() })[2]:match("^(.*[/\\])")
local C = dofile(script_dir .. "Foldback_Core.lua")
local TITLE = "Foldback mix mode test"

local PHASE_LEN = 3.5   -- REAPER's peak meter falls about 16 dB in the first 0.6 s, so "silent" needs time to show
local SETTLE = 0.6

if r.CountTracks(0) > 0 then
  local a = r.ShowMessageBox(
    "This test is meant for an EMPTY project tab (File > New project tab).\n\n" ..
    "It starts playback; anything in this project will play too.\n\nRun it here anyway?", TITLE, 4)
  if a ~= 6 then return end
end

local log = C.new_log("mixtest.txt")
local pass, fail = 0, 0
local function chk(name, ok, detail)
  if ok then pass = pass + 1 else fail = fail + 1 end
  log.w(string.format("%-62s %s%s", name, ok and "PASS" or "FAIL", detail and ("   (" .. detail .. ")") or ""))
end
local function approx(a, b, tol) return math.abs(a - b) <= (tol or 1e-4) end

---------------------------------------------------------------- build
r.PreventUIRefresh(1)
local function tag(tr) C.set_ext(tr, C.KEY_TEST, "1") end

local tone = C.new_track_at_end()
tag(tone)
r.GetSetMediaTrackInfo_String(tone, "P_NAME", "FOLDBACK TEST tone", true)
r.SetMediaTrackInfo_Value(tone, "B_MAINSEND", 0)
local _, fxname = C.add_fx(tone, C.TONE_FX)
local pos = r.GetCursorPosition()
r.CreateNewMIDIItemInProj(tone, pos, pos + 60, false)

local cue = C.new_track_at_end()
tag(cue)
C.configure_cue(cue, { name = "mix", width = "stereo" }, nil, { prefix = "FOLDBACK TEST mix ", hide_tcp = false })

local other = C.new_track_at_end()
tag(other)
r.GetSetMediaTrackInfo_String(other, "P_NAME", "FOLDBACK TEST other track", true)
r.SetMediaTrackInfo_Value(other, "B_MAINSEND", 0)
r.PreventUIRefresh(-1)
r.TrackList_AdjustWindows(false)

local started_play, cleaned = false, false
local function cleanup()
  if cleaned then return end
  cleaned = true
  if started_play then r.OnStopButton() end
  r.PreventUIRefresh(1)
  local _, _, tests = C.scan()
  for i = #tests, 1, -1 do r.DeleteTrack(tests[i]) end
  r.PreventUIRefresh(-1)
  r.TrackList_AdjustWindows(false)
  r.UpdateArrange()
end
r.atexit(cleanup)

if not fxname then
  log.err("Test tone effect could not be loaded.")
  log.save(); cleanup()
  r.ShowMessageBox("Test setup failed. Details: " .. log.path, TITLE, 0)
  return
end

---------------------------------------------------------------- logic checks (no playback needed)
local cues = { testmix = cue }
local function profile(new_tracks)
  return { cue_mode = "mix", stems = { { id = "testmix", name = "test", width = "stereo" } },
    options = { mix_send_db = -150, mix_new_tracks = new_tracks, skip_folder_tracks = true, send_mode = "prefader" } }
end
local cfg_all, cfg_pick = profile("all"), profile("pick")

local msg = C.mix_assign(tone, cfg_all, cues)
local idx = C.find_send(tone, cue)
chk("New track gets a send to the mix", idx ~= nil and msg ~= nil, tostring(msg))
chk("The send starts off (-inf)", idx ~= nil and r.GetTrackSendInfo_Value(tone, 0, idx, "D_VOL") == 0)
chk("The send is pre-fader (post-FX)", idx ~= nil and r.GetTrackSendInfo_Value(tone, 0, idx, "I_SENDMODE") == 3)
chk("The send starts centered", idx ~= nil and r.GetTrackSendInfo_Value(tone, 0, idx, "D_PAN") == 0)
local msg2 = C.mix_assign(tone, cfg_all, cues)
chk("Running it again adds nothing", msg2 == nil and r.GetTrackNumSends(tone, 0) == 1)
if idx then r.RemoveTrackSend(tone, 0, idx) end
C.mix_assign(tone, cfg_all, cues)
chk("A send removed on purpose is not put back", C.find_send(tone, cue) == nil)

C.mix_assign(other, cfg_pick, cues)
chk("'No sends until I add them' adds nothing", C.find_send(other, cue) == nil)
C.mix_assign(other, cfg_all, cues)
chk("...and switching to 'every mix' later skips tracks already seen", C.find_send(other, cue) == nil)

-- a fixed start level
local tmp = C.new_track_at_end(); tag(tmp)
local cfg_fixed = profile("all"); cfg_fixed.options.mix_send_db = -9
C.mix_assign(tmp, cfg_fixed, cues)
local ti = C.find_send(tmp, cue)
chk("A fixed start level (-9 dB) is used", ti ~= nil and approx(C.lin2db(r.GetTrackSendInfo_Value(tmp, 0, ti, "D_VOL")), -9, 0.05))
r.DeleteTrack(tmp)

-- Start from my mix
idx = C.ensure_send(tone, cue, 0.0, 3, false)
r.SetMediaTrackInfo_Value(tone, "D_VOL", 0.5)
r.SetMediaTrackInfo_Value(tone, "D_PAN", 0.4)
r.SetMediaTrackInfo_Value(tone, "B_MUTE", 1)
local n = C.start_from_mix(cue, { tone, other })
chk("Start from my mix changed only the track that has a send", n == 1, "changed " .. n)
chk("...copied the fader level", approx(r.GetTrackSendInfo_Value(tone, 0, idx, "D_VOL"), 0.5))
chk("...copied the pan", approx(r.GetTrackSendInfo_Value(tone, 0, idx, "D_PAN"), 0.4))
chk("...copied the mute", r.GetTrackSendInfo_Value(tone, 0, idx, "B_MUTE") == 1)
chk("...and left the source track alone", approx(r.GetMediaTrackInfo_Value(tone, "D_VOL"), 0.5))

-- Listen follows the master track's output when none is chosen
local mi = C.master_out_index()
local li, how = C.listen_index({})
if mi then
  chk("Listen with no output chosen uses the master's output", li == mi and how == "master", "master " .. tostring(mi) .. ", listen " .. tostring(li))
else
  log.w("note: the master track has no hardware output here, so the Listen-follows-master check was skipped")
end
local li2 = C.listen_index({ monitor_output = 1 })
chk("A chosen Listen output wins over the master", li2 == 0)

-- limiter placement and fader cap
r.SetMediaTrackInfo_Value(cue, "D_VOL", C.db2lin(6))
chk("Limiter loads on the cue", C.sync_limiter(cue, true, -20) == true)
local nfx = r.TrackFX_GetCount(cue)
local _, lastname = r.TrackFX_GetFXName(cue, nfx - 1, "")
chk("...as the last effect", lastname:find("Foldback limiter", 1, true) ~= nil, lastname)
chk("...with the ceiling set", approx(r.TrackFX_GetParam(cue, nfx - 1, 0), -20, 0.05), tostring(r.TrackFX_GetParam(cue, nfx - 1, 0)))
chk("...and the cue fader pulled down to 0 dB", approx(r.GetMediaTrackInfo_Value(cue, "D_VOL"), 1.0, 0.001))
C.sync_limiter(cue, true, -20)
chk("Running it again does not add a second limiter", r.TrackFX_GetCount(cue) == nfx)
C.sync_limiter(cue, false)
chk("Turning it off removes it", r.TrackFX_GetCount(cue) == nfx - 1)

-- click track and talkback
local ck = C.ensure_click()
chk("Click track is created with its generator", ck ~= nil)
if ck then
  tag(ck)
  r.SetMediaTrackInfo_Value(ck, "D_VOL", 1.0)
  local cmsg = C.mix_assign(ck, cfg_all, cues)
  chk("The click track gets a send to the mix like any other track", C.find_send(ck, cue) ~= nil, tostring(cmsg))
  chk("The click track never plays to the master", r.GetMediaTrackInfo_Value(ck, "B_MAINSEND") == 0)
end
-- diagnostic: the same generator on a track that has an empty item instead of being armed
local ckB = C.new_track_at_end()
tag(ckB)
r.GetSetMediaTrackInfo_String(ckB, "P_NAME", "FOLDBACK TEST click (item)", true)
r.SetMediaTrackInfo_Value(ckB, "B_MAINSEND", 0)
C.add_fx(ckB, C.CLICK_FX)
do local p0 = r.GetCursorPosition(); r.CreateNewMIDIItemInProj(ckB, p0, p0 + 600, false) end
local ckB_send = C.ensure_send(ckB, cue, 0.0, 3, false)
if ckB_send then r.SetTrackSendInfo_Value(ckB, 0, ckB_send, "D_VOL", 0.0) end   -- silent until its own phase
local tcfg = { stems = { { id = "testmix", name = "test", width = "stereo" } }, options = {} }
local tb = C.ensure_talkback(tcfg, cues)
chk("Talkback track is created", tb ~= nil)
if tb then
  tag(tb)
  local ti2 = C.find_send(tb, cue)
  chk("...with a send to the mix, closed", ti2 ~= nil and r.GetTrackSendInfo_Value(tb, 0, ti2, "B_MUTE") == 1)
  C.talkback_set(true)
  chk("Talk opens the send", ti2 ~= nil and r.GetTrackSendInfo_Value(tb, 0, ti2, "B_MUTE") == 0)
  C.talkback_set(false)
  chk("Letting go closes it again", ti2 ~= nil and r.GetTrackSendInfo_Value(tb, 0, ti2, "B_MUTE") == 1)
  chk("The talkback track never plays to the master", r.GetMediaTrackInfo_Value(tb, "B_MAINSEND") == 0)
end

---------------------------------------------------------------- audio phases
local function reset()
  r.SetMediaTrackInfo_Value(tone, "D_VOL", 1.0)
  r.SetMediaTrackInfo_Value(tone, "B_MUTE", 0)
  r.SetMediaTrackInfo_Value(tone, "D_PAN", 0.0)
  r.SetTrackSendInfo_Value(tone, 0, idx, "D_VOL", 1.0)
  r.SetTrackSendInfo_Value(tone, 0, idx, "D_PAN", 0.0)
  r.SetTrackSendInfo_Value(tone, 0, idx, "B_MUTE", 0)
end
local function sendset(k, v) r.SetTrackSendInfo_Value(tone, 0, idx, k, v) end

local meas, lim_ceiling
local phases = {
  { name = "Send 0 dB, centered (baseline)",  set = function() end },
  { name = "Send off (-inf)",                  set = function() sendset("D_VOL", 0.0) end },
  { name = "Send -12 dB",                      set = function() sendset("D_VOL", C.db2lin(-12)) end },
  { name = "Send 0 dB, pan hard left",         set = function() sendset("D_PAN", -1.0) end },
  { name = "Send 0 dB, pan hard right",        set = function() sendset("D_PAN", 1.0) end },
  { name = "Source fader at -inf (pre-fader)", set = function() r.SetMediaTrackInfo_Value(tone, "D_VOL", 0.0) end },
  { name = "Source muted (pre-fader)",         set = function() r.SetMediaTrackInfo_Value(tone, "B_MUTE", 1) end },
  { name = "Limiter on, ceiling 6 dB below peak", set = function() lim_ceiling = math.max(-24, math.floor(C.lin2db(meas[1].L) + 0.5) - 6); C.sync_limiter(cue, true, lim_ceiling) end },
  { name = "Limiter on, ceiling at 0 dB",         set = function() C.sync_limiter(cue, true, 0) end },
  { name = "Click track (peak on the click track)", track = ck, set = function()
    C.sync_limiter(cue, false)
    -- REAPER may skip a track whose only sends are silent, so open the click's send like a user would
    local cs = ck and C.find_send(ck, cue)
    if cs then r.SetTrackSendInfo_Value(ck, 0, cs, "D_VOL", 1.0) end
  end },
  { name = "Click on a track with an empty item (diagnostic)", track = ckB, set = function()
    local cs = ck and C.find_send(ck, cue)
    if cs then r.SetTrackSendInfo_Value(ck, 0, cs, "D_VOL", 0.0) end
    if ckB_send then r.SetTrackSendInfo_Value(ckB, 0, ckB_send, "D_VOL", 1.0) end
  end },
}
meas = {}
for i = 1, #phases do meas[i] = { L = 0, R = 0, lastL = 0, lastR = 0 } end

if (r.GetPlayState() & 1) == 0 then
  r.OnPlayButton()
  started_play = true
end
local t0 = r.time_precise() + 0.5
local cur = 0

local function finish()
  reset()
  C.sync_limiter(cue, false)
  local function d(v) return C.lin2db(v) end
  local bL, bR = d(meas[1].L), d(meas[1].R)
  log.w("")
  log.w(string.format("%-40s %9s %9s   %9s %9s", "Phase", "loudest L", "loudest R", "end L", "end R"))
  for i, p in ipairs(phases) do
    log.w(string.format("%-40s %9s %9s   %9s %9s", p.name, C.fmtdb(d(meas[i].L)), C.fmtdb(d(meas[i].R)),
      C.fmtdb(d(meas[i].lastL)), C.fmtdb(d(meas[i].lastR))))
  end
  log.w("")
  chk("Baseline: the cue has sound in both ears", bL > -40 and bR > -40, string.format("L %s, R %s", C.fmtdb(bL), C.fmtdb(bR)))
  chk("Send off: the cue is silent (end of phase)", d(meas[2].lastL) < -70 and d(meas[2].lastR) < -70,
    string.format("L %s, R %s", C.fmtdb(d(meas[2].lastL)), C.fmtdb(d(meas[2].lastR))))
  chk("Send -12 dB: both sides are 12 dB below baseline",
    approx(d(meas[3].L), bL - 12, 0.7) and approx(d(meas[3].R), bR - 12, 0.7))
  chk("Pan hard left: right ear is silent, left has sound",
    d(meas[4].lastL) > -40 and d(meas[4].lastR) < d(meas[4].lastL) - 40,
    string.format("L %s, R %s", C.fmtdb(d(meas[4].lastL)), C.fmtdb(d(meas[4].lastR))))
  chk("Pan hard right: left ear is silent, right has sound",
    d(meas[5].lastR) > -40 and d(meas[5].lastL) < d(meas[5].lastR) - 40,
    string.format("L %s, R %s", C.fmtdb(d(meas[5].lastL)), C.fmtdb(d(meas[5].lastR))))
  chk("Source fader at -inf does not change the cue",
    approx(d(meas[6].L), bL, 0.5) and approx(d(meas[6].R), bR, 0.5))
  chk("Source muted does not change the cue",
    approx(d(meas[7].L), bL, 0.5) and approx(d(meas[7].R), bR, 0.5))
  chk("Limiter holds the peak at its ceiling",
    d(meas[8].L) <= lim_ceiling + 0.4 and d(meas[8].L) >= lim_ceiling - 2.0 and d(meas[8].R) <= lim_ceiling + 0.4,
    string.format("ceiling %d, got L %s R %s", lim_ceiling, C.fmtdb(d(meas[8].L)), C.fmtdb(d(meas[8].R))))
  chk("The click track (armed for monitoring) makes sound while playing", ck ~= nil and d(meas[10].L) > -40,
    string.format("click track peak %s; same generator on a track with an item: %s", C.fmtdb(d(meas[10].L)), C.fmtdb(d(meas[11].L))))
  chk("Limiter with a high ceiling leaves the sound alone",
    approx(d(meas[9].L), bL, 0.7) and approx(d(meas[9].R), bR, 0.7),
    string.format("L %s vs %s", C.fmtdb(d(meas[9].L)), C.fmtdb(bL)))
  log.w("")
  log.w(string.format("Pan law note: hard left puts the left ear at %+.1f dB relative to baseline (0 = balance-style, +3 = equal-power).",
    d(meas[4].L) - bL))
  log.w("")
  log.w(string.format("Result: %d passed, %d failed", pass, fail))
  log.save()
  cleanup()
  r.ShowMessageBox(string.format("Mix mode test finished: %d passed, %d failed.\n\nTemporary tracks removed.\nDetails: %s",
    pass, fail, log.path), TITLE, 0)
end

local function loop()
  local now = r.time_precise()
  if now < t0 then r.defer(loop) return end
  local k = math.floor((now - t0) / PHASE_LEN) + 1
  if k > #phases then finish() return end
  if k ~= cur then
    reset()
    phases[k].set()
    cur = k
  end
  if now - (t0 + (k - 1) * PHASE_LEN) >= SETTLE then
    local m = meas[k]
    local mt = phases[k].track or cue
    m.L = math.max(m.L, r.Track_GetPeakInfo(mt, 0))
    m.R = math.max(m.R, r.Track_GetPeakInfo(mt, 1))
    m.lastL = r.Track_GetPeakInfo(mt, 0)      -- the reading at the end of the phase (for "silent" checks)
    m.lastR = r.Track_GetPeakInfo(mt, 1)
  end
  r.defer(loop)
end

log.w("Logic checks done. Running", #phases, "audio phases of", PHASE_LEN, "s ...")
r.defer(loop)
