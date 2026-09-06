# dockit design

dockit edits the real macOS Dock. It is not a replacement Dock.

The editor has no sidebar. Its native titlebar contains the profile picker at the upper right, with a colored squircle and paired chevrons. The body contains a white-backed identity badge, profile status, action controls, and a horizontal Dock preview.

Selection inspects a saved profile without activating it. Edits save to the selected profile. The explicit `apply` action changes the real Dock. The active badge moves only after verification. Menu and Focus activation leave the editor selection unchanged.

The initial editor content size is 620 by 260 points. Its minimum is 520 by 260. Long names remain complete, and action controls stack when needed. Details scroll independently below the fixed upper region. When that region cannot fit, the body scrolls with ordinary native controls.

Settings has one scrolling page with general, focus, data & privacy, and about sections. It has no sidebar or tabs. Its initial content size is 620 by 620 points, with a 520 by 480 minimum.

System fonts, SF Symbols, semantic control colors, and AppKit application icons form the interface. Profile color is a secondary identity cue paired with a name. The identity palette uses equal OKLCH lightness and hue-relative chroma within sRGB. Native menus, alerts, sheets, file panels, and keyboard commands take precedence over custom controls.

The fixed picker and edit menu use native Liquid Glass. The apply button uses prominent glass with the user's accent color and semantic selected-control text. Adjacent actions share a GlassEffectContainer. Scrolling rows and preview items do not use glass effects. The preview uses one restrained material shelf with full-size icons and distinct small and regular spacer slots. It does not imitate Dock magnification.

All dockit-authored interface text is lowercase. User-entered names, application names, filenames, paths, and system-owned dialogs retain their original casing. Profile names have a 32-grapheme limit. Command ellipses indicate a following dialog, not clipped content.

Animations communicate selection, editing and completion. Use native transitions and honor Reduce Motion. A Dock reload is a real system transition and must not be disguised as an instant custom animation.

Missing apps remain in profiles. Applying reports skipped apps. Destructive actions identify their scope. Deleting a profile does not alter the real Dock. The final profile cannot be deleted.

Focus configuration belongs to System Settings. dockit never invents an inventory of Focus names. A Focus filter selects one dockit profile. Focus ending leaves the Dock unchanged.

The feature workbook is the sole feature-status tracker. The decision trail records why a choice was made, without duplicating status.
