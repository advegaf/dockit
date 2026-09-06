import assert from "node:assert/strict";
import test from "node:test";
import {
  applyUpdate,
  buildWorkbook,
  mergeIDs,
  normalizeVisibleProductProse,
  normalizeVisibleProductText,
  scanFormulaErrors,
  validateWorkbook,
} from "./FeatureLedger.mjs";

function cell(workbook, sheetName, address) {
  return workbook.worksheets.getItem(sheetName).getRange(address).values[0][0];
}

function rowFor(workbook, sheetName, column, startRow, value) {
  const rows = workbook.worksheets.getItem(sheetName).getRange(`${column}${startRow}:${column}300`).values;
  const offset = rows.findIndex(([candidate]) => candidate === value);
  assert.ok(offset >= 0, `${value} was not found on ${sheetName}`);
  return startRow + offset;
}

test("ordered ID sets merge without duplicates", () => {
  assert.equal(mergeIDs("TR-001, TR-002", ["TR-002", "TR-003"]), "TR-001, TR-002, TR-003");
  assert.equal(mergeIDs("TR-001", "TR-002", true), "TR-002");
});

test("visible product prose is lowercased without changing paths or identifiers", () => {
  assert.equal(
    normalizeVisibleProductText("Dockit opens Dockit's Settings for the selected Dock."),
    "dockit opens dockit's Settings for the selected Dock."
  );
  assert.equal(normalizeVisibleProductText("Sources/Dockit/AppModel.swift"), "Sources/Dockit/AppModel.swift");
  assert.equal(normalizeVisibleProductText("DockitCore and DockitArchive stay identifiers."), "DockitCore and DockitArchive stay identifiers.");
  assert.equal(normalizeVisibleProductText("Keep `Dockit` as an exact code identifier."), "Keep `Dockit` as an exact code identifier.");
  assert.equal(normalizeVisibleProductText("Dockit.app is a file name."), "Dockit.app is a file name.");
});

test("branding operation changes only designated prose cells", () => {
  const workbook = buildWorkbook();
  const stories = workbook.worksheets.getItem("Stories");
  stories.getRange("D7").values = [["Dockit is visible here."]];
  stories.getRange("G7").values = [["Sources/Dockit/AppModel.swift"]];
  const evidence = workbook.worksheets.getItem("Evidence");
  evidence.getRange("G6").values = [["Dockit settings are visible."]];
  evidence.getRange("F6").values = [["artifacts/ui/Dockit QA Export.dockit"]];

  const changed = normalizeVisibleProductProse(workbook);

  assert.equal(changed, 2);
  assert.equal(cell(workbook, "Stories", "D7"), "dockit is visible here.");
  assert.equal(cell(workbook, "Stories", "G7"), "Sources/Dockit/AppModel.swift");
  assert.equal(cell(workbook, "Evidence", "G6"), "dockit settings are visible.");
  assert.equal(cell(workbook, "Evidence", "F6"), "artifacts/ui/Dockit QA Export.dockit");
});

test("new workbooks contain lowercase visible product prose", () => {
  const workbook = buildWorkbook();
  assert.equal(cell(workbook, "Stories", "D7"), "As a Mac user, I can tell whether dockit supports my Mac.");
  assert.equal(
    cell(workbook, "Stories", "E7"),
    "dockit runs on macOS 26 or later. Unsupported systems cannot install or launch the build."
  );
});

test("run upserts are explicit, partial, plural, and date preserving", () => {
  const workbook = buildWorkbook();
  assert.throws(
    () => applyUpdate(workbook, { "run-id": "TR-001", story: "PRF-001" }),
    /only identifies an explicit --upsert-run operation/
  );

  applyUpdate(workbook, {
    "upsert-run": true,
    "run-id": "TR-001",
    "story-ids": ["PRF-001", "PRF-002", "PRF-001"],
    "run-functional": "Pass",
    "run-date": "2026-08-30T12:00:00Z",
    actual: "Original result",
  });
  applyUpdate(workbook, {
    "upsert-run": true,
    "run-id": "TR-001",
    "story-ids": "PRF-002, PRF-003",
    build: "abc123",
  });

  assert.equal(cell(workbook, "Test runs", "B6"), "PRF-001, PRF-002, PRF-003");
  assert.equal(cell(workbook, "Test runs", "C6"), "abc123");
  assert.equal(cell(workbook, "Test runs", "H6"), "Original result");
  assert.equal(cell(workbook, "Test runs", "R6").toISOString(), "2026-08-30T12:00:00.000Z");
  assert.equal(cell(workbook, "Test runs", "B5"), "Story IDs");
});

test("evidence linkage does not overwrite its run and accepts historical capture time", () => {
  const workbook = buildWorkbook();
  applyUpdate(workbook, {
    "upsert-run": true,
    "run-id": "TR-001",
    "story-ids": "PRF-001",
    "run-functional": "Pass",
  });
  applyUpdate(workbook, {
    "evidence-id": "EV-001",
    "story-ids": "PRF-001",
    "evidence-run-id": "TR-001",
    verdict: "Pass",
    "captured-at": "2026-08-31T09:30:00Z",
  });
  applyUpdate(workbook, { "evidence-id": "EV-001", answer: "Reviewed" });

  assert.equal(cell(workbook, "Evidence", "D6"), "TR-001");
  assert.equal(cell(workbook, "Evidence", "J6"), "Reviewed");
  assert.equal(cell(workbook, "Evidence", "H6").toISOString(), "2026-08-31T09:30:00.000Z");
  assert.equal(cell(workbook, "Test runs", "A6"), "TR-001");
  assert.equal(cell(workbook, "Test runs", "B7"), null);
});

test("story history merges and clears explicitly", () => {
  const workbook = buildWorkbook();
  applyUpdate(workbook, {
    story: "PRF-001",
    "test-runs": "TR-001, TR-002",
    evidence: "EV-001",
    "updated-at": "2026-08-28T08:00:00Z",
  });
  assert.equal(cell(workbook, "Stories", "S12").toISOString(), "2026-08-28T08:00:00.000Z");
  applyUpdate(workbook, { story: "PRF-001", "test-runs": "TR-002, TR-003", evidence: "EV-001, EV-002" });
  assert.equal(cell(workbook, "Stories", "M12"), "TR-001, TR-002, TR-003");
  assert.equal(cell(workbook, "Stories", "N12"), "EV-001, EV-002");

  applyUpdate(workbook, { story: "PRF-001", "clear-test-runs": true, "test-runs": "TR-004" });
  assert.equal(cell(workbook, "Stories", "M12"), "TR-004");
});

test("new stories and skill routes append without rebuilding the workbook", () => {
  const workbook = buildWorkbook();
  applyUpdate(workbook, {
    "upsert-story": true,
    "story-id": "NEW-001",
    area: "Native UX",
    contract: "User constraint",
    "user-story": "As a user, I can inspect a new behavior.",
    "expected-behavior": "The behavior is explicit.",
    "acceptance-test": "Exercise the behavior.",
    delivery: "Building",
  });
  const storyRow = workbook.worksheets.getItem("Stories").getRange("A7:A300").values
    .findIndex(([value]) => value === "NEW-001") + 7;
  assert.ok(storyRow >= 7);
  assert.equal(cell(workbook, "Stories", `H${storyRow}`), "Building");

  applyUpdate(workbook, {
    "upsert-skill": true,
    "skill-name": "new-skill",
    "skill-use": "Targeted review",
    "skill-state": "Executed",
    "skill-note": "Review artifact exists.",
    "skill-source": "/tmp/new-skill/SKILL.md",
  });
  const routeRow = workbook.worksheets.getItem("Decisions").getRange("A23:A300").values
    .findIndex(([value]) => value === "new-skill") + 23;
  assert.ok(routeRow >= 23);
  assert.equal(cell(workbook, "Decisions", `D${routeRow}`), "Executed");
});

test("existing story definitions update without clearing history or status", () => {
  const workbook = buildWorkbook();
  applyUpdate(workbook, {
    story: "PRF-001",
    delivery: "Ready for retest",
    functional: "Pass",
    "test-runs": "TR-HISTORIC",
    evidence: "EV-HISTORIC",
    defects: "DEF-HISTORIC",
  });

  applyUpdate(workbook, {
    story: "PRF-001",
    area: "Saved docks",
    contract: "Approved behavior",
    "user-story": "As a user, I can revise an existing saved dock definition.",
    "expected-behavior": "The revised definition replaces the superseded wording.",
    "acceptance-test": "Inspect the revised definition and its retained history.",
  });

  const row = rowFor(workbook, "Stories", "A", 7, "PRF-001");
  assert.deepEqual(
    workbook.worksheets.getItem("Stories").getRange(`B${row}:F${row}`).values[0],
    [
      "Saved docks",
      "Approved behavior",
      "As a user, I can revise an existing saved dock definition.",
      "The revised definition replaces the superseded wording.",
      "Inspect the revised definition and its retained history.",
    ]
  );
  assert.equal(cell(workbook, "Stories", `H${row}`), "Ready for retest");
  assert.equal(cell(workbook, "Stories", `I${row}`), "Pass");
  assert.equal(cell(workbook, "Stories", `M${row}`), "TR-HISTORIC");
  assert.equal(cell(workbook, "Stories", `N${row}`), "EV-HISTORIC");
  assert.equal(cell(workbook, "Stories", `O${row}`), "DEF-HISTORIC");
  assert.ok(cell(workbook, "Stories", `S${row}`) instanceof Date);
});

test("new execution decisions append below skill routes and validate story references", () => {
  const workbook = buildWorkbook();
  const originalDecision = workbook.worksheets.getItem("Decisions").getRange("A6:F6").values[0];
  const animateRow = rowFor(workbook, "Decisions", "A", 23, "animate");
  const originalAnimate = workbook.worksheets.getItem("Decisions").getRange(`A${animateRow}:F${animateRow}`).values[0];

  applyUpdate(workbook, {
    "decision-id": "DEC-AUDIT-001",
    "decision-type": "Execution decision",
    item: "saved and applied layouts",
    state: "Approved",
    behavior: "store the saved layout separately from the last verified applied layout.",
    "affected-stories": "PRF-001",
  });

  const auditTitleRow = rowFor(workbook, "Decisions", "A", 21, "Execution decision audit");
  const auditRow = rowFor(workbook, "Decisions", "A", auditTitleRow + 2, "DEC-AUDIT-001");
  assert.ok(auditRow > animateRow);
  assert.deepEqual(workbook.worksheets.getItem("Decisions").getRange("A6:F6").values[0], originalDecision);
  assert.deepEqual(
    workbook.worksheets.getItem("Decisions").getRange(`A${animateRow}:F${animateRow}`).values[0],
    originalAnimate
  );
  assert.doesNotThrow(() => validateWorkbook(workbook));

  applyUpdate(workbook, {
    "decision-id": "DEC-AUDIT-002",
    item: "bad reference",
    "affected-stories": "STORY-MISSING",
  });
  assert.throws(
    () => validateWorkbook(workbook),
    /Decisions![A-Z]+\d+ references missing story STORY-MISSING/
  );
});

test("foreign keys are checked after all updates", () => {
  const workbook = buildWorkbook();
  applyUpdate(workbook, { story: "PRF-001", "test-runs": "TR-MISSING" });
  assert.throws(() => validateWorkbook(workbook), /Stories!M12 references missing run TR-MISSING/);

  applyUpdate(workbook, {
    "upsert-run": true,
    "run-id": "TR-MISSING",
    "story-ids": "PRF-001",
  });
  assert.doesNotThrow(() => validateWorkbook(workbook));
});

test("unresolved defect formulas include work awaiting closure", () => {
  const workbook = buildWorkbook();
  applyUpdate(workbook, {
    "defect-id": "DEF-001",
    "story-ids": "PRF-001",
    severity: "P2",
    "defect-status": "Fixed",
    "found-date": "2026-08-27T07:00:00Z",
  });
  assert.equal(cell(workbook, "Defects", "B2"), 1);
  assert.equal(cell(workbook, "Stories", "K2"), 1);
  assert.equal(cell(workbook, "Defects", "P6").toISOString(), "2026-08-27T07:00:00.000Z");

  applyUpdate(workbook, { "defect-id": "DEF-001", "defect-status": "Closed" });
  assert.equal(cell(workbook, "Defects", "B2"), 0);
  assert.equal(cell(workbook, "Stories", "K2"), 0);
});

test("Verified requires completed checks, passing linked evidence, and no unresolved P0 or P1 defect", () => {
  const workbook = buildWorkbook();
  applyUpdate(workbook, {
    "upsert-run": true,
    "run-id": "TR-VERIFY",
    "story-ids": "PRF-001",
    "run-functional": "Pass",
  });
  applyUpdate(workbook, {
    "evidence-id": "EV-VERIFY",
    "story-ids": "PRF-001",
    "evidence-run-id": "TR-VERIFY",
    verdict: "Pass",
  });
  applyUpdate(workbook, {
    story: "PRF-001",
    delivery: "Verified",
    functional: "Pass",
    visual: "Not applicable",
    motion: "Not applicable",
    accessibility: "Not applicable",
    "test-runs": "TR-VERIFY",
    evidence: "EV-VERIFY",
  });
  assert.doesNotThrow(() => validateWorkbook(workbook));

  applyUpdate(workbook, {
    "defect-id": "DEF-VERIFY",
    "story-ids": "PRF-001",
    "found-in-run": "TR-VERIFY",
    severity: "P1",
    "defect-status": "Fixed",
  });
  assert.throws(() => validateWorkbook(workbook), /unresolved high-severity defects: DEF-VERIFY/);

  applyUpdate(workbook, {
    "defect-id": "DEF-VERIFY",
    "defect-status": "Closed",
    "closed-date": "2026-09-01T10:00:00Z",
  });
  assert.equal(cell(workbook, "Defects", "Q6").toISOString(), "2026-09-01T10:00:00.000Z");
  assert.doesNotThrow(() => validateWorkbook(workbook));
});

test("formula scan reaches cells beyond the preview range and rejects errors", async () => {
  const workbook = buildWorkbook();
  workbook.worksheets.getItem("Stories").getRange("T300").formulas = [["=1/0"]];
  await assert.rejects(() => scanFormulaErrors(workbook), /Stories!T300: #DIV\/0!/);
});
