import { createHash } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { readFile, realpath, stat } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const strategies = [
  'forcedTermination',
  'gracefulTerminationWithForcedFallback',
  'forcedTerminationAndExplicitRelaunch',
];
const restoredMarker = 'DOCKIT_BENCHMARK_RECOVERY_RESTORED';
const runtimeRationale = 'The Dock updates this mutation counter while saving preferences. It is not a user setting.';
const observationKeys = [
  'iteration', 'recording', 'recordingSha256', 'frameRate', 'frameCount',
  'inspectedFrameRange', 'restartRequestSeconds', 'wallpaperBlackouts',
  'firstReturningDockPixelSeconds', 'settledDockSeconds', 'uncertaintyFrames',
  'observedExtraRestartCycles',
];

const isObject = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const isText = value => typeof value === 'string' && value.trim().length > 0;
const isNumber = value => typeof value === 'number' && Number.isFinite(value) && value >= 0;
const isInteger = value => Number.isSafeInteger(value) && value >= 0;
const isPID = value => isInteger(value) && value > 0 && value <= 2_147_483_647;
const isEmpty = value => Array.isArray(value) && value.length === 0;
const equal = (left, right) => JSON.stringify(left) === JSON.stringify(right);
const compare = (left, right) => left < right ? -1 : left > right ? 1 : 0;

function check(issues, condition, path, message) {
  if (!condition) issues.push({ path, message });
  return condition;
}

function shape(value, required, optional, issues, path) {
  if (!check(issues, isObject(value), path, 'must be an object')) return false;
  for (const key of required) check(issues, Object.hasOwn(value, key), `${path}.${key}`, 'is required');
  const allowed = new Set([...required, ...optional]);
  for (const key of Object.keys(value)) check(issues, allowed.has(key), `${path}.${key}`, 'is not a recognized field');
  return true;
}

function dateMilliseconds(value) {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/.test(value)) return NaN;
  const [year, month, day, hour, minute, second] = value.slice(0, 19).split(/\D/).map(Number);
  const leapYear = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
  const days = [31, leapYear ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  if (month < 1 || month > 12 || day < 1 || day > days[month - 1] || hour > 23 || minute > 59 || second > 59) return NaN;
  return Date.parse(value);
}

export function parseJSON(text) {
  const parsed = JSON.parse(text);
  const tokens = text.match(/"(?:\\.|[^"\\])*"|[{}\[\]:,]|-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?|true|false|null/g) ?? [];
  const stack = [];
  for (const token of tokens) {
    const context = stack.at(-1);
    if (token === '{') stack.push({ keys: new Set(), expectsKey: true });
    else if (token === '[') stack.push(null);
    else if (token === '}' || token === ']') stack.pop();
    else if (token === ',' && context) context.expectsKey = true;
    else if (token.startsWith('"') && context?.expectsKey) {
      const key = JSON.parse(token);
      if (context.keys.has(key)) throw new Error('duplicate json field');
      context.keys.add(key);
      context.expectsKey = false;
    }
  }
  return parsed;
}

async function readJSON(path, issues) {
  try {
    const info = await stat(path);
    if (!info.isFile() || info.size === 0 || info.size > 4 * 1024 * 1024) throw new Error('invalid file');
    return parseJSON(await readFile(path, 'utf8'));
  } catch {
    issues.push({ path, message: 'could not read a nonempty json file without syntax errors or duplicate fields (maximum 4 mib)' });
    return null;
  }
}

async function evidenceFile(path, issues, label) {
  try {
    const canonicalPath = await realpath(path);
    const info = await stat(canonicalPath);
    if (!info.isFile() || info.size === 0) throw new Error('invalid file');
    return canonicalPath;
  } catch {
    issues.push({ path: label, message: 'evidence must reference an existing nonempty regular file' });
    return null;
  }
}

async function sha256(path) {
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(path)) hash.update(chunk);
  return hash.digest('hex');
}

function identities(value, kind, issues, path) {
  if (!check(issues, Array.isArray(value), path, 'must be an array of raw preservation evidence')) return null;
  const keys = kind === 'apps' ? ['bundleIdentifier', 'processIdentifier'] : ['ownerProcessIdentifier', 'windowNumber', 'layer', 'bounds'];
  const before = issues.length;
  for (const [index, item] of value.entries()) {
    const itemPath = `${path}[${index}]`;
    if (!shape(item, keys, [], issues, itemPath)) continue;
    if (kind === 'apps') {
      check(issues, isText(item.bundleIdentifier), `${itemPath}.bundleIdentifier`, 'must be nonempty text');
      check(issues, isPID(item.processIdentifier), `${itemPath}.processIdentifier`, 'must be a positive process identifier');
    } else {
      check(issues, isPID(item.ownerProcessIdentifier), `${itemPath}.ownerProcessIdentifier`, 'must be a positive process identifier');
      check(issues, isInteger(item.windowNumber), `${itemPath}.windowNumber`, 'must be a nonnegative integer');
      check(issues, Number.isSafeInteger(item.layer), `${itemPath}.layer`, 'must be an integer');
      check(issues, isText(item.bounds), `${itemPath}.bounds`, 'must be nonempty text');
    }
  }
  if (issues.length !== before) return null;
  const normalized = value.map(item => keys.map(key => item[key]));
  const canonical = [...normalized].sort((left, right) => {
    for (let index = 0; index < keys.length; index++) {
      const result = compare(left[index], right[index]);
      if (result) return result;
    }
    return 0;
  });
  check(issues, equal(normalized, canonical) && new Set(normalized.map(JSON.stringify)).size === normalized.length,
    path, 'must be sorted and contain no duplicate identities');
  return normalized;
}

function reloadEvent(value, strategy, previousPID, issues, path) {
  if (!shape(value, ['previousProcessIdentifier', 'currentProcessIdentifier', 'strategy', 'usedForcedFallback'], [], issues, path)) return null;
  check(issues, value.strategy === strategy, `${path}.strategy`, 'does not match the expected strategy');
  check(issues, isPID(value.previousProcessIdentifier) && isPID(value.currentProcessIdentifier)
    && value.previousProcessIdentifier !== value.currentProcessIdentifier, path, 'must contain distinct positive process identifiers');
  check(issues, value.previousProcessIdentifier === previousPID, path, 'has a discontinuous process sequence');
  check(issues, typeof value.usedForcedFallback === 'boolean'
    && (strategy === strategies[1] || value.usedForcedFallback === false), `${path}.usedForcedFallback`, 'has an invalid forced fallback flag');
  return value.currentProcessIdentifier;
}

export function validateReliability(report, path = 'reliability') {
  const issues = [];
  const required = [
    'schemaVersion', 'startedAt', 'finishedAt', 'strategy', 'requiredSwitchCount', 'requestedSwitchCount',
    'backupPath', 'recoveryMarkerPath', 'ignoredRuntimeKeys', 'ignoredRuntimeKeyRationales',
    'baselineDockProcessIdentifier', 'baselineRegularApps', 'baselineWindowRecords', 'switches',
    'finalNonPinnedPreferenceChangedKeys', 'finalRegularApps', 'finalRegularAppsPreserved', 'finalWindowRecords',
    'finalWindows', 'restorationReload', 'recoveryMarkerState', 'restoredOriginal', 'gatePassed',
  ];
  if (!shape(report, required, ['failure'], issues, path)) return issues;
  check(issues, report.schemaVersion === 2, `${path}.schemaVersion`, 'must be 2');
  check(issues, strategies.includes(report.strategy), `${path}.strategy`, 'must identify a supported strategy');
  check(issues, report.requiredSwitchCount === 20 && report.requestedSwitchCount === 20, path, 'must require and request exactly 20 switches');
  const start = dateMilliseconds(report.startedAt);
  const finish = dateMilliseconds(report.finishedAt);
  check(issues, Number.isFinite(start) && Number.isFinite(finish) && finish >= start, path, 'must have ordered iso 8601 start and finish timestamps');
  for (const key of ['backupPath', 'recoveryMarkerPath']) check(issues, isText(report[key]), `${path}.${key}`, 'must be a nonempty file reference');
  check(issues, equal(report.ignoredRuntimeKeys, ['mod-count']), `${path}.ignoredRuntimeKeys`, 'must declare only the approved runtime key');
  check(issues, Array.isArray(report.ignoredRuntimeKeyRationales) && report.ignoredRuntimeKeyRationales.length === 1
    && report.ignoredRuntimeKeyRationales[0]?.key === 'mod-count'
    && report.ignoredRuntimeKeyRationales[0]?.rationale === runtimeRationale,
  `${path}.ignoredRuntimeKeyRationales`, 'must contain the approved runtime-key rationale');
  check(issues, isPID(report.baselineDockProcessIdentifier), `${path}.baselineDockProcessIdentifier`, 'must be a positive process identifier');
  const baselineApps = identities(report.baselineRegularApps, 'apps', issues, `${path}.baselineRegularApps`);
  const baselineWindows = identities(report.baselineWindowRecords, 'windows', issues, `${path}.baselineWindowRecords`);
  check(issues, baselineApps !== null && baselineWindows !== null && (baselineApps.length === 0 || baselineWindows.length > 0), path, 'must include usable raw window evidence');
  const switches = Array.isArray(report.switches) ? report.switches : [];
  check(issues, switches.length === 20, `${path}.switches`, 'must contain exactly 20 switches');
  const firstProfile = switches[0]?.profileName;
  const secondProfile = switches[1]?.profileName;
  check(issues, isText(firstProfile) && isText(secondProfile) && firstProfile !== secondProfile
    && switches.every((item, index) => item?.profileName === (index % 2 === 0 ? firstProfile : secondProfile)),
  `${path}.switches`, 'must alternate between two distinct fixture profiles');
  let previousPID = report.baselineDockProcessIdentifier;
  for (const [index, item] of switches.entries()) {
    const itemPath = `${path}.switches[${index}]`;
    if (!shape(item, ['iteration', 'profileName', 'elapsedMilliseconds', 'reload', 'skippedApps', 'nonPinnedPreferenceChangedKeys', 'regularApps', 'regularAppsPreserved', 'windowRecords', 'windows'], ['failure'], issues, itemPath)) continue;
    check(issues, item.iteration === index + 1, `${itemPath}.iteration`, 'must be the complete ordered sequence 1 through 20');
    check(issues, isText(item.profileName), `${itemPath}.profileName`, 'must be nonempty text');
    check(issues, isNumber(item.elapsedMilliseconds), `${itemPath}.elapsedMilliseconds`, 'must be finite nonnegative milliseconds');
    previousPID = reloadEvent(item.reload, report.strategy, previousPID, issues, `${itemPath}.reload`);
    check(issues, isEmpty(item.skippedApps), `${itemPath}.skippedApps`, 'must contain no skipped apps');
    check(issues, isEmpty(item.nonPinnedPreferenceChangedKeys), `${itemPath}.nonPinnedPreferenceChangedKeys`, 'must contain no changed non-pinned preferences');
    check(issues, item.regularAppsPreserved === true, `${itemPath}.regularAppsPreserved`, 'must confirm preservation');
    check(issues, equal(identities(item.regularApps, 'apps', issues, `${itemPath}.regularApps`), baselineApps), itemPath, 'regular-app evidence differs from the baseline');
    check(issues, equal(identities(item.windowRecords, 'windows', issues, `${itemPath}.windowRecords`), baselineWindows), itemPath, 'window evidence differs from the baseline');
    check(issues, item.windows === 'preserved', `${itemPath}.windows`, 'must confirm window preservation');
    check(issues, item.failure === undefined || item.failure === null, `${itemPath}.failure`, 'must not report a failure');
  }
  check(issues, isEmpty(report.finalNonPinnedPreferenceChangedKeys), `${path}.finalNonPinnedPreferenceChangedKeys`, 'must contain no changed non-pinned preferences');
  check(issues, report.finalRegularAppsPreserved === true, `${path}.finalRegularAppsPreserved`, 'must confirm preservation');
  check(issues, equal(identities(report.finalRegularApps, 'apps', issues, `${path}.finalRegularApps`), baselineApps), path, 'final regular-app evidence differs from the baseline');
  check(issues, equal(identities(report.finalWindowRecords, 'windows', issues, `${path}.finalWindowRecords`), baselineWindows), path, 'final window evidence differs from the baseline');
  check(issues, report.finalWindows === 'preserved', `${path}.finalWindows`, 'must confirm window preservation');
  reloadEvent(report.restorationReload, strategies[0], previousPID, issues, `${path}.restorationReload`);
  check(issues, report.recoveryMarkerState === restoredMarker, `${path}.recoveryMarkerState`, 'must confirm completed restoration');
  check(issues, report.restoredOriginal === true && report.gatePassed === true, path, 'must confirm restoration and a passed reliability gate');
  check(issues, report.failure === undefined || report.failure === null, `${path}.failure`, 'must not report a failure');
  return issues;
}

export function validateObservation(observation, path = 'observation') {
  const issues = [];
  if (!shape(observation, observationKeys, [], issues, path)) return issues;
  check(issues, isInteger(observation.iteration) && observation.iteration >= 1 && observation.iteration <= 20, `${path}.iteration`, 'must be an integer from 1 through 20');
  check(issues, isText(observation.recording), `${path}.recording`, 'must be a nonempty recording reference');
  check(issues, typeof observation.recordingSha256 === 'string' && /^[a-f0-9]{64}$/.test(observation.recordingSha256), `${path}.recordingSha256`, 'must be the recording sha256 in lowercase hexadecimal');
  const validRate = check(issues, isNumber(observation.frameRate) && observation.frameRate > 0, `${path}.frameRate`, 'must be finite frames per second greater than zero');
  const validCount = check(issues, isInteger(observation.frameCount) && observation.frameCount > 0, `${path}.frameCount`, 'must be a positive integer');
  check(issues, isInteger(observation.uncertaintyFrames) && observation.uncertaintyFrames >= 1, `${path}.uncertaintyFrames`, 'must declare at least one whole frame of uncertainty per endpoint');
  if (validRate) check(issues, Number.isFinite(1000 / observation.frameRate)
    && Number.isFinite(observation.uncertaintyFrames / observation.frameRate * 2000),
  path, 'frame resolution and endpoint uncertainty must be finite in milliseconds');
  check(issues, observation.observedExtraRestartCycles === 0, `${path}.observedExtraRestartCycles`, 'must explicitly report zero extra restart cycles');
  const timeKeys = ['restartRequestSeconds', 'firstReturningDockPixelSeconds', 'settledDockSeconds'];
  for (const key of timeKeys) check(issues, isNumber(observation[key]), `${path}.${key}`, 'must be finite nonnegative recording seconds');
  const validTimes = timeKeys.every(key => isNumber(observation[key]));
  const request = observation.restartRequestSeconds;
  const returned = observation.firstReturningDockPixelSeconds;
  const settled = observation.settledDockSeconds;
  if (validTimes) check(issues, request <= returned && returned <= settled, path, 'must order restart request, first returning dock pixel, and settled dock timestamps');
  if (validTimes) check(issues, Number.isFinite(settled * 1000), path, 'timestamps must remain finite when converted to milliseconds');
  if (shape(observation.inspectedFrameRange, ['first', 'last'], [], issues, `${path}.inspectedFrameRange`)) {
    const { first, last } = observation.inspectedFrameRange;
    const validRange = check(issues, isInteger(first) && isInteger(last) && first <= last && validCount && last < observation.frameCount,
      `${path}.inspectedFrameRange`, 'must be an inclusive ordered range of recording frame indices');
    if (validRate && validRange && validTimes) {
      check(issues, first / observation.frameRate <= request && settled <= last / observation.frameRate,
        `${path}.inspectedFrameRange`, 'must cover the entire event from restart request through settled dock');
    }
  }
  if (validRate && validCount && validTimes) check(issues, settled <= (observation.frameCount - 1) / observation.frameRate,
    path, 'timestamps extend beyond the recording frame count');
  if (check(issues, Array.isArray(observation.wallpaperBlackouts), `${path}.wallpaperBlackouts`, 'must be a reviewed interval array; an empty array means observed no blackout')) {
    if (validRate) check(issues, Number.isFinite(observation.uncertaintyFrames / observation.frameRate * 2000
      * Math.max(1, observation.wallpaperBlackouts.length)), path, 'combined blackout uncertainty must remain finite in milliseconds');
    let previousEnd = request;
    for (const [index, interval] of observation.wallpaperBlackouts.entries()) {
      const intervalPath = `${path}.wallpaperBlackouts[${index}]`;
      if (!shape(interval, ['startSeconds', 'endSeconds'], [], issues, intervalPath)) continue;
      check(issues, isNumber(interval.startSeconds) && isNumber(interval.endSeconds)
        && interval.startSeconds >= previousEnd && interval.startSeconds < interval.endSeconds
        && interval.endSeconds <= settled, intervalPath, 'must be finite positive-duration intervals, ordered without overlap, within the observed event');
      previousEnd = interval.endSeconds;
    }
  }
  return issues;
}

export function summarizeObservations(observations) {
  const measurements = { wallpaperBlackout: [], firstReturnDelay: [], settlingDelay: [] };
  for (const item of observations) {
    const endpointError = item.uncertaintyFrames / item.frameRate * 1000;
    const blackout = item.wallpaperBlackouts.reduce((sum, interval) => sum + interval.endSeconds - interval.startSeconds, 0) * 1000;
    const blackoutError = endpointError * Math.max(1, 2 * item.wallpaperBlackouts.length);
    for (const [key, point, error] of [
      ['wallpaperBlackout', blackout, blackoutError],
      ['firstReturnDelay', (item.firstReturningDockPixelSeconds - item.restartRequestSeconds) * 1000, 2 * endpointError],
      ['settlingDelay', (item.settledDockSeconds - item.restartRequestSeconds) * 1000, 2 * endpointError],
    ]) measurements[key].push({ point, lower: Math.max(0, point - error), upper: point + error });
  }
  const median = values => (values[(values.length - 1) >> 1] + values[values.length >> 1]) / 2;
  const p95 = values => values[Math.ceil(0.95 * values.length) - 1];
  const metrics = {};
  for (const [key, values] of Object.entries(measurements)) {
    metrics[key] = {};
    for (const [statistic, aggregate] of [['median', median], ['p95', p95]]) {
      metrics[key][statistic] = {};
      for (const bound of ['point', 'lower', 'upper']) {
        metrics[key][statistic][bound] = aggregate(values.map(value => value[bound]).sort((a, b) => a - b));
      }
    }
  }
  return metrics;
}

function absoluteGate(value, limit, strict) {
  if (strict ? value.upper < limit : value.upper <= limit) return 'passed';
  if (strict ? value.lower >= limit : value.lower > limit) return 'failed';
  return 'inconclusive';
}

export function compareCandidate(candidate, baseline) {
  const gates = [
    { metric: 'wallpaperBlackout', statistic: 'median', requirement: 'upper bound at most 280 ms', verdict: absoluteGate(candidate.wallpaperBlackout.median, 280, false) },
    { metric: 'wallpaperBlackout', statistic: 'p95', requirement: 'upper bound below 450 ms', verdict: absoluteGate(candidate.wallpaperBlackout.p95, 450, true) },
  ];
  for (const metric of ['firstReturnDelay', 'settlingDelay']) {
    for (const statistic of ['median', 'p95']) {
      const value = candidate[metric][statistic];
      const reference = baseline[metric][statistic];
      gates.push({
        metric, statistic, requirement: 'candidate upper bound at most baseline lower bound',
        pointEstimateComparison: value.point < reference.point ? 'lower' : value.point > reference.point ? 'higher' : 'equal',
        verdict: value.upper <= reference.lower ? 'passed' : value.lower > reference.upper ? 'failed' : 'inconclusive',
      });
    }
  }
  return gates;
}

export async function analyzeDockTiming({ reliabilityPaths, annotationsPath }) {
  const issues = [];
  const report = {
    schemaVersion: 1,
    baselineStrategy: strategies[0],
    recommendedStrategy: strategies[0],
    recommendation: 'retain baseline',
    evidenceComplete: false,
    pixelAnalysisPerformed: false,
    evidenceMethod: 'manual frame annotations; recording contents and metadata are not decoded by this evaluator',
    units: 'milliseconds',
    uncertaintyMethod: 'each timestamp endpoint has uncertaintyFrames / frameRate seconds of error; interval errors add; observed no blackout has one endpoint-error upper bound',
    percentileMethod: 'nearest rank (the 19th sorted observation for 20 switches)',
    issues,
    strategies: [],
  };
  if (!check(issues, Array.isArray(reliabilityPaths) && reliabilityPaths.length === 3 && reliabilityPaths.every(isText), 'reliabilityPaths', 'provide exactly three reliability report paths')
    || !check(issues, isText(annotationsPath), 'annotationsPath', 'provide the reviewed frame-annotation json path')) return report;
  const annotationFile = resolve(annotationsPath);
  const annotations = await readJSON(annotationFile, issues);
  if (!shape(annotations, ['schemaVersion', 'review', 'strategies'], [], issues, annotationFile)) return report;
  check(issues, annotations.schemaVersion === 1, `${annotationFile}.schemaVersion`, 'must be 1');
  let reviewedAt = NaN;
  if (shape(annotations.review, ['method', 'reviewedBy', 'reviewedAt'], [], issues, `${annotationFile}.review`)) {
    check(issues, annotations.review.method === 'manual-frame-review', `${annotationFile}.review.method`, 'must identify manual frame review');
    check(issues, isText(annotations.review.reviewedBy), `${annotationFile}.review.reviewedBy`, 'must identify the reviewer');
    reviewedAt = dateMilliseconds(annotations.review.reviewedAt);
    check(issues, Number.isFinite(reviewedAt), `${annotationFile}.review.reviewedAt`, 'must be an iso 8601 timestamp with a timezone');
  }
  report.review = annotations.review;
  const entries = Array.isArray(annotations.strategies) ? annotations.strategies : [];
  check(issues, entries.length === 3, `${annotationFile}.strategies`, 'must contain exactly three strategy entries');
  const entryMap = new Map();
  for (const [index, entry] of entries.entries()) {
    const path = `${annotationFile}.strategies[${index}]`;
    if (!shape(entry, ['strategy', 'reliabilityReport', 'observations'], [], issues, path)) continue;
    check(issues, strategies.includes(entry.strategy) && !entryMap.has(entry.strategy), `${path}.strategy`, 'must be a unique supported strategy');
    check(issues, isText(entry.reliabilityReport), `${path}.reliabilityReport`, 'must reference the corresponding reliability report');
    if (!entryMap.has(entry.strategy)) entryMap.set(entry.strategy, entry);
  }
  const reliabilityMap = new Map();
  const reportPaths = new Set();
  for (const inputPath of reliabilityPaths) {
    const path = resolve(inputPath);
    const canonicalPath = await evidenceFile(path, issues, path);
    if (!canonicalPath) continue;
    check(issues, !reportPaths.has(canonicalPath), path, 'must not repeat a reliability report');
    reportPaths.add(canonicalPath);
    const value = await readJSON(path, issues);
    if (!value) continue;
    const reliabilityIssues = validateReliability(value, path);
    if (!check(issues, strategies.includes(value.strategy) && !reliabilityMap.has(value.strategy), path, 'must contain a unique supported strategy report')) continue;
    for (const key of ['backupPath', 'recoveryMarkerPath']) {
      if (isText(value[key])) {
        const file = await evidenceFile(resolve(dirname(path), value[key]), reliabilityIssues, `${path}.${key}`);
        if (file && key === 'recoveryMarkerPath') {
          const marker = await readFile(file, 'utf8').catch(() => null);
          check(reliabilityIssues, marker === `${restoredMarker}\n` || marker === restoredMarker, `${path}.${key}`, 'recovery marker file must confirm completed restoration');
        }
      }
    }
    const digest = await sha256(canonicalPath).catch(() => null);
    check(reliabilityIssues, digest !== null, path, 'could not hash the reliability evidence');
    reliabilityMap.set(value.strategy, { path: canonicalPath, value, digest, issues: reliabilityIssues });
  }
  const hashes = new Map();
  const recordingMetadata = new Map();
  const events = new Map();
  for (const strategy of strategies) {
    const localIssues = [];
    const entry = entryMap.get(strategy);
    const reliability = reliabilityMap.get(strategy);
    const result = { strategy, reliabilityPassed: false, visualEvidenceComplete: false, observations: 0, issues: localIssues, metrics: null, timingGates: [], eligible: false };
    report.strategies.push(result);
    if (!check(localIssues, reliability !== undefined, strategy, 'reliability report is missing')) continue;
    localIssues.push(...reliability.issues);
    result.reliabilityPassed = reliability.issues.length === 0;
    result.reliabilityReport = reliability.path;
    result.reliabilityReportSha256 = reliability.digest;
    if (!check(localIssues, entry !== undefined, strategy, 'reviewed frame annotations are missing')) continue;
    const visualStart = localIssues.length;
    if (isText(entry.reliabilityReport)) {
      const linked = await evidenceFile(resolve(dirname(annotationFile), entry.reliabilityReport), localIssues, `${strategy}.reliabilityReport`);
      check(localIssues, linked === reliability.path, `${strategy}.reliabilityReport`, 'must reference the exact supplied reliability report');
    } else check(localIssues, false, `${strategy}.reliabilityReport`, 'must reference the exact supplied reliability report');
    check(localIssues, Number.isFinite(reviewedAt) && reviewedAt >= dateMilliseconds(reliability.value.finishedAt), strategy, 'frame review must be dated at or after the reliability run finished');
    const observations = Array.isArray(entry.observations) ? entry.observations : [];
    result.observations = observations.length;
    check(localIssues, observations.length === 20, `${strategy}.observations`, 'must contain exactly 20 reviewed switch observations');
    const iterations = new Set();
    for (const [index, observation] of observations.entries()) {
      const path = `${strategy}.observations[${index}]`;
      const observationIssues = validateObservation(observation, path);
      localIssues.push(...observationIssues);
      if (!isObject(observation)) continue;
      check(localIssues, !iterations.has(observation.iteration), `${path}.iteration`, 'must not repeat a switch number');
      iterations.add(observation.iteration);
      if (observationIssues.length !== 0) continue;
      const recording = await evidenceFile(resolve(dirname(annotationFile), observation.recording), localIssues, `${path}.recording`);
      if (!recording) continue;
      if (!hashes.has(recording)) hashes.set(recording, await sha256(recording).catch(() => null));
      const digest = hashes.get(recording);
      if (!check(localIssues, digest === observation.recordingSha256, `${path}.recordingSha256`, 'does not match the recording evidence')) continue;
      const metadata = { frameRate: observation.frameRate, frameCount: observation.frameCount };
      if (recordingMetadata.has(digest)) check(localIssues, equal(recordingMetadata.get(digest), metadata), path, 'the same recording content must have consistent frame rate and frame count');
      else recordingMetadata.set(digest, metadata);
      const seenEvents = events.get(digest) ?? [];
      const overlapping = seenEvents.some(event => observation.restartRequestSeconds <= event.end && observation.settledDockSeconds >= event.start);
      check(localIssues, !overlapping, path, 'duplicates or overlaps another annotated switch event in the same recording content');
      check(localIssues, seenEvents.every(event => event.strategy !== strategy
        || (observation.iteration > event.iteration ? observation.restartRequestSeconds > event.start : observation.restartRequestSeconds < event.start)),
      path, 'switch numbers must follow chronological order within a strategy recording');
      seenEvents.push({ strategy, iteration: observation.iteration, start: observation.restartRequestSeconds, end: observation.settledDockSeconds });
      events.set(digest, seenEvents);
    }
    check(localIssues, iterations.size === 20 && Array.from({ length: 20 }, (_, index) => index + 1).every(number => iterations.has(number)), strategy, 'review must cover every switch number from 1 through 20');
    result.visualEvidenceComplete = localIssues.length === visualStart;
    if (result.visualEvidenceComplete) result.metrics = summarizeObservations(observations);
  }
  report.evidenceComplete = issues.length === 0 && report.strategies.every(result => result.reliabilityPassed && result.visualEvidenceComplete);
  const baseline = report.strategies[0];
  for (const result of report.strategies.slice(1)) {
    if (result.metrics && baseline.metrics) result.timingGates = compareCandidate(result.metrics, baseline.metrics);
    result.eligible = report.evidenceComplete && result.timingGates.length === 6 && result.timingGates.every(gate => gate.verdict === 'passed');
  }
  const eligible = report.strategies.filter(result => result.eligible).sort((left, right) =>
    left.metrics.wallpaperBlackout.median.point - right.metrics.wallpaperBlackout.median.point
    || left.metrics.wallpaperBlackout.p95.point - right.metrics.wallpaperBlackout.p95.point
    || strategies.indexOf(left.strategy) - strategies.indexOf(right.strategy));
  if (eligible.length) {
    report.recommendedStrategy = eligible[0].strategy;
    report.recommendation = 'candidate eligible for manual strategy selection';
  }
  return report;
}

const help = `usage:
  node Tools/AnalyzeDockTiming.mjs --reliability <baseline.json> --reliability <graceful.json> --reliability <explicit.json> --annotations <review.json>

reads three schema-2 dock probe reports and one schema-1 manual frame review.
each report must contain 20 successful switches alternating two distinct fixtures.
prints json to stdout. never changes the app, preferences, recordings, or ledger.
exit 0 means the report was evaluated, not that a candidate passed. exit 2 means invalid cli arguments.

annotation root fields:
  schemaVersion: 1
  review: { method: "manual-frame-review", reviewedBy: nonempty text, reviewedAt: iso 8601 timestamp }
  strategies: exactly three entries with strategy, reliabilityReport, observations

strategy identifiers:
  forcedTermination
  gracefulTerminationWithForcedFallback
  forcedTerminationAndExplicitRelaunch

each strategy requires exactly 20 observations numbered 1 through 20:
  iteration: switch number matching the reliability report
  recording: file path relative to the annotation file (absolute paths also work)
  recordingSha256: exact recording sha256, lowercase hexadecimal
  frameRate: finite frames per second greater than zero
  frameCount: positive integer, verified by the reviewer
  inspectedFrameRange: { first, last }, inclusive zero-based frame indices
  restartRequestSeconds: restart request timestamp on this recording's timeline
  wallpaperBlackouts: array of { startSeconds, endSeconds }
  firstReturningDockPixelSeconds: first returning dock pixel timestamp
  settledDockSeconds: settled dock timestamp
  uncertaintyFrames: positive integer, at least one frame per endpoint
  observedExtraRestartCycles: 0, explicitly reviewed

all timestamps use recording seconds, not wall-clock time. frame inspection must cover
the whole event. an empty blackout array means observed no blackout. missing, false,
and null do not mean zero. a returning dock does not imply the wallpaper has recovered.
use a recording with known constant frame rate or conservatively resample and review it.
the reviewer verifies the frame rate and count, event alignment, complete inspected
range, blackout intervals, first return, settling, and extra restart cycles. this tool
checks annotation structure and file hashes; it does not decode metadata or inspect pixels.
the same recording content must use consistent frame metadata. events cannot overlap
or repeat, even through copied recording files. switch numbers follow recording order.
relative reliabilityReport paths resolve from the annotations file. backup and recovery
marker paths resolve from their reliability report. preserve these evidence files.

point estimates and uncertainty bounds are separate. each endpoint error is
uncertaintyFrames / frameRate seconds. delay error is twice that amount. blackout
interval errors add; an observed zero-blackout event has an upper bound of one endpoint
error. median uses the mean of the middle pair. p95 uses nearest rank (19th of 20).
wallpaper median upper bound must be at most 280 ms; p95 upper bound must be below
450 ms. first-return and settling median/p95 upper bounds must not exceed the
baseline's corresponding lower bounds. overlap is inconclusive, not a claimed regression.
missing, invalid, unreliable, or inconclusive evidence retains forcedTermination.
if several candidates pass, lower wallpaper point median wins, then lower p95,
then the strategy order above. the report is advisory; strategy changes stay manual.
`;

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  if (args.length === 1 && args[0] === '--help') process.stdout.write(help);
  else {
    const reliabilityPaths = [];
    let annotationsPath;
    let valid = true;
    for (let index = 0; index < args.length; index += 2) {
      const value = args[index + 1];
      if (!isText(value) || value.startsWith('--')) { valid = false; break; }
      if (args[index] === '--reliability') reliabilityPaths.push(value);
      else if (args[index] === '--annotations' && !annotationsPath) annotationsPath = value;
      else valid = false;
    }
    if (!valid || reliabilityPaths.length !== 3 || !annotationsPath) {
      process.stdout.write(`${JSON.stringify({ error: 'provide three --reliability paths and one --annotations path; use --help for the contract' })}\n`);
      process.exitCode = 2;
    } else {
      try {
        process.stdout.write(`${JSON.stringify(await analyzeDockTiming({ reliabilityPaths, annotationsPath }), null, 2)}\n`);
      } catch {
        process.stdout.write(`${JSON.stringify({ recommendedStrategy: strategies[0], recommendation: 'retain baseline', evidenceComplete: false, error: 'evidence evaluation failed; no candidate may be selected' })}\n`);
        process.exitCode = 2;
      }
    }
  }
}
