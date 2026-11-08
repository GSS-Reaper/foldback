-- Foldback - Copyright (C) 2026 Greater Society Studios. Free software under the GNU General Public License v3.0 (see LICENSE).
-- Foldback profile: Starter Stems
-- A starting point for sending groups of instruments (stems) to musicians who blend their own mix. Foldback copies it into <REAPER resource folder>/Foldback/profiles
-- the first time it runs. Change it in Foldback Settings (panel > Settings > Foldback settings...).
return {
  profile_name = "Starter Stems",
  monitor_output = nil,   -- Listen: the first output of the stereo pair that feeds your speakers
  stems = {
    { id = "drums",   name = "Drums",   width = "stereo", ui_color = { 169, 157,  96 } },
    { id = "bass",    name = "Bass",    width = "mono",   ui_color = { 148, 116, 180 } },
    { id = "guitars", name = "Guitars", width = "stereo", ui_color = { 166,  92,  89 } },
    { id = "keys",    name = "Keys",    width = "stereo", ui_color = { 117, 152, 112 } },
    { id = "vocals",  name = "Vocals",  width = "mono",   ui_color = { 116, 128, 180 } },
    { id = "click",   name = "Metronome", width = "mono", metronome = true },
  },
  options = {
    default_stems = "drums bass guitars vocals",
    hide_cue_tracks_in_arrange = true,
    hide_cue_tracks_in_mixer = true,
    auto_send_db = 0.0,
    auto_setup_new_projects = false,
    listen_off_on_open = true,
    send_mode = "prefader",
    enforce_send_mode = false,
    cue_prefix = "CUE ",
    listen_name = "CUE LISTEN",
    listen_color = { 220, 40, 40 },
  },
  panel_colors = {},
}
