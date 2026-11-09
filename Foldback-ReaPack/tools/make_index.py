#!/usr/bin/env python3
"""Builds the Foldback ReaPack package folder and its index.xml, from the files in this repo.

  python3 tools/make_index.py --user YOURGITHUBNAME --repo foldback --version 0.6.0 --repo-path Foldback-ReaPack --notes "What changed"

1. Reads the package files from --source (by default the Foldback/ folder next to tools/), adds the
   copyright notice to any file that does not have it yet, and writes them to Foldback/.
2. Writes index.xml. Every file URL points at the git TAG v<version>, so a version never changes once published.
Older versions already listed in index.xml are kept.
"""
import argparse, datetime, os, shutil, sys
import xml.etree.ElementTree as ET
from urllib.parse import quote

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
NOTICE_MARK = "Foldback - Copyright (C)"

MAIN_SCRIPTS = ["Foldback_Mixer.lua", "Foldback_Setup.lua", "Foldback_Settings.lua"]
# installed, but not added to the Action list (run them with Actions > Load ReaScript when troubleshooting)
OTHER_FILES = ["Foldback_Core.lua", "Foldback_MixTest.lua", "Foldback_Diagnostics.lua", "profiles/Starter Mixes.lua", "profiles/Starter Stems.lua",
               "effects/Foldback_MonoSum.txt", "effects/Foldback_TestTone.txt",
               "effects/Foldback_Limiter.txt", "effects/Foldback_Click.txt"]

ap = argparse.ArgumentParser()
ap.add_argument("--user", required=True)
ap.add_argument("--repo", required=True)
ap.add_argument("--version", required=True)
ap.add_argument("--author", default=None)
ap.add_argument("--notes", default="")
ap.add_argument("--index-name", default="Foldback")
ap.add_argument("--repo-path", default="", help="folder inside the GitHub repository that holds this package, e.g. Foldback-ReaPack")
ap.add_argument("--holder", default="Greater Society Studios", help="name in the copyright notice")
ap.add_argument("--source", default=os.path.join(REPO, "Foldback"), help="folder to read the package files from (default: the Foldback folder next to tools/)")
ap.add_argument("--fresh", action="store_true", help="ignore any existing index.xml and start a new one")
a = ap.parse_args()
author = a.author or a.user
source = os.path.abspath(a.source)

# 1. copy files
dest = os.path.join(REPO, "Foldback")
for rel in MAIN_SCRIPTS + OTHER_FILES:
    src = os.path.join(source, rel)
    if not os.path.isfile(src):
        sys.exit("missing file: " + src)
    out = os.path.join(dest, rel)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    text = open(src, encoding="utf-8").read()
    mark = "// " if rel.startswith("effects/") else "-- "
    notice = mark + "Foldback - Copyright (C) 2026 " + a.holder + ". Free software under the GNU General Public License v3.0 (see LICENSE)."
    lines = text.split("\n")
    # never add the notice twice, so running this again changes nothing
    has_notice = NOTICE_MARK in text or any("GNU General Public License" in line for line in lines[:3])
    if not has_notice:
        # a JSFX file must keep its desc: line first, so the notice goes right after it
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
prefix = (a.repo_path.strip("/") + "/") if a.repo_path else ""
base = "https://github.com/%s/%s/raw/v%s/%sFoldback/" % (a.user, a.repo, a.version, prefix)
for rel in MAIN_SCRIPTS + OTHER_FILES:
    attrs = {"file": rel}
    if rel in MAIN_SCRIPTS:
        attrs["main"] = "main"
    ET.SubElement(ver, "source", attrs).text = base + quote(rel)

ET.indent(root)
ET.ElementTree(root).write(idx_path, encoding="utf-8", xml_declaration=True)
print("Wrote", idx_path)
print("Version", a.version, "->", len(MAIN_SCRIPTS + OTHER_FILES), "files")
print("Import URL for users: https://github.com/%s/%s/raw/main/%sindex.xml  (use 'master' instead of 'main' if your branch is called master)" % (a.user, a.repo, prefix))
