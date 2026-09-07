#!/usr/bin/env python3
"""Reject test-only app configuration from usable installers."""

import pathlib
import plistlib
import re
import sys


def marketing_version():
    """The version project.yml declares, so a bump there is the only bump."""
    project = pathlib.Path(__file__).resolve().parents[2] / "project.yml"
    match = re.search(r'MARKETING_VERSION:\s*"([^"]+)"', project.read_text())
    if not match:
        raise ValueError("MARKETING_VERSION missing from project.yml")
    return match.group(1)


def validate(app, mode):
    if mode not in {"preview", "development", "release"}:
        raise ValueError("mode must be preview, development or release")
    with (pathlib.Path(app) / "Contents" / "Info.plist").open("rb") as source:
        info = plistlib.load(source)
    if mode == "preview":
        return
    expected = marketing_version()
    if info.get("CFBundleShortVersionString") != expected:
        raise ValueError(f"usable installer requires app version {expected}")
    extension_info = pathlib.Path(app) / "Contents" / "Extensions" / "DockitFocusExtension.appex" / "Contents" / "Info.plist"
    with extension_info.open("rb") as source:
        extension = plistlib.load(source)
    if extension.get("CFBundleShortVersionString") != expected:
        raise ValueError(f"usable installer requires Focus extension version {expected}")
    identifier = info.get("CFBundleIdentifier", "")
    if identifier != "com.advegaf.dockit":
        raise ValueError(f"usable installer requires com.advegaf.dockit, got {identifier!r}")
    environment = info.get("LSEnvironment", {})
    if not isinstance(environment, dict):
        raise ValueError("LSEnvironment must be a dictionary")
    forbidden = sorted(key for key in environment if key.startswith("DOCKIT_"))
    if forbidden:
        raise ValueError("usable installer refuses test environment keys: " + ", ".join(forbidden))
    if any("preview" in str(info.get(key, "")).lower() for key in ("CFBundleName", "CFBundleDisplayName")):
        raise ValueError("usable installer refuses preview product names")


if __name__ == "__main__":
    try:
        validate(sys.argv[1], sys.argv[2])
    except (IndexError, OSError, ValueError, plistlib.InvalidFileException) as error:
        print(f"dmg: {error}", file=sys.stderr)
        sys.exit(1)
