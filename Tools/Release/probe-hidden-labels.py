#!/usr/bin/env python3
"""Set zero label size on an isolated test image, never the shipping layout."""

import pathlib
import sys

from ds_store import DSStore

root = pathlib.Path(sys.argv[1]).resolve(strict=True)
assert root.name == "mounted" and root.parent.name.startswith("dockit-label-probe.")
assert (root / "dockit.app").is_dir() and (root / ".bg.tiff").is_file()
with DSStore.open(str(root / ".DS_Store"), "r+") as store:
    options = store["."]["icvp"]
    options["textSize"] = 0.0
    store["."]["icvp"] = options
print("zero textSize test metadata written; only a live Finder check can establish behavior")
