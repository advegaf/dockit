# Execution plan

1. Read the poteto-mode Principles section and the applicable leaf skills in full.
2. Apply the feature and autonomous-run playbooks. The how and architect investigations are complete from planning. Keep product choices fixed.
3. Prove real Dock switching and restoration before investing in the management interface.
4. Implement the explicit domain and persistence boundaries. Separate the workbook writer, Dock adapter and interface ownership.
5. Build the native interface in verifiable units. Inspect each user-visible state with screenshots and test its actual behavior.
6. Prove Focus operation, failure recovery and lifecycle behavior on this Mac.
7. Complete the first story sweep, log defects, fix causes and retest. Complete a second full sweep.
8. Restore the original Dock and remove test fixtures. Complete the authorized login lifecycle test with a recoverable handoff.
9. Sign and notarize after the release gates pass.

## Throughput checkpoint

1. Blocking first steps. The real Dock probe blocks UI implementation.
2. Independent workstreams. The workbook and Focus execution-target investigation proceed independently.
3. Shared mutable state. Root is the only writer to the live Dock during the feasibility test. Core files, interface files and the workbook have separate owners.
4. Smallest safe decomposition. Keep one owner for Dock transactions and one for the interface. Root reviews handoffs and runs the system checks.

The repository lives at github.com/advegaf/dockit and releases are cut from main with Tools/Release/release.sh and publish.sh. The approved architecture needs no second design competition.

## Skill routing

Use Claude Code sources for poteto-mode, ponytail, unslop, grill-me, autoplan, delegate, apple-design, design-consultation, ios-design-review, better-interface, better-ui, ui-skills, emil-design-eng, make-interfaces-feel-better, better-colors, find-animation-opportunities, animate, improve-animations, review-animations, design-review and ios-qa. Apply iOS review criteria to macOS and discard inapplicable simulator transport. Native SwiftUI and AppKit override web framework prescriptions.

The advisor skill is absent. Use the product and engineering reviews in autoplan and record that substitution. A skill read is not proof of a runtime review. Record executed reviews and their evidence in the workbook.

## Principles that shape implementation

Model the Domain gives profiles, items and transactions explicit types. Boundary Discipline places validation at file and system preference boundaries. Separate Before Serializing Shared State keeps the workbook independent while serializing live Dock writes. Prove It Works requires a real Dock probe, screenshots, recordings and a second behavioral sweep. Sequence Work into Verifiable Units keeps each stage tied to an observable result.
