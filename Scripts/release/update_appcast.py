#!/usr/bin/env python3
"""Insert a new <item> into a Sparkle appcast.xml.

Usage:
    update_appcast.py \\
        --appcast path/to/appcast.xml \\
        --version 0.6.0 \\
        --build 14 \\
        --min-system 15.0 \\
        --dmg path/to/VoiceTyping-0.6.0.dmg \\
        --dmg-url https://github.com/016hiro/voice_typing/releases/download/v0.6.0/VoiceTyping-0.6.0.dmg \\
        --ed-signature <base64> \\
        [--release-notes path/to/release-notes.html]

- Reads --appcast in place, inserts a new <item> at the top of <channel>
  (newest first), and writes back.
- Skips insertion if an item with the same <sparkle:version> (build number)
  already exists — idempotent for reruns.
- stdlib only (xml.etree + email.utils).
"""

from __future__ import annotations

import argparse
import os
import sys
from email.utils import formatdate
from pathlib import Path
from xml.etree import ElementTree as ET

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE_NS)
ET.register_namespace("dc", "http://purl.org/dc/elements/1.1/")


def sp(tag: str) -> str:
    return f"{{{SPARKLE_NS}}}{tag}"


def find_channel(root: ET.Element) -> ET.Element:
    channel = root.find("channel")
    if channel is None:
        raise SystemExit("error: appcast has no <channel>")
    return channel


def already_has_build(channel: ET.Element, build: str) -> bool:
    for item in channel.findall("item"):
        v = item.find(sp("version"))
        if v is not None and (v.text or "").strip() == build:
            return True
    return False


def build_item(args: argparse.Namespace) -> ET.Element:
    item = ET.Element("item")
    ET.SubElement(item, "title").text = f"Version {args.version}"
    ET.SubElement(item, "pubDate").text = formatdate(localtime=False, usegmt=True)
    ET.SubElement(item, sp("version")).text = args.build
    ET.SubElement(item, sp("shortVersionString")).text = args.version
    ET.SubElement(item, sp("minimumSystemVersion")).text = args.min_system

    if args.release_notes:
        notes_path = Path(args.release_notes)
        if not notes_path.exists():
            raise SystemExit(f"error: release notes file not found: {notes_path}")
        desc = ET.SubElement(item, "description")
        # CDATA handling: ElementTree doesn't preserve CDATA wrappers, but
        # Sparkle accepts plain HTML in <description>. Escaping happens
        # automatically via ET's text serialization.
        desc.text = notes_path.read_text(encoding="utf-8")

    length = os.path.getsize(args.dmg)
    enclosure = ET.SubElement(
        item,
        "enclosure",
        {
            "url": args.dmg_url,
            sp("edSignature"): args.ed_signature,
            "length": str(length),
            "type": "application/octet-stream",
        },
    )
    _ = enclosure  # silence unused-var hint
    return item


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--appcast", required=True, help="Path to appcast.xml")
    ap.add_argument("--version", required=True, help="Short version (e.g. 0.6.0)")
    ap.add_argument("--build", required=True, help="Build number (CFBundleVersion)")
    ap.add_argument("--min-system", default="15.0", help="LSMinimumSystemVersion")
    ap.add_argument("--dmg", required=True, help="Path to the DMG (for size)")
    ap.add_argument("--dmg-url", required=True, help="Public download URL for the DMG")
    ap.add_argument("--ed-signature", required=True,
                    help="EdDSA signature from `sign_update -p <dmg>`")
    ap.add_argument("--release-notes", default=None,
                    help="Optional path to release-notes.html (CDATA-wrapped)")
    args = ap.parse_args()

    appcast_path = Path(args.appcast)
    if not appcast_path.exists():
        raise SystemExit(f"error: appcast not found: {appcast_path}")
    if not Path(args.dmg).exists():
        raise SystemExit(f"error: dmg not found: {args.dmg}")

    tree = ET.parse(appcast_path)
    root = tree.getroot()
    channel = find_channel(root)

    if already_has_build(channel, args.build):
        print(f"skip: build {args.build} already present in {appcast_path}")
        return 0

    new_item = build_item(args)
    # Insert after the <channel> metadata block, before any existing items
    # (so newest is on top).
    insert_at = 0
    for i, child in enumerate(list(channel)):
        if child.tag == "item":
            insert_at = i
            break
        insert_at = i + 1
    channel.insert(insert_at, new_item)

    ET.indent(tree, space="  ")
    tree.write(appcast_path, encoding="utf-8", xml_declaration=True)
    print(f"inserted: version={args.version} build={args.build} into {appcast_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
