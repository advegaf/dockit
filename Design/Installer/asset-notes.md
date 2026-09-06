# installer artwork

`installer-art.png` is the full-canvas opaque artwork generated with the built-in image tool on 2026-09-06. It is an installer-only derivative. It does not replace the app icon.

The approved source was `Design/AppIcon.icon/Assets/approved-dockling.png`. The first cutout request produced baked checkerboard pixels instead of alpha and was rejected. A charcoal cutout had a visible rectangular boundary. The final full-canvas image removes that compositing boundary. Its inner tile glyphs are squircles rather than the original circle and diamond. The curl also differs slightly. Those differences remain subject to visual approval.

Final prompt:

> Create the full opaque background artwork for dockit's macOS DMG installer. Landscape exactly 3:2 aspect ratio, intended display 720 by 480 points. Use supplied icon as mascot reference; keep original face, two dark eyes and highlights, curl, warm off-white paws and straight frosted Dock shelf with central spacer notch. Remove large white squircle app icon base entirely. On the shelf show three soft pastel lavender, blue, peach app tiles, each a squircle, with simple smaller squircle glyphs (NO circles or diamonds). Background edge to edge is flat dark charcoal #1b1c20, quiet and uniform, no checkerboard, no white area, no outlined square behind mascot. Place the complete mascot and shelf as a small decorative illustration centered at x50%, y25%, occupying about 27% canvas width and 34% canvas height. Leave lower 55% of canvas ENTIRELY EMPTY charcoal for native installer icons and text to be composited later. No text, no letters, no arrow, no additional icons, no scene or particles. This must be the FULL 3:2 installer background, not a portrait cutout and not an app icon.

`background.png`, `background@2x.png` and `background.tiff` are deterministic outputs of `Tools/Release/InstallerBackground.swift`. Typography and arrow geometry come from that generator, not generated lettering. Mounted Finder verification remains separate from inspecting these images.
