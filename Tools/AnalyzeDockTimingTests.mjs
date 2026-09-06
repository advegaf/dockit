import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { analyzeDockTiming, compareCandidate, parseJSON, strategies, summarizeObservations, validateObservation, validateReliability } from './AnalyzeDockTiming.mjs';

const tool = join(dirname(fileURLToPath(import.meta.url)), 'AnalyzeDockTiming.mjs');
const clone = value => structuredClone(value);

function syntheticReliability(strategy, directory) {
  const regularApps = [{ bundleIdentifier: 'test.synthetic.app', processIdentifier: 100 }];
  const windowRecords = [{ ownerProcessIdentifier: 100, windowNumber: 7, layer: 0, bounds: 'synthetic bounds' }];
  return {
    schemaVersion: 2,
    startedAt: '2026-09-04T10:00:00Z',
    finishedAt: '2026-09-04T10:02:00Z',
    strategy,
    requiredSwitchCount: 20,
    requestedSwitchCount: 20,
    backupPath: join(directory, `${strategy}.synthetic-backup.plist`),
    recoveryMarkerPath: join(directory, `${strategy}.synthetic-recovery.txt`),
    ignoredRuntimeKeys: ['mod-count'],
    ignoredRuntimeKeyRationales: [{ key: 'mod-count', rationale: 'The Dock updates this mutation counter while saving preferences. It is not a user setting.' }],
    baselineDockProcessIdentifier: 1000,
    baselineRegularApps: regularApps,
    baselineWindowRecords: windowRecords,
    switches: Array.from({ length: 20 }, (_, index) => ({
      iteration: index + 1,
      profileName: index % 2 === 0 ? 'synthetic fixture a' : 'synthetic fixture b',
      elapsedMilliseconds: 1200,
      reload: {
        previousProcessIdentifier: 1000 + index,
        currentProcessIdentifier: 1001 + index,
        strategy,
        usedForcedFallback: false,
      },
      skippedApps: [],
      nonPinnedPreferenceChangedKeys: [],
      regularApps,
      regularAppsPreserved: true,
      windowRecords,
      windows: 'preserved',
    })),
    finalNonPinnedPreferenceChangedKeys: [],
    finalRegularApps: regularApps,
    finalRegularAppsPreserved: true,
    finalWindowRecords: windowRecords,
    finalWindows: 'preserved',
    restorationReload: { previousProcessIdentifier: 1020, currentProcessIdentifier: 1021, strategy: strategies[0], usedForcedFallback: false },
    recoveryMarkerState: 'DOCKIT_BENCHMARK_RECOVERY_RESTORED',
    restoredOriginal: true,
    gatePassed: true,
  };
}

function syntheticObservations(strategy, digest) {
  const candidate = strategy !== strategies[0];
  const secondCandidate = strategy === strategies[2];
  return Array.from({ length: 20 }, (_, index) => {
    const request = index * 3 + 1;
    const returned = request + (candidate ? 0.4 : 0.65);
    const settled = request + (candidate ? 0.6 : 1.0);
    return {
      iteration: index + 1,
      recording: `${strategy}.synthetic-recording.bin`,
      recordingSha256: digest,
      frameRate: 1000,
      frameCount: 100_000,
      inspectedFrameRange: { first: Math.floor(request * 1000) - 2, last: Math.ceil(settled * 1000) + 2 },
      restartRequestSeconds: request,
      wallpaperBlackouts: [{ startSeconds: request + 0.01, endSeconds: request + (candidate ? secondCandidate ? 0.22 : 0.21 : 0.37) }],
      firstReturningDockPixelSeconds: returned,
      settledDockSeconds: settled,
      uncertaintyFrames: 1,
      observedExtraRestartCycles: 0,
    };
  });
}

async function fixture(context) {
  const directory = await mkdtemp(join(tmpdir(), 'dockit-synthetic-timing-test-'));
  context.after(() => rm(directory, { recursive: true, force: true }));
  const reports = strategies.map(strategy => syntheticReliability(strategy, directory));
  const annotations = {
    schemaVersion: 1,
    review: { method: 'manual-frame-review', reviewedBy: 'synthetic test fixture, not real visual evidence', reviewedAt: '2026-09-04T11:00:00Z' },
    strategies: [],
  };
  for (const report of reports) {
    const data = `synthetic bytes for offline validator tests only: ${report.strategy}`;
    const digest = createHash('sha256').update(data).digest('hex');
    await writeFile(join(directory, `${report.strategy}.synthetic-recording.bin`), data);
    await writeFile(report.backupPath, 'synthetic backup bytes, not a dock backup');
    await writeFile(report.recoveryMarkerPath, 'DOCKIT_BENCHMARK_RECOVERY_RESTORED\n');
    annotations.strategies.push({
      strategy: report.strategy,
      reliabilityReport: `${report.strategy}.json`,
      observations: syntheticObservations(report.strategy, digest),
    });
  }
  const reliabilityPaths = strategies.map(strategy => join(directory, `${strategy}.json`));
  const annotationsPath = join(directory, 'synthetic-review.json');
  const save = async () => {
    await Promise.all(reports.map((report, index) => writeFile(reliabilityPaths[index], JSON.stringify(report))));
    await writeFile(annotationsPath, JSON.stringify(annotations));
  };
  await save();
  return { directory, reports, annotations, reliabilityPaths, annotationsPath, save, run: () => analyzeDockTiming({ reliabilityPaths, annotationsPath }) };
}

function assertRetained(result) {
  assert.equal(result.recommendedStrategy, strategies[0]);
  assert.equal(result.recommendation, 'retain baseline');
  assert(result.strategies.every(item => !item.eligible));
}

function messages(result) {
  return [...result.issues, ...result.strategies.flatMap(item => item.issues)].map(issue => issue.message).join('\n');
}

test('complete synthetic evidence admits a candidate without mutating evidence files', async context => {
  const data = await fixture(context);
  const before = await Promise.all([...data.reliabilityPaths, data.annotationsPath].map(path => readFile(path, 'utf8')));
  const result = await data.run();
  assert.equal(result.evidenceComplete, true, messages(result));
  assert.equal(result.pixelAnalysisPerformed, false);
  assert.equal(result.recommendedStrategy, strategies[1]);
  assert.equal(result.strategies[1].eligible, true);
  assert.equal(result.strategies[2].eligible, true);
  assert.equal(result.strategies[1].timingGates.length, 6);
  assert(result.strategies[1].timingGates.every(gate => gate.verdict === 'passed'));
  const metrics = result.strategies[1].metrics;
  assert(Math.abs(metrics.wallpaperBlackout.median.point - 200) < 0.00001);
  assert(Math.abs(metrics.firstReturnDelay.median.point - 400) < 0.00001);
  assert(Math.abs(metrics.settlingDelay.median.point - 600) < 0.00001);
  assert.equal(result.strategies[0].reliabilityReportSha256.length, 64);
  assert.deepEqual(await Promise.all([...data.reliabilityPaths, data.annotationsPath].map(path => readFile(path, 'utf8'))), before);
});

test('cli prints advisory json, keeps baseline on absent evidence, and rejects invalid arguments', async context => {
  const data = await fixture(context);
  const argumentsForTool = [...data.reliabilityPaths.flatMap(path => ['--reliability', path]), '--annotations', data.annotationsPath];
  const completed = spawnSync(process.execPath, [tool, ...argumentsForTool], { encoding: 'utf8' });
  assert.equal(completed.status, 0, completed.stderr);
  assert.equal(JSON.parse(completed.stdout).recommendedStrategy, strategies[1]);
  const missing = spawnSync(process.execPath, [tool, ...argumentsForTool.slice(0, -1), join(data.directory, 'missing.json')], { encoding: 'utf8' });
  assert.equal(missing.status, 0);
  assertRetained(JSON.parse(missing.stdout));
  for (const args of [[], ['--annotations'], ['--unknown', 'file'], ['--help', 'extra']]) {
    const invalid = spawnSync(process.execPath, [tool, ...args], { encoding: 'utf8' });
    assert.equal(invalid.status, 2);
    assert.match(JSON.parse(invalid.stdout).error, /provide three/);
  }
  const help = spawnSync(process.execPath, [tool, '--help'], { encoding: 'utf8' });
  assert.equal(help.status, 0);
  assert.match(help.stdout, /does not decode metadata or inspect pixels/);
});

test('json parsing rejects duplicate decoded keys, malformed input, and truncated documents', () => {
  for (const text of ['{"a":1,"a":2}', '{"a":1,"\\u0061":2}', '{"a":[{"b":1,"b":2}]}', '{"a":', '{"a":NaN}', '{"a":Infinity}']) {
    assert.throws(() => parseJSON(text));
  }
  assert.deepEqual(parseJSON('{"a":[{"b":"x"},{"b":"y"}],"c":{"b":2}}'), { a: [{ b: 'x' }, { b: 'y' }], c: { b: 2 } });
});

test('missing annotations and malformed annotation json retain baseline', async context => {
  const data = await fixture(context);
  for (const text of ['', '{', '{"schemaVersion":1,"schemaVersion":1}', 'false', 'null', '[]']) {
    await writeFile(data.annotationsPath, text);
    const result = await data.run();
    assertRetained(result);
    assert.equal(result.evidenceComplete, false);
  }
  await rm(data.annotationsPath);
  assertRetained(await data.run());
});

test('missing report, backup, restoration marker, or recording blocks selection', async context => {
  for (const target of ['report', 'backup', 'marker', 'recording']) {
    const data = await fixture(context);
    const path = {
      report: data.reliabilityPaths[2],
      backup: data.reports[2].backupPath,
      marker: data.reports[2].recoveryMarkerPath,
      recording: join(data.directory, data.annotations.strategies[2].observations[0].recording),
    }[target];
    await rm(path);
    const result = await data.run();
    assertRetained(result);
    assert.equal(result.evidenceComplete, false);
    assert.match(messages(result), /existing nonempty/);
  }
});

test('incorrect marker contents, empty evidence, and a changed recording hash block selection', async context => {
  for (const mutation of ['marker', 'empty', 'changed']) {
    const data = await fixture(context);
    const recording = join(data.directory, data.annotations.strategies[1].observations[0].recording);
    if (mutation === 'marker') await writeFile(data.reports[1].recoveryMarkerPath, 'DOCKIT_BENCHMARK_RECOVERY_ACTIVE\n');
    else await writeFile(recording, mutation === 'empty' ? '' : 'changed synthetic bytes');
    const result = await data.run();
    assertRetained(result);
    assert.equal(result.evidenceComplete, false);
    assert.match(messages(result), /confirm completed restoration|existing nonempty|does not match the recording/);
  }
});

test('all reliability gates are derived from raw evidence rather than gatepassed alone', () => {
  const original = syntheticReliability(strategies[0], '/synthetic-only');
  assert.deepEqual(validateReliability(original), []);
  const mutations = [
    value => { value.schemaVersion = 1; },
    value => { value.requestedSwitchCount = 19; },
    value => { value.requiredSwitchCount = 19; },
    value => { value.ignoredRuntimeKeys.push('orientation'); },
    value => { value.ignoredRuntimeKeyRationales[0].rationale = 'different'; },
    value => { value.baselineDockProcessIdentifier = null; },
    value => { value.baselineWindowRecords = null; },
    value => { value.baselineWindowRecords = []; },
    value => { value.baselineRegularApps.push(clone(value.baselineRegularApps[0])); },
    value => { value.switches.pop(); },
    value => { value.switches.push(clone(value.switches[19])); },
    value => { value.switches[2].iteration = 2; },
    value => { value.switches[2].profileName = 'synthetic third profile'; },
    value => { value.switches.forEach(item => { item.profileName = 'same synthetic profile'; }); },
    value => { value.switches[2].reload = null; },
    value => { value.switches[2].reload.previousProcessIdentifier = 9000; },
    value => { value.switches[2].reload.currentProcessIdentifier = value.switches[2].reload.previousProcessIdentifier; },
    value => { value.switches[2].reload.strategy = strategies[1]; },
    value => { value.switches[2].reload.usedForcedFallback = true; },
    value => { value.switches[2].elapsedMilliseconds = NaN; },
    value => { value.switches[2].skippedApps.push({ name: 'missing' }); },
    value => { value.switches[2].nonPinnedPreferenceChangedKeys.push('persistent-others'); },
    value => { value.switches[2].regularAppsPreserved = false; },
    value => { value.switches[2].regularApps = []; },
    value => { value.switches[2].windowRecords = []; },
    value => { value.switches[2].windows = 'inconclusive'; },
    value => { value.switches[2].failure = 'failed'; },
    value => { value.finalRegularApps = []; },
    value => { value.finalRegularAppsPreserved = false; },
    value => { value.finalWindowRecords = null; },
    value => { value.finalWindows = 'changed'; },
    value => { value.finalNonPinnedPreferenceChangedKeys.push('tilesize'); },
    value => { value.restorationReload = null; },
    value => { value.restorationReload.previousProcessIdentifier = 4; },
    value => { value.restorationReload.strategy = strategies[2]; },
    value => { value.restorationReload.usedForcedFallback = true; },
    value => { value.recoveryMarkerState = 'DOCKIT_BENCHMARK_RECOVERY_ACTIVE'; },
    value => { value.restoredOriginal = false; },
    value => { value.gatePassed = false; },
    value => { value.failure = 'failed'; },
    value => { value.finishedAt = '2026-09-04T09:00:00Z'; },
    value => { value.startedAt = 'not a date'; },
    value => { value.startedAt = '2026-02-30T10:00:00Z'; },
  ];
  for (const [index, mutate] of mutations.entries()) {
    const report = clone(original);
    mutate(report);
    assert(validateReliability(report).length > 0, `reliability mutation ${index} was accepted`);
  }
});

test('an unreliable baseline blocks promotion even when candidates and annotations pass', async context => {
  const data = await fixture(context);
  data.reports[0].switches[0].regularApps = [];
  await data.save();
  const result = await data.run();
  assertRetained(result);
  assert.equal(result.strategies[0].reliabilityPassed, false);
  assert.equal(result.strategies[1].visualEvidenceComplete, true);
});

test('duplicate reports, strategies, iterations, event references, and wrong report links block selection', async context => {
  for (const mutation of ['report', 'strategy', 'iteration', 'event', 'link', 'missing-strategy', 'fewer', 'extra']) {
    const data = await fixture(context);
    const entry = data.annotations.strategies[1];
    if (mutation === 'report') data.reliabilityPaths[2] = data.reliabilityPaths[1];
    if (mutation === 'strategy') data.annotations.strategies[2] = clone(entry);
    if (mutation === 'iteration') entry.observations[1].iteration = 1;
    if (mutation === 'event') entry.observations[1] = { ...clone(entry.observations[0]), iteration: 2 };
    if (mutation === 'link') entry.reliabilityReport = data.annotations.strategies[0].reliabilityReport;
    if (mutation === 'missing-strategy') data.annotations.strategies.pop();
    if (mutation === 'fewer') entry.observations.pop();
    if (mutation === 'extra') entry.observations.push(clone(entry.observations[0]));
    if (mutation !== 'report') await data.save();
    const result = await data.run();
    assertRetained(result);
    assert.equal(result.evidenceComplete, false, mutation);
  }
});

test('review identity, timestamp, schema, and unsupported fields are required', async context => {
  const mutations = [
    value => { value.schemaVersion = 2; },
    value => { value.review.method = 'automated-pixel-analysis'; },
    value => { value.review.reviewedBy = ''; },
    value => { value.review.reviewedAt = '2026-09-04T09:00:00Z'; },
    value => { value.review.reviewedAt = '2026-09-04'; },
    value => { value.unknown = true; },
    value => { delete value.review; },
  ];
  for (const mutate of mutations) {
    const data = await fixture(context);
    mutate(data.annotations);
    await data.save();
    assertRetained(await data.run());
  }
});

test('observation validation rejects nonfinite numbers and invalid timestamps or frame coverage', () => {
  const original = syntheticObservations(strategies[1], 'a'.repeat(64))[0];
  assert.deepEqual(validateObservation(original), []);
  const mutations = [
    value => { value.restartRequestSeconds = NaN; },
    value => { value.restartRequestSeconds = Infinity; },
    value => { value.restartRequestSeconds = 'NaN'; },
    value => { value.restartRequestSeconds = null; },
    value => { value.restartRequestSeconds = -1; },
    value => { value.firstReturningDockPixelSeconds = 0.9; },
    value => { value.settledDockSeconds = 1.1; },
    value => { value.frameRate = 0; },
    value => { value.frameRate = Infinity; },
    value => { value.frameRate = Number.MIN_VALUE; },
    value => { value.frameCount = 1; },
    value => { value.frameCount = 1000.5; },
    value => { value.inspectedFrameRange.first = 1010; },
    value => { value.inspectedFrameRange.last = 1100; },
    value => { value.inspectedFrameRange.first = -1; },
    value => { value.inspectedFrameRange.last = value.frameCount; },
    value => { value.inspectedFrameRange = null; },
    value => { value.wallpaperBlackouts[0].endSeconds = 1.005; },
    value => { value.wallpaperBlackouts[0].startSeconds = 0; },
    value => { value.wallpaperBlackouts[0].endSeconds = 1.7; },
    value => { value.wallpaperBlackouts.push({ startSeconds: 1.1, endSeconds: 1.4 }); },
    value => { value.wallpaperBlackouts[0].startSeconds = NaN; },
    value => { value.uncertaintyFrames = 0; },
    value => { value.uncertaintyFrames = 0.5; },
    value => { value.uncertaintyFrames = Infinity; },
    value => { value.frameRate = 1e-300; value.uncertaintyFrames = Number.MAX_SAFE_INTEGER; },
    value => { value.observedExtraRestartCycles = 1; },
    value => { value.observedExtraRestartCycles = false; },
    value => { value.recordingSha256 = 'invalid'; },
    value => { value.recording = ''; },
    value => { value.iteration = 21; },
    value => { value.extra = true; },
  ];
  for (const [index, mutate] of mutations.entries()) {
    const observation = clone(original);
    mutate(observation);
    assert(validateObservation(observation).length > 0, `observation mutation ${index} was accepted`);
  }
});

test('observed no blackout is measured zero, while missing false and null are not', async context => {
  const data = await fixture(context);
  for (const observation of data.annotations.strategies[1].observations) observation.wallpaperBlackouts = [];
  await data.save();
  const measured = await data.run();
  assert.equal(measured.evidenceComplete, true, messages(measured));
  assert.equal(measured.strategies[1].metrics.wallpaperBlackout.median.point, 0);
  assert.equal(measured.strategies[1].metrics.wallpaperBlackout.median.upper, 1);
  for (const value of [undefined, false, null]) {
    data.annotations.strategies[1].observations[0].wallpaperBlackouts = value;
    await data.save();
    const unmeasured = await data.run();
    assertRetained(unmeasured);
    assert.equal(unmeasured.strategies[1].metrics, null);
  }
});

test('overflowing json numeric literals cannot become measured evidence', async context => {
  const data = await fixture(context);
  const text = JSON.stringify(data.annotations).replace('"frameRate":1000', '"frameRate":1e999');
  await writeFile(data.annotationsPath, text);
  const result = await data.run();
  assertRetained(result);
  assert.match(messages(result), /finite frames per second/);
});

test('copied clips cannot be reused as independent switch evidence', async context => {
  const data = await fixture(context);
  const original = data.annotations.strategies[0].observations[0];
  const copiedPath = join(data.directory, 'copied-synthetic-recording.bin');
  await writeFile(copiedPath, await readFile(join(data.directory, original.recording)));
  data.annotations.strategies[1].observations = clone(data.annotations.strategies[0].observations).map(item => ({ ...item, recording: copiedPath }));
  await data.save();
  const result = await data.run();
  assertRetained(result);
  assert.match(messages(result), /duplicates or overlaps/);
});

test('recording metadata must agree and switch numbers must match event chronology', async context => {
  for (const mutation of ['frame-rate', 'frame-count', 'chronology']) {
    const data = await fixture(context);
    const observations = data.annotations.strategies[1].observations;
    if (mutation === 'frame-rate') {
      observations[1].frameRate = 2000;
      observations[1].inspectedFrameRange.first *= 2;
      observations[1].inspectedFrameRange.last *= 2;
    }
    if (mutation === 'frame-count') observations[1].frameCount++;
    if (mutation === 'chronology') [observations[0].iteration, observations[1].iteration] = [2, 1];
    await data.save();
    const result = await data.run();
    assertRetained(result);
    assert.match(messages(result), /consistent frame rate and frame count|chronological order/);
  }
});

test('malformed reliability reports cannot qualify through existing annotations', async context => {
  const data = await fixture(context);
  for (const text of ['{', 'null', '{"strategy":"forcedTermination","gatePassed":true,"gatePassed":false}', JSON.stringify(data.reports[0]).replace('"elapsedMilliseconds":1200', '"elapsedMilliseconds":1e999')]) {
    await writeFile(data.reliabilityPaths[0], text);
    const result = await data.run();
    assertRetained(result);
    assert.equal(result.evidenceComplete, false);
  }
});

test('median and nearest-rank p95 keep blackout, return, and settling separate', () => {
  const observations = syntheticObservations(strategies[1], 'a'.repeat(64));
  for (const [index, observation] of observations.entries()) {
    const start = observation.restartRequestSeconds;
    observation.wallpaperBlackouts = [{ startSeconds: start, endSeconds: start + (index + 1) / 1000 }];
    observation.firstReturningDockPixelSeconds = start + (index + 1) / 100;
    observation.settledDockSeconds = start + (index + 1) / 10;
  }
  const metrics = summarizeObservations(observations);
  assert(Math.abs(metrics.wallpaperBlackout.median.point - 10.5) < 1e-8);
  assert(Math.abs(metrics.wallpaperBlackout.p95.point - 19) < 1e-8);
  assert(Math.abs(metrics.firstReturnDelay.median.point - 105) < 1e-8);
  assert(Math.abs(metrics.firstReturnDelay.p95.point - 190) < 1e-8);
  assert(Math.abs(metrics.settlingDelay.median.point - 1050) < 1e-8);
  assert(Math.abs(metrics.settlingDelay.p95.point - 1900) < 1e-8);
});

test('multiple blackout intervals add their durations and endpoint uncertainty', () => {
  const observations = syntheticObservations(strategies[1], 'a'.repeat(64));
  for (const observation of observations) {
    const start = observation.restartRequestSeconds;
    observation.wallpaperBlackouts = [{ startSeconds: start, endSeconds: start + 0.1 }, { startSeconds: start + 0.2, endSeconds: start + 0.3 }];
  }
  const value = summarizeObservations(observations).wallpaperBlackout.median;
  assert(Math.abs(value.point - 200) < 1e-8);
  assert(Math.abs(value.lower - 196) < 1e-8);
  assert(Math.abs(value.upper - 204) < 1e-8);
});

function metric(point, error = 0) {
  const bounds = { point, lower: Math.max(0, point - error), upper: point + error };
  return { median: clone(bounds), p95: clone(bounds) };
}

test('threshold gates use conservative bounds with inclusive median and strict p95', () => {
  const baseline = { wallpaperBlackout: metric(360), firstReturnDelay: metric(650, 10), settlingDelay: metric(1000, 10) };
  const candidate = { wallpaperBlackout: metric(278, 2), firstReturnDelay: metric(400, 10), settlingDelay: metric(600, 10) };
  candidate.wallpaperBlackout.p95 = { point: 448, lower: 447, upper: 449 };
  assert(compareCandidate(candidate, baseline).every(gate => gate.verdict === 'passed'));
  candidate.wallpaperBlackout.p95.upper = 450;
  assert.equal(compareCandidate(candidate, baseline)[1].verdict, 'inconclusive');
  candidate.wallpaperBlackout.p95 = { point: 451, lower: 450, upper: 452 };
  assert.equal(compareCandidate(candidate, baseline)[1].verdict, 'failed');
  candidate.wallpaperBlackout.median = { point: 280, lower: 278, upper: 282 };
  assert.equal(compareCandidate(candidate, baseline)[0].verdict, 'inconclusive');
  candidate.wallpaperBlackout.median = { point: 284, lower: 282, upper: 286 };
  assert.equal(compareCandidate(candidate, baseline)[0].verdict, 'failed');
});

test('return and settling regressions fail while overlapping uncertainty stays inconclusive', () => {
  const baseline = { wallpaperBlackout: metric(360), firstReturnDelay: metric(650, 10), settlingDelay: metric(1000, 10) };
  const candidate = { wallpaperBlackout: metric(200, 2), firstReturnDelay: metric(645, 10), settlingDelay: metric(1100, 10) };
  let gates = compareCandidate(candidate, baseline);
  assert.equal(gates[2].pointEstimateComparison, 'lower');
  assert.equal(gates[2].verdict, 'inconclusive');
  assert.equal(gates[4].pointEstimateComparison, 'higher');
  assert.equal(gates[4].verdict, 'failed');
  candidate.firstReturnDelay = metric(630, 10);
  candidate.settlingDelay = metric(980, 10);
  gates = compareCandidate(candidate, baseline);
  assert(gates.every(gate => gate.verdict === 'passed'));
});

test('measured but uncertain timing retains baseline without claiming evidence is missing', async context => {
  const data = await fixture(context);
  for (const entry of data.annotations.strategies.slice(1)) {
    for (const observation of entry.observations) {
      observation.firstReturningDockPixelSeconds = observation.restartRequestSeconds + 0.649;
      observation.settledDockSeconds = observation.restartRequestSeconds + 1;
      observation.inspectedFrameRange.last = Math.ceil(observation.settledDockSeconds * 1000) + 2;
    }
  }
  await data.save();
  const result = await data.run();
  assertRetained(result);
  assert.equal(result.evidenceComplete, true, messages(result));
  assert(result.strategies[1].timingGates.some(gate => gate.verdict === 'inconclusive'));
});
