-- Foldback - Copyright (C) 2026 Greater Society Studios. Free software under the GNU General Public License v3.0 (see LICENSE).
-- Foldback profile: Starter Mixes
-- Foldback copies this into <REAPER resource folder>/Foldback/profiles the first time it runs.
-- One stereo headphone mix per performer. Change everything in Foldback Settings
-- (panel > Settings > Foldback settings...): rename or add mixes, and choose each mix's output.
return {
  profile_name = "Starter Mixes",
  cue_mode = "mix",
  monitor_output = nil,   -- nil = Listen plays on the same outputs as your master track
  stems = {
    { id = "artist1", name = "Artist 1", width = "stereo", ui_color = { 116, 128, 180 } },
    { id = "artist2", name = "Artist 2", width = "stereo", ui_color = { 169, 157,  96 } },
    { id = "artist3", name = "Artist 3", width = "stereo", ui_color = { 166,  92,  89 } },
    { id = "artist4", name = "Artist 4", width = "stereo", ui_color = { 148, 116, 180 } },
  },
  options = {
    default_stems = "artist1 artist2 artist3 artist4",
    hide_cue_tracks_in_arrange = true,
    hide_cue_tracks_in_mixer = true,
    auto_send_db = 0.0,
    mix_send_db = -150,
    mix_new_tracks = "all",
    auto_setup_new_projects = false,
    listen_off_on_open = true,
    send_mode = "prefader",
    enforce_send_mode = false,
    skip_folder_tracks = true,
    cue_prefix = "CUE ",
    listen_name = "CUE LISTEN",
    listen_color = { 220, 40, 40 },
    limiter = true,
    click_track = true,
    talkback = false,
    limiter_ceiling_db = -3,
  },
  panel_colors = {},
}
