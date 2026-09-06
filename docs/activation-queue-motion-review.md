# Activation queue motion review

## Verdict

Build 4 uses no explicit custom animations in the app source. Window presentation, sheets, progress indicators, and the macOS Dock transition are system-owned. This restraint fits a native utility and avoids decorative movement during frequent profile switches.

The recorded single activation passes the visible feedback and state-continuity review. Queue interruption timing and exact Reduce Motion transition behavior remain unverified, so the complete activation-queue motion gate stays open.

## Confirmed evidence

| Evidence | What it proves | Limit |
| --- | --- | --- |
| [`activation-queue-motion.mov`](../artifacts/ui/activation-queue-motion.mov) | A single activation shows prompt system progress indicators, keeps the old Dock marked active while work is pending, then changes the active label and checkmark only after completion. | It contains no second request during the first activation. It cannot prove queue ordering, interruption, or retargeting. |
| [`activation-queue-before.jpeg`](../artifacts/ui/activation-queue-before.jpeg), [`activation-queue-after.jpeg`](../artifacts/ui/activation-queue-after.jpeg), [`activation-queue-contact-sheet.jpg`](../artifacts/ui/activation-queue-contact-sheet.jpg) | The selected, applying, and completed states are legible and use native feedback. | Static frames and one-second samples cannot prove subsecond timing, easing, or interruption behavior. |
| [`final-build4-reduce-motion-light.jpeg`](../artifacts/ui/final-build4-reduce-motion-light.jpeg) | Build 4 remains visually coherent with Reduce Motion enabled. | It is a screenshot, so it does not show the transition or spinner behavior under that setting. |
| Current SwiftUI source | Activation uses standard `ProgressView` feedback and separates applying state from active state. The Dock preview and profile detail views animate selection and reordering with short system curves, and every one of those animations is gated on Reduce Motion. | AppKit and SwiftUI still own their normal system transitions. Source inspection does not replace a runtime recording. |

## Motion assessment

The existing movie shows feedback appearing shortly after activation begins. The previous active profile remains truthful throughout the pending period. Completion changes the active label, checkmark, editing controls, and status together. There is no custom spring, scale, bounce, or crossfade.

The several-second wait in the fixture is operation time, not an animation duration. The interface remains stable during that wait and does not claim success early.

The progress indicators are placed at the action and on the applying profile row. This makes the source and destination of the operation clear without moving content around the window.

## Open checks

1. Record one continuous run that starts an activation, requests a second profile before the first finishes, and keeps the sidebar, toolbar, status, and final active row visible. Verify that the last valid request wins and that progress never attaches to the wrong row.
2. Repeat the rapid-request recording with Reduce Motion enabled. Verify that state feedback remains clear and no transition depends on movement.
3. If release evidence must cover the real macOS Dock transition, record a real profile switch with the Dock visible from request through reload. The existing movie covers the dockit management UI only.

## Release position

No motion defect is visible in the evidence collected so far. The remaining issue is evidence coverage. Keep the queue-interruption and Reduce Motion motion stories unverified until the two continuous recordings exist.
