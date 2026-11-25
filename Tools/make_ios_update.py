#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Generate ios-update.json from the exact public IPA. No upload is performed."""
import argparse
import hashlib
import json
import plistlib
import re
import zipfile
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--notes", type=Path, required=True, help="UTF-8 update summary")
    parser.add_argument("--notes-en", type=Path, help="Optional UTF-8 English update summary")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.ipa.resolve() == args.output.resolve():
        parser.error("output must not overwrite the IPA")
    with zipfile.ZipFile(args.ipa) as archive:
        names = [n for n in archive.namelist() if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", n)]
        if len(names) != 1:
            parser.error("expected exactly one main application Info.plist")
        info = plistlib.loads(archive.read(names[0]))
    version = info["CFBundleShortVersionString"]
    build_text = info["CFBundleVersion"]
    minimum = info["MinimumOSVersion"]
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        parser.error("version must have three numeric components")
    if not re.fullmatch(r"[0-9]+", build_text) or int(build_text) <= 0:
        parser.error("build must be a positive integer")
    notes = args.notes.read_text(encoding="utf-8").strip()
    if not notes:
        parser.error("notes must not be empty")
    digest = hashlib.sha256()
    with args.ipa.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    metadata = dict(schemaVersion=1, product="CarWithin", platform="ios", version=version,
                    build=int(build_text), minimumOSVersion=minimum, releaseTag="v" + version,
                    ipaName=args.ipa.name, size=args.ipa.stat().st_size,
                    sha256=digest.hexdigest(), notes=notes)
    if args.notes_en is not None:
        notes_en = args.notes_en.read_text(encoding="utf-8").strip()
        if not notes_en:
            parser.error("English notes must not be empty when supplied")
        metadata["notesEn"] = notes_en
    args.output.write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(args.output)


if __name__ == "__main__":
    main()
