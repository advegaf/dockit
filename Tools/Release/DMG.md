# dmg packaging

The disk image contains the unchanged app, an Applications-folder symlink and hidden Finder layout assets. Packaging never launches or copies the app into Applications. The Python packages are build tools only and are not bundled into dockit.

Prepare the build tools in an isolated environment:

```sh
python3 -m venv /tmp/dockit-dmg-tools
/tmp/dockit-dmg-tools/bin/pip install -r Tools/Release/dmg-requirements.txt
export DOCKIT_DMG_PYTHON=/tmp/dockit-dmg-tools/bin/python
```

Build a local preview from an isolated, ad-hoc-signed app:

```sh
bash Tools/Release/package-dmg.sh /absolute/test/dockit.app /absolute/output/dockit-preview.dmg preview
bash Tools/Release/test-dmg.sh /absolute/test/dockit.app
```

Preview mode names the mounted app `dockit preview.app` and labels the volume and image filename. The signed app's own identity and test environment remain unchanged. Do not install a preview as the everyday app.

For a usable local build that is not yet notarized:

```sh
bash Tools/Release/package-dmg.sh /absolute/development/dockit.app /absolute/output/dockit-development.dmg development
```

Development and release modes require `com.advegaf.dockit` and version `1.0.0` for both the app and Focus extension. They reject preview product names and every `DOCKIT_` entry in `LSEnvironment`. This prevents test-host and demo builds from being delivered as working apps. Development mode preserves the app signature, labels its filename and volume, and does not claim notarization. Release verification applies the same guard before ZIP or DMG creation. Artwork contains no development or notarization notices.

Regenerate the standard and Retina backgrounds from the reviewed full-canvas artwork:

```sh
xcrun swift Tools/Release/InstallerBackground.swift Design/Installer/installer-art.png Design/Installer
```

The generator adds native typography and the arrow. Finder supplies the actual app and Applications icons. The single TIFF is 1320 by 800 pixels at 144 DPI, equivalent to 660 by 400 points. The generated TIFF and the standard and Retina PNGs are build outputs and stay out of git; only `installer-art.png` is committed.

The existing release command creates the ZIP, then stages, signs, notarizes and staples the DMG. Only a verified DMG moves to `dist/dockit-<version>.dmg`. `publish.sh` then creates the GitHub release and uploads that DMG. Development and preview products retain their explicit filenames and must never be relabeled as this release artifact. Set the existing `NOTARY_KEYCHAIN_PROFILE` and prepare the build-only Python environment first. Release mode refuses ad-hoc apps and requires an already stapled app that passes Gatekeeper. Keep all project release gates in force before running this command.

An unsuccessful DMG remains in `.build-release` with its notary result. Preserve or remove that exact unfinished image before retrying. Existing output images are never overwritten by the DMG packager.

Packaging seeds the image with pinned `sindresorhus/create-dmg` 8.1.0 through `npx`, then updates that APFS image. Node and the downloaded packages are build tools only. This follows the working SelfControl release layout on macOS 26. The custom background is a hidden `.bg.tiff` at the volume root. [ds-store](https://ds-store.readthedocs.io/en/latest/) writes fresh Finder metadata and [mac-alias](https://mac-alias.readthedocs.io/en/latest/) regenerates the alias. No Finder GUI scripting is used.

The content area is 660 by 400 points, with 96-point icons centered at (220, 270) and (440, 270), zero initial scroll and icon previews disabled. No filename underlays or extra notices are baked into the image. Finder itself owns the filename labels; its documented icon-view options offer size and position, not a hide-label toggle. The normal metadata retains 11-point labels until an actual Finder test establishes another behavior. Finder may retain the user's bar preferences despite the image's hidden-bar metadata; packaging does not change those preferences.

The image is mounted at a different temporary location after conversion to check the background alias, icon positions, Applications target and app signature again. A Finder inspection is still required to verify appearance.

`probe-hidden-labels.py` is an isolated diagnostic only. It sets `textSize` to zero on a cloned image under a guarded temporary mount. This is not a documented hide-label setting and does not establish that Finder will hide names. The normal packager never calls it. [Apple's Finder view guidance](https://support.apple.com/en-au/guide/mac-help/mchldaafb302/mac) documents filename hiding for Gallery view, while [Icon view guidance](https://support.apple.com/en-ca/guide/mac-help/mchlp2209/mac) describes label size and position.
