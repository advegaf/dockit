import fs from "node:fs/promises";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { FileBlob, SpreadsheetFile, Workbook } from "@oai/artifact-tool";

const repoRoot = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
const workbookPath = path.join(repoRoot, "docs", "dockit-feature-ledger.xlsx");
const renderDir = path.join(repoRoot, "artifacts", "ledger");

const palette = {
  navy: "#16324F",
  blue: "#2563EB",
  blueLight: "#EAF2FF",
  slate: "#475569",
  slateLight: "#F5F7FA",
  line: "#D7DEE7",
  green: "#166534",
  greenLight: "#DCFCE7",
  amber: "#92400E",
  amberLight: "#FEF3C7",
  red: "#991B1B",
  redLight: "#FEE2E2",
  white: "#FFFFFF",
};

const deliveryValues = [
  "Proposed",
  "Ready to build",
  "Building",
  "Ready for test",
  "Testing",
  "Failed",
  "Fixing",
  "Ready for retest",
  "Verified",
  "Blocked",
  "Deferred",
];

const verdictValues = ["Not run", "Pass", "Fail", "Blocked", "Not applicable"];
const unresolvedDefectStatuses = new Set(["Open", "Fixing", "Fixed", "Deferred"]);
const completedReviewValues = new Set(["Pass", "Not applicable"]);
const formulaErrorPattern = "^(?:#NULL!|#DIV/0!|#VALUE!|#REF!|#NAME\\?|#NUM!|#N/A|#SPILL!|#CALC!|#FIELD!|#DATA!|#CONNECT!|#BLOCKED!|#UNKNOWN!|#GETTING_DATA|#ERROR!)$";
const visibleProductPattern = /(?<![\p{L}\p{N}_./\\])Dockit(?![\p{L}\p{N}_./\\])/gu;
const executionDecisionAuditTitle = "Execution decision audit";

const visibleProductProseRanges = [
  ["Stories", ["A1:A3", "D7:F300", "T7:T300"]],
  ["Test runs", ["A1:A3", "D6:H300", "S6:S300"]],
  ["Defects", ["A1:A3", "F6:J300", "R6:R300"]],
  ["Decisions", ["A1:A3", "C6:C300", "E6:E300"]],
  ["Evidence", ["A1:A3", "G6:G300", "I6:J300", "L6:L300"]],
];

function normalizeVisibleProductText(value) {
  if (typeof value !== "string" || !value.includes("Dockit")) return value;
  return value
    .split(/(`[^`]*`)/g)
    .map((segment, index) => (index % 2 === 1 ? segment : segment.replace(visibleProductPattern, "dockit")))
    .join("");
}

function normalizeVisibleProductProse(workbook) {
  let changed = 0;
  for (const [sheetName, ranges] of visibleProductProseRanges) {
    const sheet = workbook.worksheets.getItem(sheetName);
    for (const address of ranges) {
      const range = sheet.getRange(address);
      const values = range.values;
      const normalized = values.map((row) => row.map((value) => {
        const next = normalizeVisibleProductText(value);
        if (next !== value) changed += 1;
        return next;
      }));
      range.values = normalized;
    }
  }
  return changed;
}

const stories = [
  ["PLT-001", "Platform", "Settled", "As a Mac user, I can tell whether Dockit supports my Mac.", "Dockit runs on macOS 26 or later. Unsupported systems cannot install or launch the build.", "Build with a macOS 26 deployment target. Confirm the app launches on macOS 26 and the binary declares the same minimum version.", "", "Not run"],
  ["PRV-001", "Privacy", "Explicit", "As a user, my Dock profiles remain on my Mac.", "Profiles persist only in local application storage.", "Create profiles, inspect storage, disable networking, relaunch, and confirm the profiles remain available.", "", "Not run"],
  ["PRV-002", "Privacy", "Explicit", "As a user, I can use Dockit without an account.", "No sign-in, registration, identity, or account recovery path exists.", "Exercise first launch and all profile actions without credentials.", "", "Not run"],
  ["PRV-003", "Privacy", "Explicit", "As a user, my profiles do not sync through a service.", "Dockit has no cloud synchronization path.", "Inspect settings and network activity while creating, editing, and switching profiles.", "", "Not run"],
  ["PRV-004", "Privacy", "Explicit", "As a user, I am not tracked.", "Dockit emits no analytics or telemetry.", "Monitor network and local logs during an end-to-end session. Record no analytics destination or event payload.", "", "Not run"],
  ["PRF-001", "Profiles", "Settled", "As a user, I can create a Dock from my current Dock.", "The create flow offers Capture current Dock and stores the current pinned apps and spacers as a new profile.", "Create from a fixture Dock. Switch away and back. Confirm app order and spacer layout match the captured baseline.", "", "Not run"],
  ["PRF-002", "Profiles", "Settled", "As a user, I can create an empty Dock.", "The create flow offers Empty Dock and creates a profile with no pinned apps or spacers.", "Create an empty profile, activate it, and confirm folders, recents, settings, and running apps remain untouched.", "", "Not run"],
  ["PRF-003", "Profiles", "Explicit", "As a user, I can name a Dock profile.", "A profile name is visible in every selection and management surface and persists after relaunch.", "Create, rename, quit, relaunch, and confirm the same name in each surface.", "", "Not run"],
  ["PRF-004", "Profiles", "Explicit", "As a user, I can color a Dock profile.", "A selected profile color is visible where profiles are distinguished and persists after relaunch.", "Change color, relaunch, and inspect each profile surface in light and dark appearance.", "", "Not run"],
  ["PRF-005", "Profiles", "Explicit", "As a user, I can create as many Dock profiles as I need.", "Dockit imposes no product-level profile count limit.", "Create a representative multi-profile set and confirm each remains selectable and persists after relaunch.", "", "Not run"],
  ["PRF-006", "Profiles", "Settled", "As a user, I can duplicate a Dock profile.", "Duplicate creates a new independently editable profile with the same name basis, color, apps, spacer sequence, and Focus association policy defined by the product.", "Duplicate a populated profile, edit the duplicate, and confirm the source profile remains unchanged.", "DEC-02", "Not run"],
  ["PRF-007", "Profiles", "Settled", "As a user, I can delete a profile I no longer need.", "Deleting a non-final profile requires confirmation and does not change the actual Dock unless the user chooses another profile.", "Delete an inactive and an active non-final profile. Confirm the stored set changes only as approved and the current Dock remains known.", "DEC-03", "Not run"],
  ["PRF-008", "Profiles", "Settled", "As a user, I cannot delete my final remaining profile by accident.", "The deletion command is unavailable or explains why when only one profile remains.", "Reduce to one profile and attempt deletion through every available entry point.", "DEC-03", "Not run"],
  ["PRF-009", "Profiles", "Safety guardrail", "As a user, I can see which profile is selected and which one is active.", "Selection is a management choice. Active means Dockit has successfully reconciled the actual Dock to that profile. The UI never presents them as the same when they differ.", "Select a profile without applying it where supported, force an apply failure, and confirm the selected and active indicators remain truthful.", "DEC-04", "Not run"],
  ["PRF-010", "Profiles", "Explicit", "As a user, I can switch to a saved Dock in one action.", "A switch request applies the selected profile without a second setup flow or hidden destructive confirmation.", "Activate two fixture profiles through each supported menu path and time the interaction.", "", "Not run"],
  ["PRF-011", "Profiles", "Explicit", "As a user, switching profiles restores pinned app order.", "The actual Dock's pinned-app sequence matches the saved order for the activated profile.", "Apply two profiles with distinct app sequences and compare the Dock to saved expected order.", "", "Not run"],
  ["PRF-012", "Profiles", "Explicit", "As a user, switching profiles restores spacers.", "Spacer count, kind, and position match the activated profile.", "Apply two profiles with distinct spacer layouts and compare actual Dock separator positions.", "", "Not run"],
  ["PRF-013", "Profiles", "Explicit", "As a user, my folders survive a profile switch.", "Dockit does not alter the Dock's folder section.", "Configure folders before switching. Compare folder entries before and after both manual and Focus switches.", "", "Not run"],
  ["PRF-014", "Profiles", "Explicit", "As a user, my recent-apps behavior survives a profile switch.", "Dockit does not change the recent-apps setting or manage dynamic recent apps.", "Enable recent apps, switch profiles, and confirm the setting and dynamic items retain macOS behavior.", "", "Not run"],
  ["PRF-015", "Profiles", "Explicit", "As a user, my unrelated Dock preferences survive a profile switch.", "Position, size, magnification, hiding, animation, and other non-profile preferences stay unchanged.", "Use non-default Dock preferences, switch profiles, and compare each setting before and after.", "", "Not run"],
  ["PRF-016", "Profiles", "Explicit", "As a user, switching a profile never opens or quits apps.", "The set of running processes is unchanged by any profile switch.", "Record running apps, perform manual and Focus switches, and verify each process remains running.", "", "Not run"],
  ["PRF-017", "Profiles", "Explicit", "As a user, apps I already have open remain in the Dock until I quit them.", "An unpinned running app retains normal macOS Dock visibility after a profile switch and disappears only through normal macOS quit behavior.", "Run an app absent from the destination profile, switch, then quit it. Confirm visibility before and after the quit.", "", "Not run"],
  ["PRF-018", "Editing", "Explicit", "As a user, adding a pinned app to the active Dock saves the edit.", "A direct macOS Dock add updates only the active profile and survives switching away and back.", "Pin a fixture app directly in the Dock. Switch to another profile and return.", "", "Not run"],
  ["PRF-019", "Editing", "Explicit", "As a user, removing a pinned app from the active Dock saves the edit.", "A direct macOS Dock removal updates only the active profile and survives switching away and back.", "Remove a pinned fixture app directly, switch away, and return.", "", "Not run"],
  ["PRF-020", "Editing", "Explicit", "As a user, reordering pinned apps in the active Dock saves the edit.", "A direct macOS Dock reorder persists as the active profile's ordered app sequence.", "Reorder two fixture apps, switch away and back, and compare ordering.", "", "Not run"],
  ["PRF-021", "Editing", "Explicit", "As a user, adding a spacer to the active Dock saves the edit.", "A spacer addition persists as part of the active profile.", "Add a spacer using Dockit's supported path, switch away and back, and compare its position.", "", "Not run"],
  ["PRF-022", "Editing", "Explicit", "As a user, removing or moving a spacer in the active Dock saves the edit.", "Spacer removal or movement persists as part of the active profile.", "Remove and move fixture spacers, switch away and back, and compare positions.", "", "Not run"],
  ["PRF-023", "Editing", "Settled", "As a user, I can populate a profile while keeping the real Dock as the editor.", "The profile becomes active before direct Dock edits define it. Dockit offers a native command for spacer insertion without building a fake Dock editor.", "Create a profile, activate it, add apps through macOS and a spacer through Dockit, and confirm the stored profile.", "DEC-01", "Not run"],
  ["PRF-024", "Reconciliation", "Safety guardrail", "As a user, edits to the active Dock never overwrite an inactive profile.", "Direct Dock changes reconcile only into the active profile.", "Edit the active profile, inspect every inactive profile, then switch among them.", "", "Not run"],
  ["PRF-025", "Reconciliation", "Safety guardrail", "As a user, Dockit's own switch does not get saved as a partial manual edit.", "An apply operation converges to the intended profile without intermediate autosave corruption.", "Rapidly switch distinct profiles and inspect each stored item sequence afterward.", "", "Not run"],
  ["PRF-026", "Reconciliation", "Settled", "As a user, Dock edits made while Dockit is closed reconcile on reopening.", "On reopening, Dockit compares the actual pinned-app and spacer sequence to the recorded active profile, records a clear reconciliation outcome, and never silently overwrites another profile.", "Quit Dockit, edit the Dock, reopen Dockit, inspect the reconciliation UI, then switch away and back.", "DEC-06", "Not run"],
  ["PRF-027", "Persistence", "Explicit", "As a user, my saved Dock profiles remain after quitting and reopening Dockit.", "Names, colors, app order, spacers, and active metadata reload correctly.", "Create and edit profiles, quit Dockit, relaunch, and compare every saved field.", "", "Not run"],
  ["MEN-001", "Menus", "Settled", "As a user, I can switch Docks from a native app menu.", "The primary menu lists profiles, shows active state, supports keyboard navigation, and performs the same safe apply path as the main window.", "Use every menu entry with mouse and keyboard. Compare menu result to direct selection.", "DEC-05", "Not run"],
  ["MEN-002", "Menus", "Settled", "As a user, I can manage profiles from native menus without losing context.", "Create, duplicate, rename, color, export, import, and delete actions are grouped in clear native menu or contextual-menu paths.", "Exercise each command and inspect labels, enabled state, confirmation, and cancellation behavior.", "DEC-05", "Not run"],
  ["MEN-003", "Menus", "Settled", "As a user, I can choose whether Dockit appears in the menu bar.", "Menu-bar presence is optional, uses a native status-item interaction, and turning it off does not delete profiles or disable the main app.", "Enable and disable menu-bar presence, relaunch, and confirm profile data and main-window access persist.", "DEC-05", "Not run"],
  ["MEN-004", "Native UX", "User constraint", "As a keyboard or VoiceOver user, I can operate all Dockit controls.", "Controls expose native labels, focus order, keyboard actions, and VoiceOver semantics.", "Run keyboard-only and VoiceOver passes across profile, menu, Focus, import, and recovery flows.", "", "Not run"],
  ["MEN-005", "Native UX", "User constraint", "As a user, Dockit feels like a Mac app rather than a themed Dock clone.", "Dockit uses standard macOS controls and leaves the real macOS Dock as the visual result.", "Review light and dark mode screenshots and recordings against native macOS interaction expectations.", "", "Not run"],
  ["MEN-006", "Native UX", "User constraint", "As a user, Dockit respects system accessibility appearance and motion preferences.", "Text, contrast, focus, Reduce Motion, and system appearance remain usable. Dockit does not introduce custom Dock physics.", "Test light, dark, increased contrast, and Reduce Motion states with screenshots and recordings.", "", "Not run"],
  ["FOC-001", "Focus", "Explicit", "As a user, I can attach a Dock profile to a Focus Mode.", "A profile can show and persist its allowed Focus association.", "Attach an available Focus, relaunch, and confirm the association remains intact.", "", "Not run"],
  ["FOC-002", "Focus", "Settled", "As a user, I can change or remove a Focus association.", "Reassignment and unlinking persist without changing the actual Dock until a Focus activation event occurs.", "Attach, reassign, unlink, relaunch, and confirm the Dock remains unchanged absent an event.", "", "Not run"],
  ["FOC-003", "Focus", "Explicit", "As a user, turning on an attached Focus switches to its Dock.", "An eligible Focus activation uses the same apply path as a manual switch.", "Turn on a mapped real Focus. Confirm active profile, Dock app order, spacers, and no app lifecycle effects.", "", "Not run"],
  ["FOC-004", "Focus", "Settled", "As a user, I get predictable behavior when a Focus ends.", "When a mapped Focus ends, Dockit retains the currently active Dock until a later manual or Focus activation event.", "Activate a mapped Focus, then end it. Confirm no unsolicited profile switch occurs.", "DEC-07", "Not run"],
  ["FOC-005", "Focus", "Settled", "As a user, a manual Dock choice remains understandable during Focus automation.", "The UI explains whether the active Dock came from a manual or Focus event. A later Focus activation may apply its mapped Dock.", "Manually switch during an active Focus, inspect attribution, then toggle another mapped Focus.", "DEC-07", "Not run"],
  ["FOC-006", "Focus", "Settled", "As a user, I know when Focus automation is unavailable.", "When the required Focus capability, entitlement, authorization, or operating-system support is absent, Dockit disables the binding action and explains the manual alternative.", "Deny or remove the required capability and inspect controls, error copy, and unchanged Dock behavior.", "DEC-08", "Not run"],
  ["FOC-007", "Focus", "Settled", "As a user, Focus automation can run after login when I enable it.", "Dockit offers an explicit login-item choice. When enabled, the app can observe mapped Focus changes after sign-in without showing an intrusive window.", "Enable launch at login in a test account, sign out and in, activate a mapped Focus, and confirm the expected Dock applies.", "DEC-09", "Not run"],
  ["FOC-008", "Focus", "Safety guardrail", "As a user, a Focus-triggered switch preserves the same non-profile Dock state as a manual switch.", "Folders, recents, settings, and running apps remain untouched during Focus automation.", "Run the same preservation fixture through a Focus-triggered switch.", "", "Not run"],
  ["XFR-001", "Transfer", "Explicit", "As a user, I can export saved Docks to move them manually.", "Export writes a local portable file for the selected profile set.", "Export one and multiple fixture profiles. Inspect the file and import it into an isolated local fixture.", "", "Not run"],
  ["XFR-002", "Transfer", "Explicit", "As a user, export contains only profile data.", "Exports include names, colors, app references, and spacer layout. They exclude folders, recents, other Dock settings, windows, running-app state, accounts, and analytics.", "Compare exported structure with a fixture that has non-default unrelated Dock state.", "", "Not run"],
  ["XFR-003", "Transfer", "Explicit", "As a user, I can import a valid Dockit export.", "A valid local file creates usable local profiles with saved name, color, ordering, and spacers.", "Import a known fixture and activate each imported profile.", "", "Not run"],
  ["XFR-004", "Transfer", "Safety guardrail", "As a user, a malformed import cannot damage my current setup.", "Invalid, corrupt, or unsupported import data changes neither saved profiles nor the actual Dock.", "Attempt malformed and unsupported imports. Compare profiles and actual Dock before and after.", "", "Not run"],
  ["XFR-005", "Transfer", "Settled", "As a user, I can resolve an import name conflict deliberately.", "Import previews profile-name collisions and creates a renamed copy by default unless the user explicitly chooses another supported resolution.", "Import a profile with an existing name. Confirm preview, cancellation, default result, and source profile preservation.", "DEC-10", "Not run"],
  ["XFR-006", "Transfer", "Settled", "As a user, I can handle an app that is missing on another Mac.", "Dockit retains an unavailable app reference, visibly marks it, and requires an explicit skip or relink decision before a partial apply.", "Import a fixture with an unavailable app. Confirm it is not silently dropped and the Dock remains unchanged until the user chooses.", "DEC-11", "Not run"],
  ["REL-001", "Recovery", "Settled", "As a user, a failed Dock update does not leave me in an unknown state.", "Dockit records the failed apply, restores or preserves the prior known state where possible, and presents a clear retry or recovery path.", "Inject an apply failure. Confirm active status, saved profiles, actual Dock, error visibility, and retry behavior.", "DEC-12", "Not run"],
  ["REL-002", "Recovery", "Settled", "As a user, I can recover after Dockit quits or the system interrupts an update.", "On next launch, Dockit detects an incomplete operation, reconciles the actual Dock, and gives the user a safe outcome rather than assuming success.", "Interrupt an update in a test environment, relaunch, and inspect reconciliation and recovery choices.", "DEC-12", "Not run"],
  ["REL-003", "Recovery", "Native-quality constraint", "As a user, I receive restrained native feedback after a manual or automatic switch.", "Dockit confirms success without unnecessary modal interruption and explains failures in context.", "Review successful and failed switch feedback in each entry point with screenshots and VoiceOver.", "", "Not run"],
  ["REL-004", "Release", "Settled", "As a user, I can install a trusted Dockit build.", "Release artifacts are signed, notarized, and present expected macOS trust behavior before distribution.", "Build a release candidate, verify signature and notarization, and install on a clean test account.", "DEC-13", "Not run"],
  ["REL-005", "Release", "Settled", "As a user, I can understand a blocked permission or unsupported integration.", "Dockit presents an actionable native explanation, does not claim success, and keeps the current Dock intact.", "Deny every required capability and inspect recovery paths and actual Dock preservation.", "DEC-08", "Not run"],
  ["BRD-001", "Brand", "User constraint", "As a user, I see the product name written as dockit everywhere.", "Every user-visible product name, bundle label, menu item, alert, Focus surface, and release artifact uses lowercase dockit. The generic macOS Dock name remains capitalized.", "Inspect every app surface, Finder bundle name, Focus filter, accessibility label, and packaged artifact. Search built resources for visible uppercase product copy.", "DEC-13", "Not run"],
  ["PRF-028", "Profiles", "User constraint", "As a user, I can understand a saved Dock before activating it.", "The selected profile shows an exact-order horizontal preview of apps and spacers without changing the active Dock.", "Select inactive and active profiles with mixed app and spacer layouts. Compare the preview order, state labels, accessibility descriptions, and actual Dock behavior.", "DEC-04", "Not run"],
  ["PRF-029", "Profiles", "User constraint", "As a user, I can enter a readable profile name without hidden shortening.", "Profile names accept at most 32 grapheme clusters. Interactive input rejects additional characters and imports report overlength names without silently changing them.", "Test empty, 32-character, 33-character, composed Unicode, rename, create, duplicate, archive validation, and import paths.", "", "Not run"],
  ["SET-001", "Settings", "User constraint", "As a user, I can navigate dockit's settings like a native Mac app.", "A resizable Settings window provides persistent General, Focus, Data & Privacy, and About destinations with independent detail scrolling and standard controls.", "Open each destination at default and minimum size, relaunch Settings, and verify selection persistence, keyboard access, scrolling, labels, and appearance.", "", "Not run"],
  ["SET-002", "Settings", "Explicit", "As a user, I can control launch and menu bar behavior from General settings.", "Launch at login and menu bar controls reflect real state, report required approval, and provide a working System Settings action.", "Toggle each setting, handle approval-required state, relaunch, and verify persisted behavior.", "DEC-05, DEC-09", "Not run"],
  ["SET-003", "Settings", "Explicit", "As a user, I can understand and configure Focus readiness.", "Focus settings report current availability, explain login readiness, and open the correct System Settings destination.", "Exercise available and unavailable states, activate the action, and confirm manual switching remains available.", "DEC-08, DEC-09", "Not run"],
  ["SET-004", "Settings", "Explicit", "As a user, I can review local data handling and app identity.", "Data & Privacy provides working import and export actions. About shows the app icon, lowercase name, version, build, platform requirement, distribution, and local-only statement.", "Exercise import and export from Settings, then compare About values with the built bundle and privacy architecture.", "", "Not run"],
  ["MEN-007", "Menus", "User constraint", "As a user, I can switch Docks from a useful menu bar item immediately after setup.", "The menu bar item is visible by default, uses a monochrome dockling template, lists colored profiles with truthful active state, and provides Manage Docks, Settings, and Quit in native order.", "Test first run, explicit opt-out, relaunch, light and dark appearance, keyboard use, switching success, switching failure, and every menu action.", "DEC-05", "Not run"],
  ["UX-001", "Native UX", "User constraint", "As a user, I can read all user-controlled text without overflow dots.", "Names, app labels, filenames, paths, statuses, and errors wrap, scroll, or use adaptive layout. No automatic truncation hides their content.", "Test a 32-wide-character name, long app name, deep path, long filename, long error, large text, and minimum window widths across every sheet and window.", "", "Not run"],
  ["UX-002", "Native UX", "User constraint", "As a user, I can recognize dockit from a distinctive native icon.", "The app uses an original dockling icon with reviewed macOS raster sizes. The menu bar uses a separate pixel-aligned monochrome template derived from its silhouette.", "Inspect 16 through 1024 pixel app assets in light and dark contexts. Inspect the menu template at 16 and 18 points in light, dark, and Increased Contrast.", "", "Not run"],
  ["MOT-001", "Motion", "Release gate", "As a user, I experience the shortest reliable system interruption when switching Docks.", "Dockit skips equivalent layouts, serializes and coalesces requests, restarts the Dock once, verifies the result, and selects only a benchmarked restart strategy that preserves reliability.", "Back up the real Dock. Run 20 alternating switches per restart strategy, measure blackout median and p95, verify every preservation invariant, then restore the backup.", "DEC-12", "Not run"],
];

const decisions = [
  ["DEC-01", "Product decision", "New profile source", "Settled", "Offer Capture current Dock and Empty Dock. Keep the real Dock as the primary editor.", "PRF-001, PRF-002, PRF-023"],
  ["DEC-02", "Product decision", "Duplicate profile", "Settled", "Duplicate a profile as an independent profile. Define whether Focus association copies before release.", "PRF-006"],
  ["DEC-03", "Product decision", "Deletion and final profile guard", "Settled", "Confirm deletion. Do not delete the final remaining profile. Deleting a profile does not change the actual Dock alone.", "PRF-007, PRF-008"],
  ["DEC-04", "Product decision", "Selection versus active", "Settled", "Selection is a pending management choice. Active means the actual Dock has reconciled successfully.", "PRF-009"],
  ["DEC-05", "Product decision", "Menus and menu bar", "Settled", "Use native menu paths. Provide menu-bar presence as an optional user-controlled status item.", "MEN-001, MEN-002, MEN-003"],
  ["DEC-06", "Product decision", "Closed-change reconciliation", "Settled", "On reopen, compare the actual Dock to the active profile, report the result, and do not overwrite inactive profiles.", "PRF-026"],
  ["DEC-07", "Product decision", "Focus precedence", "Settled", "Apply when Focus turns on. Retain the active Dock when it turns off. Explain manual switches during Focus automation.", "FOC-004, FOC-005"],
  ["DEC-08", "Product decision", "Focus capability gates", "Settled", "Disable unsupported or unauthorized Focus binding. Explain the manual path and preserve the Dock.", "FOC-006, REL-005"],
  ["DEC-09", "Product decision", "Login item", "Settled", "Offer launch at login as an explicit choice for Focus automation after sign-in.", "FOC-007"],
  ["DEC-10", "Product decision", "Import collision", "Settled", "Preview collisions and create a renamed copy by default.", "XFR-005"],
  ["DEC-11", "Product decision", "Missing imported apps", "Settled", "Retain and visibly mark unavailable references. Require explicit skip or relink before a partial apply.", "XFR-006"],
  ["DEC-12", "Product decision", "Recovery", "Settled", "Detect incomplete work, reconcile actual Dock state, and provide a safe recovery path.", "REL-001, REL-002"],
  ["DEC-13", "Release decision", "Signing and notarization", "Settled", "Sign and notarize release artifacts before distribution testing.", "REL-004"],
];

const routes = [
  ["animate", "Requested", "Animation exploration", "Pending runtime review", "Use after the first switchable UI exists.", "/Users/advegaf/.agents/skills/animate/SKILL.md"],
  ["better-interface", "Requested", "Interaction and information architecture", "Pending design review", "Use before management surfaces are finalized.", "/Users/advegaf/.agents/skills/better-interface/SKILL.md"],
  ["emil-design-eng", "Requested twice", "Design implementation review", "Pending runtime review", "One route covers both duplicate invocations.", "/Users/advegaf/.agents/skills/emil-design-eng/SKILL.md"],
  ["apple-design", "Requested", "macOS-native design guidance", "Pending design review", "Apply to the first native surface.", "/Users/advegaf/.agents/skills/apple-design/SKILL.md"],
  ["improve-animations", "Requested", "Motion refinement", "Pending runtime review", "Use after motion evidence exists.", "/Users/advegaf/.agents/skills/improve-animations/SKILL.md"],
  ["review-animations", "Requested", "Motion review", "Pending runtime review", "Use recordings, not screenshots alone.", "/Users/advegaf/.claude/skills/review-animations/SKILL.md"],
  ["find-animation-opportunities", "Requested", "Motion opportunity scan", "Pending design review", "Use after the initial UI flow exists.", "/Users/advegaf/.agents/skills/find-animation-opportunities/SKILL.md"],
  ["grill-me", "Requested", "Requirement challenge", "Pending plan review", "Use before shipping irreversible UX choices.", "/Users/advegaf/.codex/skills/grill-me/SKILL.md"],
  ["autoplan", "Requested", "Implementation planning", "Pending plan review", "Use for scoped delivery planning.", "/Users/advegaf/.claude/skills/gstack/autoplan/SKILL.md"],
  ["make-interfaces-feel-better", "Requested", "Interaction polish", "Pending runtime review", "Use after the first live UI pass.", "/Users/advegaf/.agents/skills/make-interfaces-feel-better/SKILL.md"],
  ["delegate", "Requested", "Subtask delegation", "Active route", "Use for bounded independent work.", "/Users/advegaf/.claude/skills/delegate/SKILL.md"],
  ["ios-design-review", "Requested", "Platform review", "Pending applicability review", "Reassess for macOS before invocation.", "/Users/advegaf/.claude/skills/gstack/ios-design-review/SKILL.md"],
  ["design-consultation", "Requested", "Design consultation", "Pending design review", "Use when a material product choice remains.", "/Users/advegaf/.claude/skills/gstack/design-consultation/SKILL.md"],
  ["design-review", "Requested", "Design review", "Pending runtime review", "Use after a renderable native UI exists.", "/Users/advegaf/.claude/skills/gstack/design-review/SKILL.md"],
  ["ui-skills", "Requested", "UI implementation guidance", "Pending runtime review", "Use for the live app surface.", "/Users/advegaf/.claude/skills/ui-skills/SKILL.md"],
  ["better-ui", "Requested", "UI quality review", "Pending runtime review", "Use after the first end-to-end flow exists.", "/Users/advegaf/.agents/skills/better-ui/SKILL.md"],
  ["ios-qa", "Requested", "Runtime QA", "Pending applicability review", "Reassess for macOS before invocation.", "/Users/advegaf/.claude/skills/gstack/ios-qa/SKILL.md"],
  ["better-colors", "Requested", "Color review", "Pending design review", "Use when profile colors and states are visible.", "/Users/advegaf/.agents/skills/better-colors/SKILL.md"],
  ["advisor", "Requested", "Advisor route", "Missing", "No matching local Claude skill or command was found.", "Missing"],
  ["unslop", "Requested", "Writing quality", "Active route", "Apply to user-facing copy, docs, and error text.", "/Users/advegaf/.claude/skills/unslop/SKILL.md"],
  ["poteto-mode", "Requested", "Agent operating mode", "Active route", "Applies across this session.", "/Users/advegaf/.agents/skills/poteto-mode/SKILL.md"],
  ["ponytail", "Requested", "Agent quality route", "Pending applicability review", "Invoke only when its instructions fit the active work.", "/Users/advegaf/.claude/plugins/cache/ponytail/ponytail/4.9.0/skills/ponytail/SKILL.md"],
  ["imagegen", "Requested", "Original app icon generation", "Executed, asset review active", "Generated two independent dockling concepts. The second concept was selected after the first visual review.", "/Users/advegaf/.codex/skills/.system/imagegen/SKILL.md"],
];

decisions.find(([id]) => id === "DEC-02")[4] =
  "Duplicate a profile as an independent profile. Focus filter setup stays in System Settings and does not copy.";

const ponytailRoute = routes.find(([name]) => name === "ponytail");
ponytailRoute[2] = "Native and standard-library implementation";
ponytailRoute[3] = "Active route";
ponytailRoute[4] = "Use native APIs and no runtime dependencies.";

const focusSetupStory = stories.find(([id]) => id === "FOC-001");
focusSetupStory[3] = "As a user, I can select a Dock profile for a Focus filter in System Settings.";
focusSetupStory[4] = "Dockit's Focus filter offers the current profile list and stores one stable profile identifier per filter configuration.";
focusSetupStory[5] = "Configure a temporary Focus filter in System Settings, relaunch Dockit, and confirm activation resolves the same profile.";

const focusCapabilityStory = stories.find(([id]) => id === "FOC-006");
focusCapabilityStory[4] = "If live Focus switching is unreliable, Dockit explains that Focus automation is unavailable and leaves manual switching usable.";
focusCapabilityStory[5] = "Exercise the supported and unavailable Focus paths. Inspect the explanation and confirm manual switching remains intact.";

const missingAppStory = stories.find(([id]) => id === "XFR-006");
missingAppStory[4] = "Dockit retains and marks an unavailable app reference. Before a partial apply, the user must relink it, cancel, or explicitly skip it for that switch.";
missingAppStory[5] = "Import a fixture with one unavailable app. Confirm the Dock remains unchanged until the user relinks the app or chooses Skip and Apply.";

function colName(index) {
  let value = index + 1;
  let result = "";
  while (value > 0) {
    const remainder = (value - 1) % 26;
    result = String.fromCharCode(65 + remainder) + result;
    value = Math.floor((value - 1) / 26);
  }
  return result;
}

function parseArgs(argv) {
  const args = {};
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (!token.startsWith("--")) continue;
    const key = token.slice(2);
    const next = argv[index + 1];
    if (!next || next.startsWith("--")) {
      args[key] = true;
    } else {
      args[key] = next;
      index += 1;
    }
  }
  return args;
}

function setTitle(sheet, lastColumn, title, subtitle) {
  sheet.getRange(`A1:${lastColumn}1`).merge();
  sheet.getRange("A1").values = [[title]];
  sheet.getRange(`A1:${lastColumn}1`).format = {
    fill: palette.navy,
    font: { bold: true, color: palette.white, size: 16 },
    horizontalAlignment: "left",
    verticalAlignment: "center",
  };
  sheet.getRange(`A1:${lastColumn}1`).format.rowHeight = 28;
  sheet.getRange(`A3:${lastColumn}3`).merge();
  sheet.getRange("A3").values = [[subtitle]];
  sheet.getRange(`A3:${lastColumn}3`).format = {
    fill: palette.slateLight,
    font: { color: palette.slate, italic: true, size: 10 },
    verticalAlignment: "center",
  };
  sheet.getRange(`A3:${lastColumn}3`).format.rowHeight = 28;
}

function setHeader(sheet, range) {
  sheet.getRange(range).format = {
    fill: palette.blue,
    font: { bold: true, color: palette.white, size: 10 },
    horizontalAlignment: "center",
    verticalAlignment: "center",
    wrapText: true,
    borders: { preset: "outside", style: "thin", color: palette.blue },
  };
  sheet.getRange(range).format.rowHeight = 34;
}

function setBody(sheet, range) {
  sheet.getRange(range).format = {
    font: { color: "#1F2937", size: 10 },
    verticalAlignment: "top",
    wrapText: true,
    borders: { insideHorizontal: { style: "thin", color: palette.line } },
  };
}

function applyWidths(sheet, widths) {
  widths.forEach((width, index) => {
    sheet.getRange(`${colName(index)}:${colName(index)}`).format.columnWidth = width;
  });
}

function decorateStatusRange(range) {
  range.conditionalFormats.add("containsText", {
    text: "Verified",
    format: { fill: palette.greenLight, font: { color: palette.green, bold: true } },
  });
  range.conditionalFormats.add("containsText", {
    text: "Pass",
    format: { fill: palette.greenLight, font: { color: palette.green, bold: true } },
  });
  range.conditionalFormats.add("containsText", {
    text: "Fail",
    format: { fill: palette.redLight, font: { color: palette.red, bold: true } },
  });
  range.conditionalFormats.add("containsText", {
    text: "Blocked",
    format: { fill: palette.amberLight, font: { color: palette.amber, bold: true } },
  });
}

function createStoriesSheet(workbook) {
  const sheet = workbook.worksheets.add("Stories");
  sheet.showGridLines = false;
  setTitle(
    sheet,
    "T",
    "Dockit feature ledger",
    "This workbook is the only feature-status source of truth. Every story begins Not run until real evidence exists."
  );

  sheet.getRange("A2:B2").values = [["Total stories", null]];
  sheet.getRange("B2").formulas = [["=COUNTA(A7:A300)"]];
  sheet.getRange("D2:E2").values = [["Verified", null]];
  sheet.getRange("E2").formulas = [["=COUNTIF(H7:H300,\"Verified\")"]];
  sheet.getRange("G2:H2").values = [["Functional pass", null]];
  sheet.getRange("H2").formulas = [["=COUNTIF(I7:I300,\"Pass\")"]];
  sheet.getRange("J2:K2").values = [["Unresolved defects", null]];
  sheet.getRange("K2").formulas = [["=0"]];
  sheet.getRange("M2:T2").merge();
  sheet.getRange("M2").values = [["Verification rule: do not set Verified without a real Dock test, required evidence, and no unresolved high-severity defect."]];
  sheet.getRange("A2:K2").format = {
    fill: palette.blueLight,
    font: { color: palette.navy, bold: true },
    verticalAlignment: "center",
    borders: { preset: "outside", style: "thin", color: palette.line },
  };
  sheet.getRange("M2:T2").format = {
    fill: palette.amberLight,
    font: { color: palette.amber, italic: true, size: 9 },
    wrapText: true,
    verticalAlignment: "center",
  };
  sheet.getRange("A2:T2").format.rowHeight = 26;

  const headers = [
    "Story ID",
    "Area",
    "Contract",
    "User story",
    "Expected behavior",
    "Acceptance test",
    "Dependency / decision",
    "Delivery",
    "Functional",
    "Visual",
    "Motion",
    "Accessibility",
    "Test run IDs",
    "Evidence IDs",
    "Defect IDs",
    "Regression story IDs",
    "Build / commit",
    "Owner",
    "Last updated",
    "Notes",
  ];
  sheet.getRange("A6:T6").values = [headers];
  setHeader(sheet, "A6:T6");

  const rows = stories.map((story) => [
    ...story.slice(0, 7),
    "Ready to build",
    "Not run",
    "Not run",
    "Not run",
    "Not run",
    "",
    "",
    "",
    "",
    "",
    "",
    "",
    "",
  ]);
  sheet.getRange(`A7:T${6 + rows.length}`).values = rows;
  setBody(sheet, `A7:T${6 + rows.length}`);
  sheet.getRange(`A7:C${6 + rows.length}`).format.font = { bold: true, color: palette.navy, size: 10 };
  sheet.getRange(`H7:L${6 + rows.length}`).format.horizontalAlignment = "center";
  sheet.getRange(`H7:H300`).dataValidation = { rule: { type: "list", values: deliveryValues } };
  sheet.getRange(`I7:L300`).dataValidation = { rule: { type: "list", values: verdictValues } };
  decorateStatusRange(sheet.getRange("H7:L300"));
  applyWidths(sheet, [13, 15, 19, 36, 46, 42, 18, 13, 12, 12, 12, 14, 16, 16, 16, 18, 16, 14, 16, 30]);
  sheet.freezePanes.freezeRows(6);
  sheet.freezePanes.freezeColumns(3);
  return sheet;
}

function createTestRunsSheet(workbook) {
  const sheet = workbook.worksheets.add("Test runs");
  sheet.showGridLines = false;
  setTitle(
    sheet,
    "S",
    "Test runs",
    "Append one row for every executed test attempt. Do not overwrite a failed run with its later retest."
  );
  sheet.getRange("A2:B2").values = [["Executed runs", null]];
  sheet.getRange("B2").formulas = [["=COUNTA(A6:A300)"]];
  sheet.getRange("D2:E2").values = [["Functional passes", null]];
  sheet.getRange("E2").formulas = [["=COUNTIF(I6:I300,\"Pass\")"]];
  sheet.getRange("G2:H2").values = [["Failed runs", null]];
  sheet.getRange("H2").formulas = [["=COUNTIF(I6:I300,\"Fail\")"]];
  sheet.getRange("A2:H2").format = {
    fill: palette.blueLight,
    font: { color: palette.navy, bold: true },
    borders: { preset: "outside", style: "thin", color: palette.line },
  };
  const headers = [
    "Run ID",
    "Story IDs",
    "Build / commit",
    "macOS / device",
    "Preconditions",
    "Steps",
    "Expected result",
    "Actual result",
    "Functional",
    "Visual",
    "Motion",
    "Accessibility",
    "Before screenshot",
    "After screenshot",
    "Recording",
    "Defect IDs",
    "Tester",
    "Run date",
    "Notes",
  ];
  sheet.getRange("A5:S5").values = [headers];
  setHeader(sheet, "A5:S5");
  setBody(sheet, "A6:S300");
  sheet.getRange("I6:L300").dataValidation = { rule: { type: "list", values: verdictValues } };
  decorateStatusRange(sheet.getRange("I6:L300"));
  applyWidths(sheet, [14, 13, 16, 22, 32, 42, 34, 34, 12, 12, 12, 14, 22, 22, 22, 16, 16, 14, 30]);
  sheet.freezePanes.freezeRows(5);
  sheet.freezePanes.freezeColumns(2);
  return sheet;
}

function createDefectsSheet(workbook) {
  const sheet = workbook.worksheets.add("Defects");
  sheet.showGridLines = false;
  setTitle(
    sheet,
    "R",
    "Defects",
    "Log every reproducible functional, UX, visual, privacy, and accessibility error. Link it to its failed run and retest."
  );
  sheet.getRange("A2:B2").values = [["Unresolved defects", null]];
  sheet.getRange("B2").formulas = [["=COUNTIF(L6:L300,\"Open\")+COUNTIF(L6:L300,\"Fixing\")+COUNTIF(L6:L300,\"Fixed\")+COUNTIF(L6:L300,\"Deferred\")"]];
  sheet.getRange("D2:E2").values = [["Fixed defects", null]];
  sheet.getRange("E2").formulas = [["=COUNTIF(L6:L300,\"Fixed\")"]];
  sheet.getRange("G2:H2").values = [["Closed defects", null]];
  sheet.getRange("H2").formulas = [["=COUNTIF(L6:L300,\"Closed\")"]];
  sheet.getRange("A2:H2").format = {
    fill: palette.blueLight,
    font: { color: palette.navy, bold: true },
    borders: { preset: "outside", style: "thin", color: palette.line },
  };
  const headers = [
    "Defect ID",
    "Found in run",
    "Story IDs",
    "Type",
    "Severity",
    "Summary",
    "Reproduction steps",
    "Expected behavior",
    "Actual behavior",
    "Root cause",
    "Fix reference",
    "Status",
    "Retest run",
    "Evidence IDs",
    "Owner",
    "Found date",
    "Closed date",
    "Notes",
  ];
  sheet.getRange("A5:R5").values = [headers];
  setHeader(sheet, "A5:R5");
  setBody(sheet, "A6:R300");
  sheet.getRange("E6:E300").dataValidation = { rule: { type: "list", values: ["P0", "P1", "P2", "P3"] } };
  sheet.getRange("L6:L300").dataValidation = { rule: { type: "list", values: ["Open", "Fixing", "Fixed", "Closed", "Deferred"] } };
  decorateStatusRange(sheet.getRange("L6:L300"));
  applyWidths(sheet, [14, 14, 18, 16, 10, 34, 40, 34, 34, 34, 20, 14, 14, 18, 16, 14, 14, 30]);
  sheet.freezePanes.freezeRows(5);
  sheet.freezePanes.freezeColumns(3);
  return sheet;
}

function createDecisionsSheet(workbook) {
  const sheet = workbook.worksheets.add("Decisions");
  sheet.showGridLines = false;
  setTitle(
    sheet,
    "F",
    "Decisions and skill routes",
    "Product choices are settled here. Requested skills are recorded here with their local route and pending review state."
  );
  sheet.getRange("A5:F5").values = [["Decision ID", "Type", "Item", "State", "Settled behavior", "Affected stories"]];
  setHeader(sheet, "A5:F5");
  sheet.getRange(`A6:F${5 + decisions.length}`).values = decisions;
  setBody(sheet, `A6:F${5 + decisions.length}`);
  sheet.getRange(`A6:D${5 + decisions.length}`).format.font = { bold: true, color: palette.navy, size: 10 };

  const routeTitleRow = 8 + decisions.length;
  sheet.getRange(`A${routeTitleRow}:F${routeTitleRow}`).merge();
  sheet.getRange(`A${routeTitleRow}`).values = [["Requested skill routes"]];
  sheet.getRange(`A${routeTitleRow}:F${routeTitleRow}`).format = {
    fill: palette.slateLight,
    font: { bold: true, color: palette.navy, size: 11 },
    verticalAlignment: "center",
  };
  sheet.getRange(`A${routeTitleRow}:F${routeTitleRow}`).format.rowHeight = 22;
  const routeHeaderRow = routeTitleRow + 1;
  sheet.getRange(`A${routeHeaderRow}:F${routeHeaderRow}`).values = [["Route", "Request", "Use", "Review state", "Timing / note", "Local source"]];
  setHeader(sheet, `A${routeHeaderRow}:F${routeHeaderRow}`);
  const routeStart = routeHeaderRow + 1;
  sheet.getRange(`A${routeStart}:F${routeStart + routes.length - 1}`).values = routes;
  setBody(sheet, `A${routeStart}:F${routeStart + routes.length - 1}`);
  sheet.getRange(`A${routeStart}:D${routeStart + routes.length - 1}`).format.font = { bold: true, color: palette.navy, size: 10 };
  sheet.getRange(`D${routeStart}:D${routeStart + routes.length - 1}`).conditionalFormats.add("containsText", {
    text: "Missing",
    format: { fill: palette.redLight, font: { color: palette.red, bold: true } },
  });
  sheet.getRange(`D${routeStart}:D${routeStart + routes.length - 1}`).conditionalFormats.add("containsText", {
    text: "Pending",
    format: { fill: palette.amberLight, font: { color: palette.amber, bold: true } },
  });
  sheet.getRange(`D${routeStart}:D${routeStart + routes.length - 1}`).conditionalFormats.add("containsText", {
    text: "Active",
    format: { fill: palette.greenLight, font: { color: palette.green, bold: true } },
  });
  ensureExecutionDecisionAudit(sheet);
  applyWidths(sheet, [22, 18, 28, 24, 46, 66]);
  sheet.freezePanes.freezeRows(5);
  return sheet;
}

function createEvidenceSheet(workbook) {
  const sheet = workbook.worksheets.add("Evidence");
  sheet.showGridLines = false;
  setTitle(
    sheet,
    "L",
    "Evidence",
    "Link every screenshot, recording, or artifact to the story and test run it proves. A screenshot cannot prove motion by itself."
  );
  sheet.getRange("A2:B2").values = [["Evidence items", null]];
  sheet.getRange("B2").formulas = [["=COUNTA(A6:A300)"]];
  sheet.getRange("D2:E2").values = [["Screenshot items", null]];
  sheet.getRange("E2").formulas = [["=COUNTIF(B6:B300,\"Screenshot\")"]];
  sheet.getRange("G2:H2").values = [["Recording items", null]];
  sheet.getRange("H2").formulas = [["=COUNTIF(B6:B300,\"Recording\")"]];
  sheet.getRange("A2:H2").format = {
    fill: palette.blueLight,
    font: { color: palette.navy, bold: true },
    borders: { preset: "outside", style: "thin", color: palette.line },
  };
  const headers = [
    "Evidence ID",
    "Type",
    "Story IDs",
    "Run ID",
    "Build / commit",
    "File path",
    "Scenario / state shown",
    "Captured at",
    "Visual review question",
    "Reviewer answer",
    "Verdict",
    "Notes",
  ];
  sheet.getRange("A5:L5").values = [headers];
  setHeader(sheet, "A5:L5");
  setBody(sheet, "A6:L300");
  sheet.getRange("B6:B300").dataValidation = { rule: { type: "list", values: ["Screenshot", "Recording", "Log", "Other"] } };
  sheet.getRange("K6:K300").dataValidation = { rule: { type: "list", values: verdictValues } };
  decorateStatusRange(sheet.getRange("K6:K300"));
  applyWidths(sheet, [16, 14, 14, 14, 16, 44, 32, 20, 48, 42, 14, 30]);
  sheet.freezePanes.freezeRows(5);
  sheet.freezePanes.freezeColumns(3);
  return sheet;
}

function buildWorkbook() {
  const workbook = Workbook.create();
  createStoriesSheet(workbook);
  createTestRunsSheet(workbook);
  createDefectsSheet(workbook);
  createDecisionsSheet(workbook);
  createEvidenceSheet(workbook);
  normalizeVisibleProductProse(workbook);
  normalizeLedgerSchema(workbook);
  return workbook;
}

function findStoryRow(sheet, storyId) {
  const values = sheet.getRange("A7:A300").values;
  const offset = values.findIndex(([value]) => value === storyId);
  if (offset < 0) throw new Error(`Story ID not found: ${storyId}`);
  return 7 + offset;
}

function findValueRow(sheet, column, startRow, value) {
  const values = sheet.getRange(`${column}${startRow}:${column}300`).values;
  const offset = values.findIndex(([candidate]) => candidate === value);
  if (offset < 0) throw new Error(`Value not found on ${sheet.name}: ${value}`);
  return startRow + offset;
}

function findValueRowOrBlank(sheet, column, startRow, value) {
  const values = sheet.getRange(`${column}${startRow}:${column}300`).values;
  const existingOffset = values.findIndex(([candidate]) => candidate === value);
  if (existingOffset >= 0) return startRow + existingOffset;
  const blankOffset = values.findIndex(([candidate]) => !candidate);
  if (blankOffset < 0) throw new Error(`No blank row available on ${sheet.name}`);
  return startRow + blankOffset;
}

function findValueRowInRange(sheet, column, startRow, endRow, value) {
  const values = sheet.getRange(`${column}${startRow}:${column}${endRow}`).values;
  const offset = values.findIndex(([candidate]) => candidate === value);
  return offset < 0 ? null : startRow + offset;
}

function findValueRowOrBlankInRange(sheet, column, startRow, endRow, value) {
  const values = sheet.getRange(`${column}${startRow}:${column}${endRow}`).values;
  const existingOffset = values.findIndex(([candidate]) => candidate === value);
  if (existingOffset >= 0) return startRow + existingOffset;
  const blankOffset = values.findIndex(([candidate]) => !candidate);
  if (blankOffset < 0) throw new Error(`No blank row available on ${sheet.name}`);
  return startRow + blankOffset;
}

function executionDecisionAudit(sheet) {
  const titleRow = findValueRowInRange(sheet, "A", 21, 300, executionDecisionAuditTitle);
  if (titleRow === null) return null;
  return { titleRow, headerRow: titleRow + 1, startRow: titleRow + 2 };
}

function ensureExecutionDecisionAudit(sheet) {
  const existing = executionDecisionAudit(sheet);
  if (existing) return existing;

  const values = sheet.getRange("A23:A300").values;
  let lastUsedRow = 22;
  values.forEach(([value], offset) => {
    if (value) lastUsedRow = 23 + offset;
  });
  const titleRow = lastUsedRow + 2;
  const headerRow = titleRow + 1;
  if (headerRow >= 300) throw new Error("No room remains for the execution decision audit");

  sheet.getRange(`A${titleRow}:F${titleRow}`).merge();
  sheet.getRange(`A${titleRow}`).values = [[executionDecisionAuditTitle]];
  sheet.getRange(`A${titleRow}:F${titleRow}`).format = {
    fill: palette.slateLight,
    font: { bold: true, color: palette.navy, size: 11 },
    verticalAlignment: "center",
  };
  sheet.getRange(`A${titleRow}:F${titleRow}`).format.rowHeight = 22;
  sheet.getRange(`A${headerRow}:F${headerRow}`).values = [[
    "Decision ID",
    "Type",
    "Item",
    "State",
    "Settled behavior",
    "Affected stories",
  ]];
  setHeader(sheet, `A${headerRow}:F${headerRow}`);
  return { titleRow, headerRow, startRow: headerRow + 1 };
}

function hasValue(args, key) {
  return Object.prototype.hasOwnProperty.call(args, key) && args[key] !== undefined && args[key] !== true;
}

function setIfPresent(sheet, cell, value) {
  if (value !== undefined && value !== true) sheet.getRange(cell).values = [[value]];
}

function firstValue(args, keys) {
  for (const key of keys) {
    if (hasValue(args, key)) return args[key];
  }
  return undefined;
}

function isFlag(args, key) {
  return args[key] === true || args[key] === "true";
}

function parseIDs(value) {
  if (value === undefined || value === null || value === true || value === "") return [];
  const values = Array.isArray(value) ? value : [value];
  const seen = new Set();
  const result = [];
  for (const entry of values) {
    for (const candidate of String(entry).split(/[,;\n]/)) {
      const id = candidate.trim();
      if (id && !seen.has(id)) {
        seen.add(id);
        result.push(id);
      }
    }
  }
  return result;
}

function formatIDs(ids) {
  return parseIDs(ids).join(", ");
}

function mergeIDs(existing, additions, clear = false) {
  return formatIDs([...(clear ? [] : parseIDs(existing)), ...parseIDs(additions)]);
}

function parseHistoricalDate(value, key) {
  if (value instanceof Date) {
    if (Number.isNaN(value.getTime())) throw new Error(`--${key} must be a valid date`);
    return value;
  }
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) throw new Error(`--${key} must be a valid date`);
  return date;
}

function dateValue(args, key, existing, fallback) {
  if (hasValue(args, key)) return parseHistoricalDate(args[key], key);
  return existing || fallback;
}

function setRowValueIfPresent(row, index, args, keys) {
  const value = firstValue(args, keys);
  if (value !== undefined) row[index] = value;
}

function normalizeLedgerSchema(workbook) {
  const storiesSheet = workbook.worksheets.getItem("Stories");
  storiesSheet.getRange("A1").values = [["dockit feature ledger"]];
  storiesSheet.getRange("G6").values = [["Source, code, or decision refs"]];
  storiesSheet.getRange("J2").values = [["Unresolved defects"]];
  storiesSheet.getRange("K2").formulas = [["=Defects!B2"]];
  storiesSheet.getRange("O6").values = [["Defect IDs"]];

  const runsSheet = workbook.worksheets.getItem("Test runs");
  runsSheet.getRange("B5").values = [["Story IDs"]];

  const defectsSheet = workbook.worksheets.getItem("Defects");
  defectsSheet.getRange("A2").values = [["Unresolved defects"]];
  defectsSheet.getRange("B2").formulas = [["=COUNTIF(L6:L300,\"Open\")+COUNTIF(L6:L300,\"Fixing\")+COUNTIF(L6:L300,\"Fixed\")+COUNTIF(L6:L300,\"Deferred\")"]];

  const evidenceSheet = workbook.worksheets.getItem("Evidence");
  evidenceSheet.getRange("C5").values = [["Story IDs"]];
}

function applyUpdate(workbook, args) {
  const hasOperation = args.story || args["upsert-story"] || args["decision-id"] || args.skill || args["upsert-skill"] || args["upsert-run"] || args["evidence-id"] || args["defect-id"] || args["clear-run-defects"] || isFlag(args, "normalize-branding");
  if (!hasOperation) {
    throw new Error("--update requires a story, decision, skill, run, evidence, defect, or branding operation");
  }
  if (args["run-id"] && !args["upsert-run"]) {
    throw new Error("--run-id only identifies an explicit --upsert-run operation. Use --evidence-run-id or --found-in-run for relationships.");
  }

  normalizeLedgerSchema(workbook);
  const now = new Date();

  if (isFlag(args, "normalize-branding")) normalizeVisibleProductProse(workbook);

  if (args.story || args["upsert-story"]) {
    const storiesSheet = workbook.worksheets.getItem("Stories");
    const storyId = args.story ?? firstValue(args, ["story-id"])
      ?? (args["upsert-story"] === true ? undefined : args["upsert-story"]);
    if (!storyId) throw new Error("--upsert-story requires --story-id");
    const isUpsert = Boolean(args["upsert-story"]);
    const storyRow = isUpsert
      ? findValueRowOrBlank(storiesSheet, "A", 7, storyId)
      : findStoryRow(storiesSheet, storyId);
    const existingStory = storiesSheet.getRange(`A${storyRow}:T${storyRow}`).values[0];
    const storyValues = existingStory[0]
      ? [...existingStory]
      : [storyId, "", "", "", "", "", "", "Ready to build", "Not run", "Not run", "Not run", "Not run", "", "", "", "", "", "", "", ""];
    const definitionUpdates = {
      area: 1,
      contract: 2,
      "user-story": 3,
      "expected-behavior": 4,
      "acceptance-test": 5,
    };
    storyValues[0] = storyId;
    let definitionChanged = false;
    for (const [key, index] of Object.entries(definitionUpdates)) {
      if (hasValue(args, key) && storyValues[index] !== args[key]) {
        storyValues[index] = args[key];
        definitionChanged = true;
      }
    }
    if (!existingStory[0]) {
      for (const index of [1, 2, 3, 4, 5]) {
        if (!storyValues[index]) throw new Error(`New story ${storyId} is missing a required definition field`);
      }
      storiesSheet.getRange(`A${storyRow}:T${storyRow}`).values = [storyValues];
      setBody(storiesSheet, `A${storyRow}:T${storyRow}`);
      storiesSheet.getRange(`A${storyRow}:C${storyRow}`).format.font = { bold: true, color: palette.navy, size: 10 };
    } else if (definitionChanged) {
      storiesSheet.getRange(`A${storyRow}:F${storyRow}`).values = [storyValues.slice(0, 6)];
    }
    const scalarUpdates = {
      refs: "G",
      delivery: "H",
      functional: "I",
      visual: "J",
      motion: "K",
      accessibility: "L",
      build: "Q",
      owner: "R",
      notes: "T",
    };
    let storyChanged = !existingStory[0] || definitionChanged || hasValue(args, "updated-at");
    for (const [key, column] of Object.entries(scalarUpdates)) {
      if (hasValue(args, key)) {
        setIfPresent(storiesSheet, `${column}${storyRow}`, args[key]);
        storyChanged = true;
      }
    }
    const historyUpdates = [
      { column: "M", key: "test-runs", clear: "clear-test-runs" },
      { column: "N", key: "evidence", clear: "clear-evidence" },
      { column: "O", key: hasValue(args, "story-defects") ? "story-defects" : "defects", clear: "clear-story-defects" },
      { column: "P", key: "regression", clear: "clear-regression" },
    ];
    for (const update of historyUpdates) {
      if (hasValue(args, update.key) || isFlag(args, update.clear)) {
        const cell = `${update.column}${storyRow}`;
        const existing = storiesSheet.getRange(cell).values[0][0];
        storiesSheet.getRange(cell).values = [[mergeIDs(existing, args[update.key], isFlag(args, update.clear)) || null]];
        storyChanged = true;
      }
    }
    if (storyChanged) {
      storiesSheet.getRange(`S${storyRow}`).values = [[dateValue(args, "updated-at", null, now)]];
      storiesSheet.getRange(`S${storyRow}`).format.numberFormat = "yyyy-mm-dd hh:mm";
    }
  }

  if (args["decision-id"]) {
    const decisionSheet = workbook.worksheets.getItem("Decisions");
    const existingDecisionRow = findValueRowInRange(decisionSheet, "A", 6, 20, args["decision-id"]);
    const audit = ensureExecutionDecisionAudit(decisionSheet);
    const row = existingDecisionRow
      ?? findValueRowOrBlankInRange(decisionSheet, "A", audit.startRow, 300, args["decision-id"]);
    const existing = decisionSheet.getRange(`A${row}:F${row}`).values[0];
    const values = existing[0]
      ? [...existing]
      : [args["decision-id"], "Execution decision", "", "Settled", "", ""];
    values[0] = args["decision-id"];
    setRowValueIfPresent(values, 1, args, ["decision-type"]);
    setRowValueIfPresent(values, 2, args, ["item"]);
    setRowValueIfPresent(values, 3, args, ["state"]);
    setRowValueIfPresent(values, 4, args, ["behavior"]);
    const affectedStories = firstValue(args, ["affected-stories", "story-ids", "story"]);
    if (affectedStories !== undefined || isFlag(args, "clear-affected-stories")) {
      values[5] = mergeIDs(values[5], affectedStories, isFlag(args, "clear-affected-stories"));
    }
    decisionSheet.getRange(`A${row}:F${row}`).values = [values];
    setBody(decisionSheet, `A${row}:F${row}`);
    decisionSheet.getRange(`A${row}:D${row}`).format.font = { bold: true, color: palette.navy, size: 10 };
  }

  if (args.skill || args["upsert-skill"]) {
    const decisionSheet = workbook.worksheets.getItem("Decisions");
    const skillName = args.skill ?? firstValue(args, ["skill-name"])
      ?? (args["upsert-skill"] === true ? undefined : args["upsert-skill"]);
    if (!skillName) throw new Error("--upsert-skill requires --skill-name");
    const audit = ensureExecutionDecisionAudit(decisionSheet);
    const routeEndRow = audit.titleRow - 1;
    const row = args["upsert-skill"]
      ? findValueRowOrBlankInRange(decisionSheet, "A", 23, routeEndRow, skillName)
      : findValueRowInRange(decisionSheet, "A", 23, routeEndRow, skillName);
    if (row === null) throw new Error(`Value not found on ${decisionSheet.name}: ${skillName}`);
    const existing = decisionSheet.getRange(`A${row}:F${row}`).values[0];
    const values = existing[0] ? [...existing] : [skillName, "Requested", "", "", "", ""];
    values[0] = skillName;
    setRowValueIfPresent(values, 1, args, ["skill-request"]);
    setRowValueIfPresent(values, 2, args, ["skill-use"]);
    setRowValueIfPresent(values, 3, args, ["skill-state"]);
    setRowValueIfPresent(values, 4, args, ["skill-note"]);
    setRowValueIfPresent(values, 5, args, ["skill-source"]);
    decisionSheet.getRange(`A${row}:F${row}`).values = [values];
    setBody(decisionSheet, `A${row}:F${row}`);
    decisionSheet.getRange(`A${row}:D${row}`).format.font = { bold: true, color: palette.navy, size: 10 };
  }

  if (hasValue(args, "clear-run-defects") && !args["upsert-run"]) {
    const runs = workbook.worksheets.getItem("Test runs");
    const runRow = findValueRow(runs, "A", 6, args["clear-run-defects"]);
    runs.getRange(`P${runRow}`).values = [[null]];
  }

  if (args["upsert-run"]) {
    const runId = firstValue(args, ["run-id"]) ?? (args["upsert-run"] === true ? undefined : args["upsert-run"]);
    if (!runId) throw new Error("--upsert-run requires --run-id");
    const runs = workbook.worksheets.getItem("Test runs");
    const row = findValueRowOrBlank(runs, "A", 6, runId);
    const existing = runs.getRange(`A${row}:S${row}`).values[0];
    const values = existing[0]
      ? [...existing]
      : [runId, "", "", "", "", "", "", "", "Not run", "Not run", "Not run", "Not run", "", "", "", "", "", now, ""];
    values[0] = runId;
    const storyIDs = firstValue(args, ["story-ids", "story"]);
    if (storyIDs !== undefined || isFlag(args, "clear-run-stories")) {
      values[1] = mergeIDs(values[1], storyIDs, isFlag(args, "clear-run-stories"));
    }
    setRowValueIfPresent(values, 2, args, ["build"]);
    setRowValueIfPresent(values, 3, args, ["environment"]);
    setRowValueIfPresent(values, 4, args, ["run-preconditions", "preconditions"]);
    setRowValueIfPresent(values, 5, args, ["run-steps", "steps"]);
    setRowValueIfPresent(values, 6, args, ["run-expected", "expected"]);
    setRowValueIfPresent(values, 7, args, ["run-actual", "actual"]);
    setRowValueIfPresent(values, 8, args, ["run-functional", "functional"]);
    setRowValueIfPresent(values, 9, args, ["run-visual", "visual"]);
    setRowValueIfPresent(values, 10, args, ["run-motion", "motion"]);
    setRowValueIfPresent(values, 11, args, ["run-accessibility", "accessibility"]);
    setRowValueIfPresent(values, 12, args, ["before"]);
    setRowValueIfPresent(values, 13, args, ["after"]);
    setRowValueIfPresent(values, 14, args, ["recording"]);
    const runDefects = firstValue(args, ["run-defects", "defects"]);
    if (runDefects !== undefined || isFlag(args, "clear-run-defects")) {
      values[15] = mergeIDs(values[15], runDefects, isFlag(args, "clear-run-defects"));
    }
    setRowValueIfPresent(values, 16, args, ["tester"]);
    values[17] = dateValue(args, "run-date", values[17], now);
    setRowValueIfPresent(values, 18, args, ["run-notes"]);
    if (parseIDs(values[1]).length === 0) throw new Error(`Run ${runId} requires at least one story ID`);
    runs.getRange(`A${row}:S${row}`).values = [values];
    runs.getRange(`R${row}`).format.numberFormat = "yyyy-mm-dd hh:mm";
  }

  if (args["evidence-id"]) {
    const evidence = workbook.worksheets.getItem("Evidence");
    const row = findValueRowOrBlank(evidence, "A", 6, args["evidence-id"]);
    const existing = evidence.getRange(`A${row}:L${row}`).values[0];
    const values = existing[0]
      ? [...existing]
      : [args["evidence-id"], "Screenshot", "", "", "", "", "", now, "Does this evidence clearly prove the stated behavior?", "", "Not run", ""];
    values[0] = args["evidence-id"];
    setRowValueIfPresent(values, 1, args, ["evidence-type"]);
    const storyIDs = firstValue(args, ["story-ids", "story"]);
    if (storyIDs !== undefined || isFlag(args, "clear-evidence-stories")) {
      values[2] = mergeIDs(values[2], storyIDs, isFlag(args, "clear-evidence-stories"));
    }
    if (isFlag(args, "clear-evidence-run")) values[3] = "";
    setRowValueIfPresent(values, 3, args, ["evidence-run-id"]);
    setRowValueIfPresent(values, 4, args, ["build"]);
    setRowValueIfPresent(values, 5, args, ["file"]);
    setRowValueIfPresent(values, 6, args, ["scenario"]);
    values[7] = dateValue(args, "captured-at", values[7], now);
    setRowValueIfPresent(values, 8, args, ["question"]);
    setRowValueIfPresent(values, 9, args, ["answer"]);
    setRowValueIfPresent(values, 10, args, ["verdict"]);
    setRowValueIfPresent(values, 11, args, ["evidence-notes"]);
    if (parseIDs(values[2]).length === 0) throw new Error(`Evidence ${args["evidence-id"]} requires at least one story ID`);
    evidence.getRange(`A${row}:L${row}`).values = [values];
    evidence.getRange(`H${row}`).format.numberFormat = "yyyy-mm-dd hh:mm";
  }

  if (args["defect-id"]) {
    const defects = workbook.worksheets.getItem("Defects");
    const row = findValueRowOrBlank(defects, "A", 6, args["defect-id"]);
    const existing = defects.getRange(`A${row}:R${row}`).values[0];
    const values = existing[0]
      ? [...existing]
      : [args["defect-id"], "", "", "Functional", "P2", "", "", "", "", "", "", "Open", "", "", "", now, "", ""];
    const previousStatus = values[11];
    values[0] = args["defect-id"];
    if (isFlag(args, "clear-found-in-run")) values[1] = "";
    setRowValueIfPresent(values, 1, args, ["found-in-run"]);
    const storyIDs = firstValue(args, ["story-ids", "story"]);
    if (storyIDs !== undefined || isFlag(args, "clear-defect-stories")) {
      values[2] = mergeIDs(values[2], storyIDs, isFlag(args, "clear-defect-stories"));
    }
    setRowValueIfPresent(values, 3, args, ["defect-type"]);
    setRowValueIfPresent(values, 4, args, ["severity"]);
    setRowValueIfPresent(values, 5, args, ["summary"]);
    setRowValueIfPresent(values, 6, args, ["defect-reproduction", "reproduction"]);
    setRowValueIfPresent(values, 7, args, ["defect-expected", "expected"]);
    setRowValueIfPresent(values, 8, args, ["defect-actual", "actual"]);
    setRowValueIfPresent(values, 9, args, ["root-cause"]);
    setRowValueIfPresent(values, 10, args, ["fix-reference"]);
    setRowValueIfPresent(values, 11, args, ["defect-status"]);
    if (isFlag(args, "clear-retest-run")) values[12] = "";
    setRowValueIfPresent(values, 12, args, ["retest-run"]);
    const defectEvidence = firstValue(args, ["defect-evidence", "evidence"]);
    if (defectEvidence !== undefined || isFlag(args, "clear-defect-evidence")) {
      values[13] = mergeIDs(values[13], defectEvidence, isFlag(args, "clear-defect-evidence"));
    }
    setRowValueIfPresent(values, 14, args, ["owner"]);
    values[15] = dateValue(args, "found-date", values[15], now);
    if (hasValue(args, "closed-date")) {
      values[16] = parseHistoricalDate(args["closed-date"], "closed-date");
    } else if (hasValue(args, "defect-status") && values[11] === "Closed" && previousStatus !== "Closed") {
      values[16] = now;
    } else if (hasValue(args, "defect-status") && values[11] !== "Closed") {
      values[16] = "";
    }
    setRowValueIfPresent(values, 17, args, ["defect-notes"]);
    if (parseIDs(values[2]).length === 0) throw new Error(`Defect ${args["defect-id"]} requires at least one story ID`);
    if (values[16] && values[11] !== "Closed") throw new Error(`Defect ${args["defect-id"]} has a closed date but is not Closed`);
    defects.getRange(`A${row}:R${row}`).values = [values];
    defects.getRange(`P${row}`).format.numberFormat = "yyyy-mm-dd hh:mm";
    defects.getRange(`Q${row}`).format.numberFormat = "yyyy-mm-dd hh:mm";
  }
}

function createRowIndex(sheet, range, firstRow) {
  const rows = sheet.getRange(range).values;
  const index = new Map();
  const errors = [];
  rows.forEach((values, offset) => {
    const id = String(values[0] ?? "").trim();
    if (!id) return;
    const row = firstRow + offset;
    if (index.has(id)) errors.push(`${sheet.name} has duplicate ID ${id} at rows ${index.get(id).row} and ${row}`);
    else index.set(id, { row, values });
  });
  return { index, errors };
}

function checkReferences(errors, source, value, target, targetLabel) {
  for (const id of parseIDs(value)) {
    if (!target.has(id)) errors.push(`${source} references missing ${targetLabel} ${id}`);
  }
}

function validateWorkbook(workbook) {
  const storyRows = createRowIndex(workbook.worksheets.getItem("Stories"), "A7:T300", 7);
  const runRows = createRowIndex(workbook.worksheets.getItem("Test runs"), "A6:S300", 6);
  const defectRows = createRowIndex(workbook.worksheets.getItem("Defects"), "A6:R300", 6);
  const evidenceRows = createRowIndex(workbook.worksheets.getItem("Evidence"), "A6:L300", 6);
  const errors = [...storyRows.errors, ...runRows.errors, ...defectRows.errors, ...evidenceRows.errors];

  for (const [storyId, entry] of storyRows.index) {
    const values = entry.values;
    checkReferences(errors, `Stories!M${entry.row}`, values[12], runRows.index, "run");
    checkReferences(errors, `Stories!N${entry.row}`, values[13], evidenceRows.index, "evidence");
    checkReferences(errors, `Stories!O${entry.row}`, values[14], defectRows.index, "defect");
    checkReferences(errors, `Stories!P${entry.row}`, values[15], storyRows.index, "story");
    if (values[7] !== "Verified") continue;

    if (values[8] !== "Pass") errors.push(`${storyId} cannot be Verified until Functional is Pass`);
    for (const [label, value] of [["Visual", values[9]], ["Motion", values[10]], ["Accessibility", values[11]]]) {
      if (!completedReviewValues.has(value)) errors.push(`${storyId} cannot be Verified until ${label} is Pass or Not applicable`);
    }

    const linkedRunIDs = parseIDs(values[12]);
    const passingRuns = linkedRunIDs.filter((runId) => {
      const run = runRows.index.get(runId)?.values;
      return run && run[8] === "Pass" && parseIDs(run[1]).includes(storyId);
    });
    if (passingRuns.length === 0) errors.push(`${storyId} cannot be Verified without a linked passing test run`);

    const linkedEvidenceIDs = parseIDs(values[13]);
    const passingEvidence = linkedEvidenceIDs.some((evidenceId) => {
      const evidence = evidenceRows.index.get(evidenceId)?.values;
      if (!evidence || evidence[10] !== "Pass" || !parseIDs(evidence[2]).includes(storyId)) return false;
      const runId = String(evidence[3] ?? "").trim();
      return passingRuns.includes(runId);
    });
    if (!passingEvidence) errors.push(`${storyId} cannot be Verified without passing evidence linked to a passing story run`);

    const unresolvedHighSeverity = [...defectRows.index].filter(([, defect]) => {
      const defectValues = defect.values;
      return parseIDs(defectValues[2]).includes(storyId)
        && ["P0", "P1"].includes(defectValues[4])
        && unresolvedDefectStatuses.has(defectValues[11]);
    });
    if (unresolvedHighSeverity.length > 0) {
      errors.push(`${storyId} cannot be Verified with unresolved high-severity defects: ${unresolvedHighSeverity.map(([id]) => id).join(", ")}`);
    }
  }

  for (const [runId, entry] of runRows.index) {
    if (parseIDs(entry.values[1]).length === 0) errors.push(`${runId} has no story IDs`);
    checkReferences(errors, `Test runs!B${entry.row}`, entry.values[1], storyRows.index, "story");
    checkReferences(errors, `Test runs!P${entry.row}`, entry.values[15], defectRows.index, "defect");
  }

  for (const [defectId, entry] of defectRows.index) {
    if (parseIDs(entry.values[2]).length === 0) errors.push(`${defectId} has no story IDs`);
    checkReferences(errors, `Defects!B${entry.row}`, entry.values[1], runRows.index, "run");
    checkReferences(errors, `Defects!C${entry.row}`, entry.values[2], storyRows.index, "story");
    checkReferences(errors, `Defects!M${entry.row}`, entry.values[12], runRows.index, "run");
    checkReferences(errors, `Defects!N${entry.row}`, entry.values[13], evidenceRows.index, "evidence");
    if (entry.values[16] && entry.values[11] !== "Closed") errors.push(`${defectId} has a closed date but status ${entry.values[11] || "is blank"}`);
  }

  for (const [evidenceId, entry] of evidenceRows.index) {
    if (parseIDs(entry.values[2]).length === 0) errors.push(`${evidenceId} has no story IDs`);
    checkReferences(errors, `Evidence!C${entry.row}`, entry.values[2], storyRows.index, "story");
    checkReferences(errors, `Evidence!D${entry.row}`, entry.values[3], runRows.index, "run");
  }

  const decisionsSheet = workbook.worksheets.getItem("Decisions");
  const settledDecisionRows = createRowIndex(decisionsSheet, "A6:F20", 6);
  errors.push(...settledDecisionRows.errors);
  const audit = executionDecisionAudit(decisionsSheet);
  const auditDecisionRows = audit
    ? createRowIndex(decisionsSheet, `A${audit.startRow}:F300`, audit.startRow)
    : { index: new Map(), errors: [] };
  errors.push(...auditDecisionRows.errors);
  for (const [decisionId, entry] of auditDecisionRows.index) {
    if (settledDecisionRows.index.has(decisionId)) {
      errors.push(`Decisions has duplicate ID ${decisionId} in the settled block and execution audit`);
    }
    checkReferences(errors, `Decisions!F${entry.row}`, entry.values[5], storyRows.index, "story");
  }
  for (const [, entry] of settledDecisionRows.index) {
    checkReferences(errors, `Decisions!F${entry.row}`, entry.values[5], storyRows.index, "story");
  }

  if (errors.length > 0) throw new Error(`Ledger validation failed:\n- ${errors.join("\n- ")}`);
  return {
    stories: storyRows.index.size,
    runs: runRows.index.size,
    defects: defectRows.index.size,
    evidence: evidenceRows.index.size,
    decisions: settledDecisionRows.index.size + auditDecisionRows.index.size,
  };
}

async function scanFormulaErrors(workbook) {
  const result = await workbook.inspect({
    kind: "match",
    searchTerm: formulaErrorPattern,
    options: { useRegex: true, maxResults: 10000 },
    summary: "complete formula error scan",
  });
  const matches = String(result.ndjson ?? "")
    .split("\n")
    .filter(Boolean)
    .map((line) => JSON.parse(line))
    .filter((entry) => entry.kind === "match");
  if (matches.length > 0) {
    const locations = matches.map((entry) => `${entry.sheet}!${entry.address}: ${entry.value}`).join(", ");
    throw new Error(`Formula error scan failed: ${locations}`);
  }
  return result.ndjson;
}

async function renderWorkbook(workbook, targetRenderDir = renderDir) {
  await fs.mkdir(targetRenderDir, { recursive: true });
  const sheetNames = ["Stories", "Test runs", "Defects", "Decisions", "Evidence"];
  for (const sheetName of sheetNames) {
    const image = await workbook.render({ sheetName, autoCrop: "all", scale: 1, format: "png" });
    const bytes = new Uint8Array(await image.arrayBuffer());
    await fs.writeFile(path.join(targetRenderDir, `${sheetName.replaceAll(" ", "-").replaceAll("&", "and")}.png`), bytes);
  }
}

async function exportAndVerify(workbook, options = {}) {
  const outputPath = options.outputPath ?? workbookPath;
  const shouldRender = options.render !== false;
  const outputRenderDir = options.renderDir ?? renderDir;
  normalizeLedgerSchema(workbook);
  const validation = validateWorkbook(workbook);
  const formulaScan = await scanFormulaErrors(workbook);
  await fs.mkdir(path.dirname(outputPath), { recursive: true });
  const storiesCheck = await workbook.inspect({
    kind: "table",
    range: "Stories!A1:T12",
    include: "values,formulas",
    tableMaxRows: 12,
    tableMaxCols: 20,
  });
  const output = await SpreadsheetFile.exportXlsx(workbook);
  await output.save(outputPath);
  if (shouldRender) await renderWorkbook(workbook, outputRenderDir);
  console.log(JSON.stringify({ workbookPath: outputPath, validation, storiesCheck: storiesCheck.ndjson, formulaScan }, null, 2));
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const targetWorkbookPath = args.workbook ? path.resolve(args.workbook) : workbookPath;
  const shouldRender = !isFlag(args, "skip-render");
  if (args.update) {
    const input = await FileBlob.load(targetWorkbookPath);
    const workbook = await SpreadsheetFile.importXlsx(input);
    if (args["batch-file"]) {
      const operations = JSON.parse(await fs.readFile(args["batch-file"], "utf8"));
      if (!Array.isArray(operations) || operations.length === 0) {
        throw new Error("--batch-file must contain a non-empty JSON array");
      }
      for (const operation of operations) applyUpdate(workbook, operation);
    } else {
      applyUpdate(workbook, args);
    }
    await exportAndVerify(workbook, { outputPath: targetWorkbookPath, render: shouldRender });
    return;
  }

  try {
    await fs.access(targetWorkbookPath);
    throw new Error("Workbook already exists. Use --update to import and amend the canonical workbook.");
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
  const workbook = buildWorkbook();
  await exportAndVerify(workbook, { outputPath: targetWorkbookPath, render: shouldRender });
}

const isMain = process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url;
if (isMain) {
  main().catch((error) => {
    console.error(error.stack || error.message);
    process.exitCode = 1;
  });
}

export {
  applyUpdate,
  buildWorkbook,
  exportAndVerify,
  formatIDs,
  mergeIDs,
  normalizeLedgerSchema,
  normalizeVisibleProductProse,
  normalizeVisibleProductText,
  parseArgs,
  parseIDs,
  scanFormulaErrors,
  validateWorkbook,
};
