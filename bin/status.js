#!/usr/bin/env node
// Status recorder for the agent farm: the single place where task state changes are written.
//
//   node bin/status.js <event> '<json fields>'     e.g. status.js started '{"id":"...","repo":"..."}'
//   node bin/status.js show                         print the current snapshot
//
// Writes:
//   state/events.jsonl   append-only log of every event (for syncing to Linear, a DB, or a dashboard)
//   state/status.json    snapshot: machine, number of running agents, latest state of every task
// If STATUS_HOOK is set, it is run for each event with the event JSON on stdin. This is the plug-in
// point for a future sync adapter (for example a script that updates a Linear issue or a database row).
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");

const STATE = path.join(__dirname, "..", "state");
const EVENTS = path.join(STATE, "events.jsonl");
const SNAPSHOT = path.join(STATE, "status.json");

/** Terminal states: a task in one of these is no longer running. */
const FINAL = new Set(["done", "failed", "requeued"]);

/** Read the current snapshot, or an empty one if none exists yet. */
function readSnapshot() {
  try {
    return JSON.parse(fs.readFileSync(SNAPSHOT, "utf8"));
  } catch {
    return { machine: os.hostname(), tasks: {} };
  }
}

/** Record one event: append it to the log, fold it into the snapshot, and call the hook. */
function record(type, fields) {
  fs.mkdirSync(STATE, { recursive: true });
  const event = { ts: new Date().toISOString(), machine: os.hostname(), event: type, ...fields };
  fs.appendFileSync(EVENTS, JSON.stringify(event) + "\n");

  const snap = readSnapshot();
  if (event.id) {
    const prev = snap.tasks[event.id] || {};
    const state = ["started", "done", "failed", "requeued"].includes(type) ? type : prev.state;
    snap.tasks[event.id] = { ...prev, ...fields, state, updated: event.ts };
  }
  snap.machine = os.hostname();
  snap.updated = event.ts;
  snap.running = Object.values(snap.tasks).filter((t) => t.state && !FINAL.has(t.state)).length;
  // Write atomically so readers never see a half-written file
  const tmp = SNAPSHOT + "." + process.pid;
  fs.writeFileSync(tmp, JSON.stringify(snap, null, 2) + "\n");
  fs.renameSync(tmp, SNAPSHOT);

  if (process.env.STATUS_HOOK) {
    // Best effort: a broken hook must never break a farm run
    spawnSync("sh", ["-c", process.env.STATUS_HOOK], { input: JSON.stringify(event), timeout: 15000 });
  }
}

const [type, ...args] = process.argv.slice(2);
// Fields come as one JSON object, or as key=value pairs
const json =
  args.length === 1 && args[0].startsWith("{")
    ? args[0]
    : JSON.stringify(Object.fromEntries(args.map((a) => [a.slice(0, a.indexOf("=")), a.slice(a.indexOf("=") + 1)])));
if (!type) {
  console.error("usage: status.js <event> '<json>' | key=value ... | show");
  process.exit(2);
}
if (type === "show") {
  const s = readSnapshot();
  console.log(`machine: ${s.machine}   running: ${s.running || 0}   updated: ${s.updated || "-"}`);
  for (const [id, t] of Object.entries(s.tasks).slice(-20)) {
    console.log(`  ${(t.state || "?").padEnd(9)} ${id.padEnd(40)} ${t.pr || t.repo || ""}`);
  }
} else {
  record(type, json ? JSON.parse(json) : {});
}
