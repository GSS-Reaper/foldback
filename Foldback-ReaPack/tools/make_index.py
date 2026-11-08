#!/usr/bin/env python3
"""Builds the Foldback ReaPack repository folder and its index.xml.

  python3 tools/make_index.py --user YOURGITHUBNAME --repo foldback --version 0.6.0 --notes "What changed"

1. Copies the current Foldback files from the test copy into Foldback/ (this folder is what you upload).
2. Writes index.xml. Every file URL points at the git TAG v<version>, so a version never changes once published.
Older versions already listed in index.xml are kept.
"""
import argparse, datetime, os, shutil, sys
import xml.etree.ElementTree as ET
from urllib.parse import quote

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
DEV = os.path.join(os.path.dirname(REPO), "Scripts", "Foldback")

MAIN_SCRIPTS = ["Foldback_Mixer.lua", "Foldback_Setup.lua", "Foldback_Settings.lua"]
# installed, but not added to the Action list (run them with Actions > Load ReaScript when troubleshooting)
OTHER_FILES = ["Foldback_Core.lua", "Foldback_MixTest.lua", "Foldback_Diagnostics.lua", "profiles/Starter.lua", "profiles/Starter Stems.lua",
               "effects/Foldback_MonoSum.txt", "effects/Foldback_TestTone.txt",
               "effects/Foldback_Limiter.txt", "effects/Foldback_Click.txt"]

ap = argparse.ArgumentParser()
ap.add_argument("--user", required=True)
ap.add_argument("--repo", required=True)
ap.add_argument("--version", required=True)
ap.add_argument("--author", default=None)
ap.add_argument("--notes", default="")
ap.add_argument("--index-name", default="Foldback")
ap.add_argument("--fresh", action="store_true", help="ignore any existing index.xml and start a new one")
a = ap.parse_args()
author = a.author or a.user

# 1. copy files
dest = os.path.join(REPO, "Foldback")
for rel in MAIN_SCRIPTS + OTHER_FILES:
    src = os.path.join(DEV, rel)
    if not os.path.isfile(src):
        sys.exit("missing file: " + src)
    out = os.path.join(dest, rel)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    text = open(src, encoding="utf-8").read()
    mark = "// " if rel.startswith("effects/") else "-- "
    notice = mark + "Foldback - Copyright (C) 2026 Franktree. Free software under the GNU General Public License v3.0 (see LICENSE)."
    if "GNU General Public License" not in text.split("\n", 3)[0:3].__str__():
        # a JSFX file must keep its desc: line first, so the notice goes right after it
        lines = text.split("\n")
        if rel.startswith("effects/") and lines and lines[0].startswith("desc:"):
            lines.insert(1, notice)
        else:
            lines.insert(0, notice)
        text = "\n".join(lines)
    with open(out, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)

# 2. index.xml
idx_path = os.path.join(REPO, "index.xml")
if os.path.isfile(idx_path) and not a.fresh:
    root = ET.parse(idx_path).getroot()
else:
    root = ET.Element("index", {"version": "1", "name": a.index_name})
cat = root.find("category[@name='Foldback']")
if cat is None:
    cat = ET.SubElement(root, "category", {"name": "Foldback"})
pkg = cat.find("reapack[@name='Foldback.lua']")
if pkg is None:
    pkg = ET.SubElement(cat, "reapack", {"name": "Foldback.lua", "type": "script",
                                          "desc": "Foldback - headphone (cue) mixes for REAPER"})
    md = ET.SubElement(pkg, "metadata")
    ET.SubElement(md, "description").text = (
        "Per-performer headphone mixes in REAPER. A small panel lets you set each performer's "
        "level and pan for every track, preview a mix on your speakers (Listen), talk to the "
        "performers (talkback), and protect their ears with a limiter. Needs the ReaImGui extension.")
if pkg.find("version[@name='%s']" % a.version) is not None:
    sys.exit("Version %s is already in index.xml. Use a new version number." % a.version)

ver = ET.SubElement(pkg, "version", {"name": a.version, "author": author,
                                      "time": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")})
if a.notes:
    ET.SubElement(ver, "changelog").text = a.notes
base = "https://github.com/%s/%s/raw/v%s/Foldback/" % (a.user, a.repo, a.version)
for rel in MAIN_SCRIPTS + OTHER_FILES:
    attrs = {"file": rel}
    if rel in MAIN_SCRIPTS:
        attrs["main"] = "main"
    ET.SubElement(ver, "source", attrs).text = base + quote(rel)

ET.indent(root)
ET.ElementTree(root).write(idx_path, encoding="utf-8", xml_declaration=True)
print("Wrote", idx_path)
print("Version", a.version, "->", len(MAIN_SCRIPTS + OTHER_FILES), "files")
print("Import URL for users: https://github.com/%s/%s/raw/master/index.xml  (use 'main' instead of 'master' if your branch is called main)" % (a.user, a.repo))
