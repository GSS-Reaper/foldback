Foldback

Headphone (cue) mixes for REAPER. Foldback builds the cue tracks, sends and hardware routing for you, gives you one mixer panel to control them, and keeps a Listen button, an optional limiter, an optional click and optional talkback alongside.

Free and open source under the GNU General Public License v3.0.

Two ways to work: pick the one that fits your studio

When you set Foldback up, you choose a cue type. 

Stems: groups of instruments

Each cue is a group of instruments (for example Drums, Bass, Guitars, Keys, Vocals). Each group goes to its own channel, and the musician blends the groups on a personal mixer or a headphone amp with several inputs.

Choose stems if:

Your musicians have a personal mixer (or a multi-input headphone system) and like to make their own blend.
You want the same group layout every session.

What you get in stems mode: stereo or mono groups, track-name rules that assign tracks to groups, and REAPER's own metronome sent to its own channel as the click.

Mixes: one stereo mix per performer

Each cue is one performer's complete stereo mix. Every track can send to every mix, and you set the level and pan of each send in the panel.

Choose mixes if:

Each performer gets a single stereo feed to their headphones.
You want to build each person's mix yourself.

What you get in mixes mode: per-send level and pan, new tracks automatically getting a silent send to every mix, and an optional Foldback click track that feeds every mix.

Features in either mode
Listen button. Hear any cue on your own monitors. By default it follows the first hardware output of your master track.
Safety limiter. Optional limiter at the end of each cue, with an adjustable ceiling.
Talkback. Optional "Hold to talk" button that opens a microphone to the cues only while you hold it.
Profiles. Foldback keeps your cue names, outputs and options in profiles. It comes with two starting points: Starter (four mixes named Artist 1 to Artist 4) and Starter Stems (Drums, Bass, Guitars, Keys, Vocals and a click). Switch between them, or make your own, in Foldback Settings.
Requirements
REAPER
ReaPack (to install and update)
ReaImGui (install it from ReaPack: Extensions > ReaPack > Browse packages, search ReaImGui)

SWS and js_ReaScriptAPI are not required.

Install
In REAPER, open Extensions > ReaPack > Manage repositories.
Click Import/export, then Import repositories.
Paste this address and click OK: https://github.com/GSS-Reaper/foldback/raw/main/Foldback-ReaPack/index.xml
Open Extensions > ReaPack > Browse packages, find Foldback, right-click it and choose Install, then click Apply.
Open Actions > Show action list and search for Foldback. You should see three actions: Foldback_Mixer, Foldback_Setup and Foldback_Settings.
First-time setup
Choose your cue type. Run Foldback_Settings and open the Cues tab. The Cue type menu offers Stems (groups of instruments) and Mixes (one stereo mix per performer). Choose the one you want.
Name your cues and pick their outputs in the same tab. For each cue, choose the REAPER output it plays from.
Choose your options (limiter, talkback, and, in mixes mode, the Foldback click track).
Run Foldback_Setup in each project to pick which cues that session uses and build the tracks and sends.
Run Foldback_Mixer to open the panel and control the cues.
Troubleshooting scripts

Two extra scripts are installed in the Foldback folder but are hidden from the Action list: Foldback_MixTest.lua and Foldback_Diagnostics.lua. MixTest runs automatic audio checks on your session; Diagnostics reports your setup. To run one, open Actions > Show action list > New action > Load ReaScript, then pick the file from Scripts/Foldback/Foldback/ in your REAPER resource folder. Please include the output if you report a problem.

Limits
The Foldback click track (mixes mode) follows tempo and time signature only. It does not use REAPER's metronome sound, volume, count-in or on/off setting, and it plays only while the project plays. The accented beat assumes a constant time signature from the project start.
Talkback has no ducking and no latch.
Developed and tested on macOS. Windows support is written but has not been tested.
Feedback

Please report problems under Issues on this repository, with your REAPER version, your operating system and, if you can, the MixTest output.

License

GPL-3.0. See the LICENSE file. Copyright (C) 2026 Greater Society Studios.
