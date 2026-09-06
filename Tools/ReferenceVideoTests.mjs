import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const tool = path.join(path.dirname(fileURLToPath(import.meta.url)), "ReferenceVideo.mjs");

function run(args) {
  return spawnSync(process.execPath, [tool, ...args], {
    encoding: "utf8",
    maxBuffer: 16 * 1024 * 1024,
  });
}

async function readJSON(file) {
  return JSON.parse(await readFile(file, "utf8"));
}

async function writeJSON(file, value) {
  await writeFile(file, `${JSON.stringify(value, null, 2)}\n`);
}

async function fixture(context) {
  const directory = await mkdtemp(path.join(tmpdir(), "dockit-reference-video-test-"));
  context.after(() => rm(directory, { recursive: true, force: true }));
  const source = path.join(directory, "fixture.mp4");
  const reference = path.join(directory, "reference");
  const generated = spawnSync("ffmpeg", [
    "-v", "error",
    "-f", "lavfi",
    "-i", "testsrc=size=16x16:rate=10:duration=0.3",
    "-c:v", "libx264",
    "-pix_fmt", "yuv420p",
    source,
  ], { encoding: "utf8" });
  assert.equal(generated.status, 0, generated.stderr);
  const indexed = run(["index", "--source", source, "--output", reference]);
  assert.equal(indexed.status, 0, indexed.stderr || indexed.stdout);
  return {
    source,
    reference,
    manifest: path.join(reference, "manifest.json"),
    annotations: path.join(reference, "annotations.json"),
    coverage: path.join(reference, "coverage.json"),
  };
}

test("index and extract preserve zero-based frame identity and original pts", async context => {
  const data = await fixture(context);
  const manifest = await readJSON(data.manifest);
  assert.deepEqual(manifest.frames.map(frame => frame.frameIndex), [0, 1, 2]);
  assert.deepEqual(manifest.frames.map(frame => frame.originalPTSTime), ["0.000000", "0.100000", "0.200000"]);
  assert(manifest.frames.every(frame => Number.isFinite(frame.originalPTS)));
  assert(manifest.frames.every(frame => Number.isFinite(frame.originalDuration)));
  assert.equal(manifest.source.width, 16);
  assert.equal(manifest.source.height, 16);

  const annotations = await readJSON(data.annotations);
  assert.equal(annotations.annotations.length, 3);
  assert(annotations.annotations.every(annotation => annotation.reviewStatus === "unreviewed"));
  assert(annotations.annotations.every(annotation => annotation.outcome === null));

  const framesDirectory = path.join(data.reference, "frames");
  const extracted = run([
    "extract",
    "--manifest", data.manifest,
    "--from", "0",
    "--to", "2",
    "--output", framesDirectory,
  ]);
  assert.equal(extracted.status, 0, extracted.stderr || extracted.stdout);
  assert.deepEqual(await readdir(framesDirectory), [
    "extraction-000000-000002.json",
    "frame-000000.png",
    "frame-000001.png",
    "frame-000002.png",
  ]);
  const extraction = await readJSON(path.join(framesDirectory, "extraction-000000-000002.json"));
  assert.deepEqual(extraction.frames.map(frame => frame.frameIndex), [0, 1, 2]);
  assert.deepEqual(
    extraction.frames.map(frame => frame.originalPTSTime),
    manifest.frames.map(frame => frame.originalPTSTime),
  );
});

test("extract rejects invalid inclusive frame bounds", async context => {
  const data = await fixture(context);
  for (const [from, to] of [["-1", "1"], ["2", "1"], ["0", "3"], ["x", "1"]]) {
    const output = path.join(data.reference, `bad-${from}-${to}`);
    const result = run([
      "extract",
      "--manifest", data.manifest,
      "--from", from,
      "--to", to,
      "--output", output,
    ]);
    assert.equal(result.status, 2, result.stderr || result.stdout);
    assert.match(result.stderr, /frame bounds/);
  }
});

test("extract rejects source bytes that no longer match the manifest hash", async context => {
  const data = await fixture(context);
  await writeFile(data.source, "changed source bytes");
  const result = run([
    "extract",
    "--manifest", data.manifest,
    "--from", "0",
    "--to", "0",
    "--output", path.join(data.reference, "changed"),
  ]);
  assert.equal(result.status, 2, result.stderr || result.stdout);
  assert.match(result.stderr, /source sha256 does not match/);
});

test("coverage reports every unreviewed frame and exits non-zero", async context => {
  const data = await fixture(context);
  const result = run([
    "coverage",
    "--manifest", data.manifest,
    "--annotations", data.annotations,
    "--output", data.coverage,
  ]);
  assert.equal(result.status, 1, result.stderr || result.stdout);
  const report = await readJSON(data.coverage);
  assert.equal(report.complete, false);
  assert.equal(report.reviewedFrameCount, 0);
  assert.deepEqual(report.unreviewedFrameIndexes, [0, 1, 2]);
});

test("coverage rejects missing and duplicate annotation records", async context => {
  for (const mutation of ["missing", "duplicate"]) {
    const data = await fixture(context);
    const annotations = await readJSON(data.annotations);
    if (mutation === "missing") annotations.annotations.pop();
    else annotations.annotations.push(structuredClone(annotations.annotations[0]));
    await writeJSON(data.annotations, annotations);
    const result = run([
      "coverage",
      "--manifest", data.manifest,
      "--annotations", data.annotations,
      "--output", data.coverage,
    ]);
    assert.equal(result.status, 2, result.stderr || result.stdout);
    assert.match(result.stderr, mutation === "missing" ? /missing annotation/ : /duplicate annotation/);
  }
});

test("coverage requires explicit inspected evidence and rejects path traversal", async context => {
  const data = await fixture(context);
  const annotations = await readJSON(data.annotations);
  for (const annotation of annotations.annotations) {
    annotation.reviewStatus = "reviewed";
    annotation.outcome = "match";
    annotation.inspectedEvidence = [`frames/frame-${String(annotation.frameIndex).padStart(6, "0")}.png`];
    annotation.currentAppComparisonEvidence = ["current-app/editor.png"];
  }
  annotations.annotations[1].inspectedEvidence = ["../outside.png"];
  await writeJSON(data.annotations, annotations);
  const rejected = run([
    "coverage",
    "--manifest", data.manifest,
    "--annotations", data.annotations,
    "--output", data.coverage,
  ]);
  assert.equal(rejected.status, 2, rejected.stderr || rejected.stdout);
  assert.match(rejected.stderr, /safe relative path/);

  annotations.annotations[1].inspectedEvidence = ["frames/frame-000001.png"];
  await writeJSON(data.annotations, annotations);
  const complete = run([
    "coverage",
    "--manifest", data.manifest,
    "--annotations", data.annotations,
    "--output", data.coverage,
  ]);
  assert.equal(complete.status, 0, complete.stderr || complete.stdout);
  assert.equal((await readJSON(data.coverage)).complete, true);
});
