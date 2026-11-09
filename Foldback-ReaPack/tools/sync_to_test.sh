#!/bin/bash
# Copies the 12 package files from this repo into a portable REAPER Test copy:
#   Scripts/Foldback           (installer source)
#   Scripts/Foldback/Foldback  (installed copy)
#
# It only copies the 12 files named below. It never deletes anything, and it
# never touches Foldback_Install.lua, Foldback_Test.lua or Foldback_UndoTest.lua.
#
# Usage: bash sync_to_test.sh ["/path/to/REAPER Test"]

set -euo pipefail

REAPER_TEST="${1:-$HOME/Documents/Claude Code/REAPER Test}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE="$(dirname "$HERE")/Foldback"

SOURCE_DIR="$REAPER_TEST/Scripts/Foldback"
INSTALLED_DIR="$REAPER_TEST/Scripts/Foldback/Foldback"

FILES=(
  "Foldback_Core.lua"
  "Foldback_Diagnostics.lua"
  "Foldback_MixTest.lua"
  "Foldback_Mixer.lua"
  "Foldback_Settings.lua"
  "Foldback_Setup.lua"
  "effects/Foldback_Click.txt"
  "effects/Foldback_Limiter.txt"
  "effects/Foldback_MonoSum.txt"
  "effects/Foldback_TestTone.txt"
  "profiles/Starter Mixes.lua"
  "profiles/Starter Stems.lua"
)

# Check everything first, so a problem stops the script before any file changes.
for rel in "${FILES[@]}"; do
  if [ ! -f "$PACKAGE/$rel" ]; then
    echo "STOPPED, nothing copied. Missing from the repo: $PACKAGE/$rel" >&2
    exit 1
  fi
done
for dir in "$SOURCE_DIR" "$INSTALLED_DIR"; do
  for sub in "" "/effects" "/profiles"; do
    if [ ! -d "$dir$sub" ]; then
      echo "STOPPED, nothing copied. Folder not found: $dir$sub" >&2
      exit 1
    fi
  done
done

copied=0
same=0

for dest in "$SOURCE_DIR" "$INSTALLED_DIR"; do
  echo
  echo "Into: $dest"
  for rel in "${FILES[@]}"; do
    if [ -f "$dest/$rel" ] && cmp -s "$PACKAGE/$rel" "$dest/$rel"; then
      echo "  already the same, left alone: $rel"
      same=$((same + 1))
    else
      cp "$PACKAGE/$rel" "$dest/$rel"
      echo "  COPIED: $rel"
      copied=$((copied + 1))
    fi
  done
done

echo
echo "Done. Copied $copied file(s). Left $same file(s) alone because they already matched."
