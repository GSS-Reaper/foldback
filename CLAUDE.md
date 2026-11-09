# Foldback: notes for Claude Code

Foldback is a headphone cue-mix (foldback) system for REAPER, written in Lua with ReaImGui and a few JSFX effects. It is free, GPL-3.0, copyright holder "Greater Society Studios", and is distributed through ReaPack from the public repo GSS-Reaper/foldback (branch main).

THIS FILE IS PUBLIC. Never put studio-specific details, personal notes, or anything private in it. Those go in CLAUDE.local.md (git-ignored).

## Who you are working with
- The owner is a recording engineer, not a programmer. Say exactly what to click or type, and ask before anything is hard to undo.
- Accuracy over guessing. If you do not know, say so or ask. Check your work before saying it is done.
- Only REAPER can prove the panel works. You cannot see it. After a change, tell the owner exactly what to try in REAPER Test and what they should see.

## Layout
- Foldback-ReaPack/index.xml: the ReaPack index (generated).
- Foldback-ReaPack/Foldback/: the package users install. Foldback_Core.lua (logic, C.VERSION), Foldback_Mixer.lua (docked panel), Foldback_Settings.lua, Foldback_Setup.lua, plus MixTest and Diagnostics (shipped without a `main` attribute, so they are not in the Action list), and JSFX in effects/*.txt.
- Foldback-ReaPack/Foldback/profiles/: the default profiles, Starter Mixes.lua and Starter Stems.lua.
- Foldback-ReaPack/tools/make_index.py: writes index.xml for a release.
- docs/: MANUAL.md, index.html, Foldback-User-Manual.pdf and images/.
- README.md and LICENSE are at the top of the repo.
- Only Mixer, Setup and Settings appear in the user's Action list.

## Product decisions (do not reverse without asking)
- Two equal cue types, chosen by each user at first setup: stems (cue_mode "stems") and mixes (cue_mode "mix"). Neither is the headline in README or forum text.
- Shareable version has NO reverb, NO track-name auto-assign rules, NO Q-Link, NO P16/device channel labels. Output names are enough.
- Users set everything through pop-up menus and settings windows, never by editing a profile text file.
- Mix mode: cues are always stereo. A new track gets a send, starting off (-inf), to every mix. A send the user deleted on purpose is never put back. Folder tracks are skipped. "Start from my mix" copies fader/pan/mute once into a cue.
- Foldback does not auto-correct send modes. Sends are added through the panel or setup.
- Default profiles: "Starter Mixes" (Artist 1-4) and "Starter Stems".
- Stems mode shows one extra button named Metronome. It opens REAPER's metronome settings; Foldback never changes the metronome, cannot read its output, and the metronome cannot join Listen. Mix mode has its own JSFX Click track that follows tempo and time signature only.
- Listen is a toggle. The lit button is red and reads LISTENING. Shift-click combines cues.
- Talkback: hold-to-talk button; the mic input is a profile setting.
- "Remove Foldback from this project..." (Settings pop-up) deletes cue tracks and sends after a confirmation, as one undo step. Foldback then stays off in that project until Setup is run again. It never touches the user's own tracks, other sends, faders, pans or FX.
- Mac and Windows are both supported. Only macOS has been tested so far. Fix Windows reports as they arrive.

## Gotchas learned the hard way
- JSFX/EEL2 does not accept scientific-notation literals (1e-7). Use plain numbers. A click track stayed silent because of this.
- ReaImGui hashes the text before "##" into the widget ID. A label that changes while a button is held makes a new widget and drops the press. Use a constant ID such as "Talkback###talk".
- Create the ImGui context after the slow font lookup, with one retry, or you get "ImGui_Attach: expected a valid ImGui_Context*".
- Foldback needs only ReaImGui. SWS (CF_*) and js_ReaScriptAPI (JS_*) calls must stay behind APIExists guards.
- Opening REAPER's metronome settings instantly makes REAPER close them again. Keep the ~0.25 s delay.
- Every undo block must be closed, even after an error.
- Installing must never overwrite a user's existing profile. Profile changes for existing users go through one-time migrations marked with flag files.

## Testing
- There is no mock-REAPER test yet and no tests/ folder in the repo.
- Foldback_Test.lua and Foldback_UndoTest.lua run inside REAPER. They are in REAPER Test (Scripts/Foldback), not in the repo or the package.
- Real checks happen in a separate portable REAPER copy ("REAPER Test"), never in the owner's main REAPER first.

## Releasing (ReaPack)
Edit Foldback files only in this repo, never in REAPER Test; run tools/sync_to_test.sh to copy them there for testing.

Releases are built only from this repo. Run the commands below from the repo's Foldback-ReaPack folder.
1. Set C.VERSION in Foldback_Core.lua to the new version. Run `bash tools/sync_to_test.sh` and test in REAPER Test.
2. Run `python3 tools/make_index.py --user GSS-Reaper --repo foldback --version X.Y.Z --repo-path Foldback-ReaPack --holder "Greater Society Studios" --notes "..."`. It reads the package files from Foldback-ReaPack/Foldback (`--source` can point somewhere else, but releases should not need it) and adds the copyright notice only to files that lack it. It refuses a version number already in index.xml. Never add `--fresh` unless starting the index over. Check that older versions' entries are unchanged.
3. Commit to main and push. Do NOT include *.bak files.
4. Only after the push, create the release with a tag that is EXACTLY `vX.Y.Z` (no extra dots; a typo once caused 404s). Tags are snapshots, so the release comes after the push. Use `gh release create`.
5. In REAPER: Extensions > ReaPack > Synchronize packages. ReaPack caches the index until you do.
- ReaPack import address: https://github.com/GSS-Reaper/foldback/raw/main/Foldback-ReaPack/index.xml
- Always ask the owner before pushing or creating a release.

## Git rules
- The commit identity must be the GitHub noreply address, never a personal email. Check `git config user.email` inside this repo before committing.
- Never commit CLAUDE.local.md, *.bak files, or any studio-specific profile.
- Small commits with plain messages. Do not rewrite history on main.
