-- Foldback - Copyright (C) 2026 Greater Society Studios. Free software under the GNU General Public License v3.0 (see LICENSE).
-- Foldback System - Diagnostics (READ-ONLY)
-- Writes a report to <resource path>/Foldback/logs/diagnostics.txt
-- Changes nothing in the project or in REAPER's settings.
local r = reaper
local res = r.GetResourcePath()
local dir = res .. "/Foldback/logs"
r.RecursiveCreateDirectory(dir, 0)
local path = dir .. "/diagnostics.txt"
local out = {}
local function w(...)
  local t = {}
  for i = 1, select('#', ...) do t[#t + 1] = tostring((select(i, ...))) end
  out[#out + 1] = table.concat(t, " ")
end
local function try(label, fn)
  local ok, a, b, c = pcall(fn)
  if ok then w(label, a, b, c) else w(label, "ERROR:", a) end
end

w("Foldback diagnostics", os.date("%Y-%m-%d %H:%M:%S"))
w("REAPER version:", r.GetAppVersion())
w("Resource path:", res)
w("OS:", r.GetOS())

-- Extensions
try("SWS version:", function() return r.CF_GetSWSVersion() end)
w("ReaImGui API present:", r.APIExists("ImGui_GetBuiltinPath"))
try("ImGui_GetVersion:", function() return r.ImGui_GetVersion() end)
local ok, err = pcall(function()
  package.path = r.ImGui_GetBuiltinPath() .. '/?.lua'
  local ImGui = require 'imgui' '0.10'
  w("require imgui '0.10': OK, CreateContext is", type(ImGui.CreateContext))
end)
if not ok then w("require imgui '0.10' FAILED:", err) end

-- Audio device
try("Audio output device:", function() local _, v = r.GetAudioDeviceInfo("IDENT_OUT", ""); return v end)
try("Device sample rate:", function() local _, v = r.GetAudioDeviceInfo("SRATE", ""); return v end)
try("Device buffer size:", function() local _, v = r.GetAudioDeviceInfo("BSIZE", ""); return v end)
w("Project sample rate:", r.GetSetProjectInfo(0, "PROJECT_SRATE", 0, false),
  "(project rate in use:", r.GetSetProjectInfo(0, "PROJECT_SRATE_USE", 0, false), ")")

local nout = r.GetNumAudioOutputs()
w("")
w("Number of audio outputs:", nout)
for i = 0, nout - 1 do
  w(string.format("  out index %d  (Reaper output %d): %s", i, i + 1, r.GetOutputChannelName(i)))
end
local nin = r.GetNumAudioInputs()
w("")
w("Number of audio inputs:", nin)
for i = 0, nin - 1 do
  w(string.format("  in index %d  (Reaper input %d): %s", i, i + 1, r.GetInputChannelName(i)))
end

-- Master track
local m = r.GetMasterTrack(0)
w("")
w("Master track channels:", r.GetMediaTrackInfo_Value(m, "I_NCHAN"))
w("Master pan law (D_PANLAW, -1 = project default):", r.GetMediaTrackInfo_Value(m, "D_PANLAW"))
local nhw = r.GetTrackNumSends(m, 1)
w("Master hardware outputs:", nhw)
for s = 0, nhw - 1 do
  w(string.format("  hw out %d: src=%d dst=%d vol=%.3f mute=%d",
    s,
    r.GetTrackSendInfo_Value(m, 1, s, "I_SRCCHAN"),
    r.GetTrackSendInfo_Value(m, 1, s, "I_DSTCHAN"),
    r.GetTrackSendInfo_Value(m, 1, s, "D_VOL"),
    r.GetTrackSendInfo_Value(m, 1, s, "B_MUTE")))
end
w("Tracks in current project:", r.CountTracks(0))
local _, projname = r.EnumProjects(-1, "")
w("Current project file:", projname)

-- Config variables (value -99999 means the name doesn't exist)
w("")
if r.APIExists("SNM_GetIntConfigVar") then
  for _, k in ipairs({ "defsendflag", "defsendvol", "defhwvol", "defpanmode", "panlaw" }) do
    w("config", k, "=", r.SNM_GetIntConfigVar(k, -99999))
  end
end

local f = io.open(path, "w")
f:write(table.concat(out, "\n") .. "\n")
f:close()
r.ShowMessageBox("Diagnostics written to:\n" .. path .. "\n\nNothing was changed.", "Foldback", 0)
