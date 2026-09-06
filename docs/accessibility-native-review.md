# Accessibility and native interaction review

## Verdict

Build 4 has a strong native accessibility baseline. The management window uses standard macOS controls, exposes a complete accessibility tree, and keeps the selected Dock separate from the active Dock in both words and symbols.

Runtime evidence now covers light and dark appearance, Increased Contrast, Reduced Transparency, Reduce Motion, a narrow window, and a VoiceOver-enabled launch. Exact VoiceOver spoken reading order, complete keyboard traversal, and the repaired login and reopen lifecycle still need independent runtime checks before release.

## Evidence standard

- Source-backed: the behavior follows directly from the current Swift or project configuration.
- Screenshot-backed: the named artifact visibly supports the finding.
- Runtime observed: the setting or lifecycle state was exercised on build 4.
- Still open: the available artifact cannot prove the behavior.

This review applies `apple-design`, `ios-design-review` adapted to macOS, `ios-qa`, `better-ui`, and `better-colors`.

## Build 4 results

| Area | Evidence | Result |
| --- | --- | --- |
| Native structure | `Sources/Dockit/ContentView.swift`, `Sources/Dockit/ProfileDetailView.swift`, `Sources/Dockit/SettingsView.swift`; `artifacts/ui/final-build4-management-dark.jpeg` | Pass. The app uses a native split view, sidebar and inset lists, unified toolbar, standard menus, buttons, sheets, settings, and system file panels. |
| Selected versus active | `artifacts/ui/final-build4-selected-vs-active-dark.jpeg`, `artifacts/ui/final-build4-selected-vs-active-light.jpeg` | Pass. Selection and the active Dock remain visibly different in both appearances. Active state uses text and a checkmark, so profile color is not the only cue. |
| Increased Contrast | `artifacts/ui/final-build4-increased-contrast-light.jpeg` | Pass for the captured management state. Selection, active state, text, and controls remain distinct. |
| Reduced Transparency | `artifacts/ui/final-build4-reduced-transparency-light.jpeg` | Pass for the captured management state. Footer and sidebar surfaces remain readable when the system reduces transparency. |
| Reduce Motion | `artifacts/ui/final-build4-reduce-motion-light.jpeg` | Pass for static state clarity. The interface remains coherent with Reduce Motion enabled. This screenshot does not prove transition timing. |
| Narrow window | `artifacts/ui/final-build4-narrow-dark.jpeg` | Pass at 701 by 532. The header, sidebar, toolbar, item list, and footer show no overlap or horizontal clipping. The exact 700 by 480 minimum was not captured. |
| VoiceOver tree | `artifacts/ui/final-build4-voiceover-active.jpeg`; live accessibility inspection | Partial pass. VoiceOver was running and dockit exposed its management window, sidebar, profile states, Dock name field, color value, pinned-item list, paths, toolbar controls, and edit controls. Text to speech activity was observed after dockit became active. The exact spoken order and every announced trait were not observed. |
| Control labels | `Sources/Dockit/ContentView.swift`, `Sources/Dockit/ProfileDetailView.swift`, `Sources/Dockit/ImportProfilesView.swift`, `Sources/Dockit/MissingAppsView.swift`, `Sources/Dockit/ReconciliationView.swift` | Pass in source and accessibility-tree inspection. Icon-only actions have names, decorative images are hidden, profile rows include active or switching state, and unavailable apps expose text as well as color. |
| Destructive actions | `Sources/Dockit/ContentView.swift`, `Sources/Dockit/ReconciliationView.swift`; `artifacts/ui/delete-active-warning.jpeg` | Pass. Destructive actions explain what changes, preserve the real Dock when deleting a profile, and protect the final profile. Recovery choices cannot be dismissed while unresolved. |
| Lifecycle source | `Sources/Dockit/DockMenuCoordinator.swift`, `Sources/Dockit/DockitApp.swift` | Fixed in source. Startup connects the shared model before a view appears, reopen reuses an existing management window, a fallback window is available, and quit waits for model flushing. Independent login-launch and reopen testing is still open. |

## Open release checks

| Priority | Check | Expected result |
| --- | --- | --- |
| High | VoiceOver reading order | Traverse the sidebar, detail view, footer, Settings, deletion warning, unavailable-app sheet, import sheet, and recovery sheet. Each control is spoken once in a useful order. Profile selection and active state are announced separately. |
| High | Full Keyboard Access | Reach every enabled control without a pointer. Arrow keys may change selection without switching the real Dock. Return and Space activate only the focused control. Escape closes every cancellable sheet. Focus rings remain visible. |
| High | Login launch and reopen | With the menu bar item disabled, launch at login without showing the management window. One Dock click must open exactly one usable window. Errors and recovery must open that same window and present their sheet. Closing and reopening must not create duplicates. |
| Medium | Exact minimum size | Resize to 700 by 480 and repeat populated, empty, applying, and two-line status states. No content may overlap or become unreachable. |
| Medium | Accessibility settings across sheets | Repeat unavailable-app, deletion, import, and recovery flows in light and dark appearance with Increased Contrast and Reduced Transparency. All text and focus indicators must remain clear. |
| Medium | Long content | Use a maximum-length profile name, long app paths, and several unavailable apps. Text should truncate predictably while primary actions remain reachable. |

## Release position

The captured build 4 management UI meets the native visual and structural bar. Do not mark the accessibility or lifecycle stories fully verified until the open VoiceOver, keyboard, and login lifecycle checks have recorded results.
