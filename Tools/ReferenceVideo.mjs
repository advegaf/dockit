import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { createReadStream } from "node:fs";
import { access, mkdir, readFile, readdir, rename, stat, unlink, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const schemaVersion = 1;
const outcomes = new Set(["match", "difference", "intentionalDifference", "notComparable"]);
const sha256Pattern = /^[a-f0-9]{64}$/;

function fail(message, exitCode = 2) {
  const error = new Error(message);
  error.exitCode = exitCode;
  throw error;
}

function parseArguments(argv) {
  const [command, ...tokens] = argv;
  if (!command || command === "--help") return { command: "help", options: {} };
  const allowed = {
    index: new Set(["source", "output"]),
    extract: new Set(["manifest", "from", "to", "output"]),
    coverage: new Set(["manifest", "annotations", "output"]),
  }[command];
  if (!allowed) fail(`unknown command: ${command}`);
  const options = {};
  for (let index = 0; index < tokens.length; index += 2) {
    const option = tokens[index];
    const value = tokens[index + 1];
    if (!option?.startsWith("--") || value === undefined || value.startsWith("--")) fail(`invalid arguments for ${command}`);
    const key = option.slice(2);
    if (!allowed.has(key)) fail(`unknown option for ${command}: ${option}`);
    if (options[key] !== undefined) fail(`duplicate option for ${command}: ${option}`);
    options[key] = value;
  }
  if ([...allowed].some(key => options[key] === undefined)) fail(`missing required option for ${command}`);
  return { command, options };
}

function usage() {
  return [
    "usage:",
    "  ReferenceVideo.mjs index --source <video> --output <directory>",
    "  ReferenceVideo.mjs extract --manifest <manifest.json> --from <index> --to <index> --output <directory>",
    "  ReferenceVideo.mjs coverage --manifest <manifest.json> --annotations <annotations.json> --output <coverage.json>",
  ].join("\n");
}

async function exists(file) {
  try {
    await access(file);
    return true;
  } catch {
    return false;
  }
}

async function writeJSONAtomic(file, value, overwrite = true) {
  if (!overwrite && await exists(file)) fail(`refusing to overwrite existing file: ${file}`);
  await mkdir(path.dirname(file), { recursive: true });
  const temporary = `${file}.tmp-${process.pid}`;
  try {
    await writeFile(temporary, `${JSON.stringify(value, null, 2)}\n`, { flag: "wx" });
    await rename(temporary, file);
  } catch (error) {
    await unlink(temporary).catch(() => {});
    throw error;
  }
}

async function sha256(file) {
  const hash = createHash("sha256");
  for await (const chunk of createReadStream(file)) hash.update(chunk);
  return hash.digest("hex");
}

function run(binary, args, maxBuffer = 256 * 1024 * 1024) {
  const result = spawnSync(binary, args, { encoding: "utf8", maxBuffer });
  if (result.error) fail(`${binary} failed: ${result.error.message}`);
  if (result.status !== 0) fail(`${binary} failed: ${(result.stderr || result.stdout).trim()}`);
  return result.stdout;
}

function finiteNumber(value, label) {
  const number = typeof value === "number" ? value : Number(value);
  if (!Number.isFinite(number)) fail(`${label} must be finite`);
  return number;
}

function positiveInteger(value, label) {
  const number = finiteNumber(value, label);
  if (!Number.isSafeInteger(number) || number <= 0) fail(`${label} must be a positive integer`);
  return number;
}

function safeInteger(value, label) {
  const number = finiteNumber(value, label);
  if (!Number.isSafeInteger(number)) fail(`${label} must be a safe integer`);
  return number;
}

function safeRelativePath(value, label) {
  if (typeof value !== "string" || value.length === 0 || path.isAbsolute(value) || value.includes("\\")) {
    fail(`${label} must be a safe relative path`);
  }
  const parts = value.split("/");
  if (parts.some(part => part === "" || part === "." || part === "..") || path.normalize(value) !== value) {
    fail(`${label} must be a safe relative path`);
  }
  return value;
}

function containedOutput(baseDirectory, candidate) {
  const output = path.resolve(candidate);
  const relative = path.relative(baseDirectory, output);
  if (relative === "" || relative.startsWith(`..${path.sep}`) || relative === ".." || path.isAbsolute(relative)) {
    fail("output must be a child directory of the manifest directory");
  }
  return output;
}

function validateManifest(manifest) {
  if (!manifest || typeof manifest !== "object" || Array.isArray(manifest)) fail("manifest must be an object");
  if (manifest.schemaVersion !== schemaVersion || manifest.kind !== "referenceVideoFrameIndex") fail("unsupported manifest schema");
  const source = manifest.source;
  if (!source || typeof source !== "object" || Array.isArray(source)) fail("manifest source must be an object");
  if (typeof source.absolutePath !== "string" || !path.isAbsolute(source.absolutePath) || path.normalize(source.absolutePath) !== source.absolutePath) {
    fail("manifest source path must be normalized and absolute");
  }
  if (!sha256Pattern.test(source.sha256)) fail("manifest source sha256 is invalid");
  positiveInteger(source.byteSize, "manifest source byte size");
  positiveInteger(source.width, "manifest source width");
  positiveInteger(source.height, "manifest source height");
  positiveInteger(source.decodedFrameCount, "manifest decoded frame count");
  if (!Array.isArray(manifest.frames) || manifest.frames.length !== source.decodedFrameCount) {
    fail("manifest frame count does not match decoded frame count");
  }
  let previousPTS = -Infinity;
  for (const [position, frame] of manifest.frames.entries()) {
    if (!frame || typeof frame !== "object" || Array.isArray(frame)) fail(`manifest frame ${position} must be an object`);
    if (frame.frameIndex !== position) fail(`manifest has missing, duplicate, or out-of-order frame index at ${position}`);
    const pts = safeInteger(frame.originalPTS, `manifest frame ${position} original pts`);
    if (pts <= previousPTS) fail(`manifest frame ${position} original pts must increase`);
    previousPTS = pts;
    const ptsTime = finiteNumber(frame.originalPTSTime, `manifest frame ${position} original pts time`);
    if (typeof frame.originalPTSTime !== "string") fail(`manifest frame ${position} original pts time must preserve ffprobe text`);
    if (position > 0 && ptsTime < finiteNumber(manifest.frames[position - 1].originalPTSTime, "previous original pts time")) {
      fail(`manifest frame ${position} original pts time must not decrease`);
    }
    const duration = positiveInteger(frame.originalDuration, `manifest frame ${position} original duration`);
    const durationTime = finiteNumber(frame.originalDurationTime, `manifest frame ${position} original duration time`);
    if (duration <= 0 || durationTime <= 0 || typeof frame.originalDurationTime !== "string") {
      fail(`manifest frame ${position} original duration is invalid`);
    }
  }
  return manifest;
}

function buildCoverage(manifest, annotations) {
  if (!annotations || typeof annotations !== "object" || Array.isArray(annotations)) fail("annotations must be an object");
  if (annotations.schemaVersion !== schemaVersion || annotations.kind !== "referenceVideoFrameAnnotations") {
    fail("unsupported annotations schema");
  }
  if (annotations.sourceSha256 !== manifest.source.sha256) fail("annotations source sha256 does not match manifest");
  safeRelativePath(annotations.manifest, "annotations manifest path");
  if (!Array.isArray(annotations.annotations)) fail("annotations must contain an array");
  const byIndex = new Map();
  for (const [position, annotation] of annotations.annotations.entries()) {
    if (!annotation || typeof annotation !== "object" || Array.isArray(annotation)) fail(`annotation ${position} must be an object`);
    const frameIndex = safeInteger(annotation.frameIndex, `annotation ${position} frame index`);
    if (frameIndex < 0 || frameIndex >= manifest.frames.length) fail(`annotation frame index ${frameIndex} is out of range`);
    if (byIndex.has(frameIndex)) fail(`duplicate annotation for frame ${frameIndex}`);
    byIndex.set(frameIndex, annotation);
  }
  const missing = manifest.frames.map(frame => frame.frameIndex).filter(frameIndex => !byIndex.has(frameIndex));
  if (missing.length > 0) fail(`missing annotation records for frames: ${missing.join(", ")}`);

  const reviewed = [];
  const unreviewed = [];
  const outcomeCounts = Object.fromEntries([...outcomes].map(outcome => [outcome, 0]));
  for (let frameIndex = 0; frameIndex < manifest.frames.length; frameIndex += 1) {
    const annotation = byIndex.get(frameIndex);
    if (!["unreviewed", "reviewed"].includes(annotation.reviewStatus)) {
      fail(`annotation ${frameIndex} review status must be reviewed or unreviewed`);
    }
    for (const field of ["inspectedEvidence", "currentAppComparisonEvidence", "relatedStoryIDs", "relatedDefectIDs"]) {
      if (!Array.isArray(annotation[field])) fail(`annotation ${frameIndex} ${field} must be an array`);
      if (new Set(annotation[field]).size !== annotation[field].length) fail(`annotation ${frameIndex} ${field} contains duplicates`);
    }
    annotation.inspectedEvidence.forEach((value, index) => safeRelativePath(value, `annotation ${frameIndex} inspected evidence ${index}`));
    annotation.currentAppComparisonEvidence.forEach((value, index) => safeRelativePath(value, `annotation ${frameIndex} current app evidence ${index}`));
    for (const field of ["relatedStoryIDs", "relatedDefectIDs"]) {
      for (const value of annotation[field]) {
        if (typeof value !== "string" || !/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(value)) fail(`annotation ${frameIndex} ${field} contains an invalid id`);
      }
    }
    if (typeof annotation.notes !== "string") fail(`annotation ${frameIndex} notes must be text`);
    if (annotation.reviewStatus === "unreviewed") {
      if (annotation.outcome !== null) fail(`unreviewed annotation ${frameIndex} must not have an outcome`);
      unreviewed.push(frameIndex);
      continue;
    }
    if (!outcomes.has(annotation.outcome)) fail(`reviewed annotation ${frameIndex} has an invalid outcome`);
    if (annotation.inspectedEvidence.length === 0) fail(`reviewed annotation ${frameIndex} requires inspected evidence`);
    if (annotation.outcome !== "notComparable" && annotation.currentAppComparisonEvidence.length === 0) {
      fail(`reviewed annotation ${frameIndex} requires current app comparison evidence`);
    }
    if (annotation.outcome === "notComparable" && annotation.notes.trim().length === 0) {
      fail(`not comparable annotation ${frameIndex} requires notes`);
    }
    reviewed.push(frameIndex);
    outcomeCounts[annotation.outcome] += 1;
  }
  return {
    schemaVersion,
    kind: "referenceVideoReviewCoverage",
    sourceSha256: manifest.source.sha256,
    totalFrameCount: manifest.frames.length,
    reviewedFrameCount: reviewed.length,
    unreviewedFrameCount: unreviewed.length,
    reviewedFrameIndexes: reviewed,
    unreviewedFrameIndexes: unreviewed,
    outcomeCounts,
    complete: unreviewed.length === 0,
    rule: "Only explicit reviewed annotations count. Indexing, extraction, hashes, and sampling do not count as visual review.",
  };
}

async function indexVideo(options) {
  const source = path.resolve(options.source);
  const sourceStat = await stat(source).catch(() => null);
  if (!sourceStat?.isFile() || sourceStat.size <= 0) fail(`source must be an existing nonempty file: ${source}`);
  const output = path.resolve(options.output);
  const manifestPath = path.join(output, "manifest.json");
  const annotationsPath = path.join(output, "annotations.json");
  const coveragePath = path.join(output, "coverage.json");
  if (await Promise.any([manifestPath, annotationsPath, coveragePath].map(async file => {
    if (await exists(file)) return true;
    throw new Error("missing");
  })).catch(() => false)) fail(`refusing to replace existing reference-video files in: ${output}`);

  const probeText = run("ffprobe", [
    "-v", "error",
    "-select_streams", "v:0",
    "-count_frames",
    "-show_frames",
    "-show_entries", "stream=index,width,height,nb_frames,nb_read_frames,r_frame_rate,avg_frame_rate,time_base,duration",
    "-show_entries", "frame=pts,pts_time,duration,duration_time",
    "-of", "json",
    source,
  ]);
  let probe;
  try {
    probe = JSON.parse(probeText);
  } catch {
    fail("ffprobe returned invalid json");
  }
  const stream = probe.streams?.[0];
  if (!stream || !Array.isArray(probe.frames) || probe.frames.length === 0) fail("ffprobe returned no decoded video frames");
  const frames = probe.frames.map((frame, frameIndex) => ({
    frameIndex,
    originalPTS: safeInteger(frame.pts, `ffprobe frame ${frameIndex} pts`),
    originalPTSTime: String(frame.pts_time),
    originalDuration: positiveInteger(frame.duration, `ffprobe frame ${frameIndex} duration`),
    originalDurationTime: String(frame.duration_time),
  }));
  const digest = await sha256(source);
  const manifest = validateManifest({
    schemaVersion,
    kind: "referenceVideoFrameIndex",
    source: {
      absolutePath: source,
      sha256: digest,
      byteSize: sourceStat.size,
      streamIndex: safeInteger(stream.index, "video stream index"),
      width: positiveInteger(stream.width, "video width"),
      height: positiveInteger(stream.height, "video height"),
      timeBase: stream.time_base,
      nominalFrameRate: stream.r_frame_rate,
      averageFrameRate: stream.avg_frame_rate,
      durationTime: stream.duration,
      declaredFrameCount: positiveInteger(stream.nb_frames, "declared frame count"),
      decodedFrameCount: positiveInteger(stream.nb_read_frames, "decoded frame count"),
    },
    frames,
  });
  if (manifest.source.declaredFrameCount !== manifest.frames.length) fail("declared frame count does not match decoded frame count");
  const annotations = {
    schemaVersion,
    kind: "referenceVideoFrameAnnotations",
    manifest: "manifest.json",
    sourceSha256: digest,
    annotations: frames.map(frame => ({
      frameIndex: frame.frameIndex,
      reviewStatus: "unreviewed",
      inspectedEvidence: [],
      currentAppComparisonEvidence: [],
      outcome: null,
      notes: "",
      relatedStoryIDs: [],
      relatedDefectIDs: [],
    })),
  };
  const coverage = buildCoverage(manifest, annotations);
  await mkdir(output, { recursive: true });
  await writeJSONAtomic(manifestPath, manifest, false);
  await writeJSONAtomic(annotationsPath, annotations, false);
  await writeJSONAtomic(coveragePath, coverage, false);
  return { manifestPath, annotationsPath, coveragePath, sourceSha256: digest, frameCount: frames.length };
}

async function readManifest(file) {
  let manifest;
  try {
    manifest = JSON.parse(await readFile(file, "utf8"));
  } catch (error) {
    fail(`cannot read manifest: ${error.message}`);
  }
  return validateManifest(manifest);
}

function parseFrameBound(value) {
  if (!/^(0|[1-9][0-9]*)$/.test(value)) fail("frame bounds must be zero-based nonnegative integers");
  return Number(value);
}

async function pngDimensions(file) {
  const bytes = await readFile(file);
  const signature = "89504e470d0a1a0a";
  if (bytes.length < 24 || bytes.subarray(0, 8).toString("hex") !== signature) fail(`extracted file is not png: ${file}`);
  return { width: bytes.readUInt32BE(16), height: bytes.readUInt32BE(20), byteSize: bytes.length };
}

async function extractFrames(options) {
  const manifestPath = path.resolve(options.manifest);
  const manifest = await readManifest(manifestPath);
  const from = parseFrameBound(options.from);
  const to = parseFrameBound(options.to);
  if (from > to || to >= manifest.frames.length) fail(`frame bounds must satisfy 0 <= from <= to < ${manifest.frames.length}`);
  const sourceStat = await stat(manifest.source.absolutePath).catch(() => null);
  if (!sourceStat?.isFile()) fail("manifest source is not an existing file");
  if (await sha256(manifest.source.absolutePath) !== manifest.source.sha256) fail("source sha256 does not match manifest");
  if (sourceStat.size !== manifest.source.byteSize) fail("source bytes do not match manifest byte size");
  const manifestDirectory = path.dirname(manifestPath);
  const output = containedOutput(manifestDirectory, options.output);
  const metadataName = `extraction-${String(from).padStart(6, "0")}-${String(to).padStart(6, "0")}.json`;
  const expected = Array.from({ length: to - from + 1 }, (_, offset) => path.join(output, `frame-${String(from + offset).padStart(6, "0")}.png`));
  for (const file of [...expected, path.join(output, metadataName)]) {
    if (await exists(file)) fail(`refusing to overwrite existing extraction file: ${file}`);
  }
  await mkdir(output, { recursive: true });
  run("ffmpeg", [
    "-v", "error",
    "-i", manifest.source.absolutePath,
    "-map", "0:v:0",
    "-vf", `select=between(n\\,${from}\\,${to})`,
    "-fps_mode", "passthrough",
    "-frames:v", String(to - from + 1),
    "-start_number", String(from),
    "-an", "-sn", "-dn",
    "-n",
    path.join(output, "frame-%06d.png"),
  ]);
  const extractionFrames = [];
  for (let frameIndex = from; frameIndex <= to; frameIndex += 1) {
    const file = path.join(output, `frame-${String(frameIndex).padStart(6, "0")}.png`);
    const dimensions = await pngDimensions(file);
    if (dimensions.width !== manifest.source.width || dimensions.height !== manifest.source.height) {
      fail(`extracted frame ${frameIndex} dimensions changed`);
    }
    const indexed = manifest.frames[frameIndex];
    extractionFrames.push({
      frameIndex,
      originalPTS: indexed.originalPTS,
      originalPTSTime: indexed.originalPTSTime,
      originalDuration: indexed.originalDuration,
      originalDurationTime: indexed.originalDurationTime,
      file: safeRelativePath(path.relative(manifestDirectory, file), `extracted frame ${frameIndex} path`),
      sha256: await sha256(file),
      byteSize: dimensions.byteSize,
      width: dimensions.width,
      height: dimensions.height,
    });
  }
  const metadataPath = path.join(output, metadataName);
  const extraction = {
    schemaVersion,
    kind: "referenceVideoFrameExtraction",
    manifest: safeRelativePath(path.relative(manifestDirectory, manifestPath), "extraction manifest path"),
    sourceSha256: manifest.source.sha256,
    inclusiveFrameBounds: { from, to },
    fpsMode: "passthrough",
    rescaled: false,
    frames: extractionFrames,
  };
  await writeJSONAtomic(metadataPath, extraction, false);
  return { metadataPath, frameCount: extractionFrames.length, inclusiveFrameBounds: { from, to } };
}

async function reportCoverage(options) {
  const manifest = await readManifest(path.resolve(options.manifest));
  let annotations;
  try {
    annotations = JSON.parse(await readFile(path.resolve(options.annotations), "utf8"));
  } catch (error) {
    fail(`cannot read annotations: ${error.message}`);
  }
  const report = buildCoverage(manifest, annotations);
  await writeJSONAtomic(path.resolve(options.output), report);
  return report;
}

async function main() {
  const { command, options } = parseArguments(process.argv.slice(2));
  if (command === "help") {
    process.stdout.write(`${usage()}\n`);
    return;
  }
  const result = command === "index"
    ? await indexVideo(options)
    : command === "extract"
      ? await extractFrames(options)
      : await reportCoverage(options);
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  if (command === "coverage" && !result.complete) process.exitCode = 1;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main().catch(error => {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = error.exitCode ?? 2;
  });
}
