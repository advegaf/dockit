#!/usr/bin/env python3
"""Write and verify the mounted installer's Finder layout without UI automation."""

import pathlib
import sys

from ds_store import DSStore
from mac_alias import Alias

root = pathlib.Path(sys.argv[1]).resolve(strict=True)
app_name = sys.argv[2]
background = root / ".bg.tiff"
assert (root / app_name).is_dir()
assert (root / "Applications").is_symlink()
assert (root / "Applications").readlink() == pathlib.Path("/Applications")
if "--verify" not in sys.argv:
  with DSStore.open(str(root / ".DS_Store"), "w+") as store:
    store["."]["icvl"] = ("type", b"icnv")
    store["."]["bwsp"] = {
        "ShowStatusBar": False,
        "ShowToolbar": False,
        "ShowSidebar": False,
        "ShowPathbar": False,
        "ShowTabView": False,
        "ContainerShowSidebar": False,
        "PreviewPaneVisibility": False,
        "SidebarWidth": 0,
        "WindowBounds": "{{200, 200}, {660, 422}}",
    }
    store["."]["icvp"] = {
        "viewOptionsVersion": 1,
        "backgroundType": 2,
        "backgroundImageAlias": Alias.for_file(str(background)).to_bytes(),
        "backgroundColorRed": 0.0,
        "backgroundColorGreen": 0.0,
        "backgroundColorBlue": 0.0,
        "iconSize": 96.0,
        "textSize": 11.0,
        "gridSpacing": 100.0,
        "gridOffsetX": 0.0,
        "gridOffsetY": 0.0,
        "scrollPositionX": 0.0,
        "scrollPositionY": 0.0,
        "arrangeBy": "none",
        "labelOnBottom": True,
        "showIconPreview": False,
        "showItemInfo": False,
    }
    store[app_name]["Iloc"] = (220, 270)
    store["Applications"]["Iloc"] = (440, 270)
with DSStore.open(str(root / ".DS_Store"), "r") as store:
    assert store[app_name]["Iloc"] == (220, 270)
    assert store["Applications"]["Iloc"] == (440, 270)
    assert store["."]["icvp"]["iconSize"] == 96.0
    assert store["."]["icvp"]["textSize"] == 11.0
    assert store["."]["icvp"]["showIconPreview"] is False
    assert store["."]["icvp"]["scrollPositionX"] == store["."]["icvp"]["scrollPositionY"] == 0.0
    alias = Alias.from_bytes(store["."]["icvp"]["backgroundImageAlias"])
    assert alias.target.filename == ".bg.tiff"
    assert alias.target.cnid == background.stat().st_ino
    assert store["."]["bwsp"]["ShowToolbar"] is False
    assert store["."]["bwsp"]["WindowBounds"] == "{{200, 200}, {660, 422}}"
print("installer layout verified")
