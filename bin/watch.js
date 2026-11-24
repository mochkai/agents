#!/usr/bin/env node
// Live monitor for the agent farm: what each running task is doing right now.
//   node bin/watch.js            print once
//   bin/watch.sh [seconds]       refresh continuously (default every 5 s)
//
// It reads state/status.json for the task list, plus the session transcripts Claude Code writes under
// ~/.claude/projects/<worktree-path>/ to see which agent is active and what it last did.
// It also lists Claude sessions you started yourself (e.g. `claude --agent orchestrator`) that were active in
// the last ACTIVE_MINUTES (default 15); farm runs under worktrees/ are left out of that list.
// It also shows the last plan-usage reading (state/usage.json, written by bin/usage.sh) against the limits in
// farm.conf (environment variables override them). It never probes the usage itself; bin/watch.sh refreshes it.
// It is read-only and uses no API calls, so it costs nothing to run.
const fs = require("fs");
const os = require("os");
const path = require("path");

const FARM = path.join(__dirname, "..");
const PROJECTS = process.env.CLAUDE_PROJECTS_DIR || path.join(os.homedir(), ".claude", "projects");
// Non-numeric or zero values fall back to the defaults
const STALE_MIN = Number(process.env.STALE_MINUTES) || 10;
const ACTIVE_MIN = Number(process.env.ACTIVE_MINUTES) || 15;
const IDLE_MS = 5 * 60000;        // interactive sessions quieter than this are dimmed
const MAX_INTERACTIVE = 8;
const TAIL_BYTES = 256 * 1024;    // large interactive transcripts: only the tail is parsed
const HEAD_BYTES = 16 * 1024;     // ...plus the head, if the tail doesn't say which agent the session runs as
const tty = process.stdout.isTTY;
const c = (code, s) => (tty ? `\x1b[${code}m${s}\x1b[0m` : s);
const dim = (s) => c(2, s), bold = (s) => c(1, s), green = (s) => c(32, s), red = (s) => c(31, s), yellow = (s) => c(33, s), cyan = (s) => c(36, s);

/**
 * Make transcript-derived text safe to print: strips ESC and other control characters
 * (C0, DEL and C1), so a transcript can't inject terminal escape sequences.
 */
function clean(s) {
  return String(s ?? "").replace(/[\x00-\x1f\x7f-\x9f]/g, "");
}

/** Human-friendly duration, for example "4m 12s" or "1h 03m". */
function ago(ms) {
  const s = Math.max(0, Math.round(ms / 1000));
  if (s < 60) return `${s}s`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m ${String(s % 60).padStart(2, "0")}s`;
  return `${Math.floor(m / 60)}h ${String(m % 60).padStart(2, "0")}m`;
}

/** True if a process with this pid is still alive. */
function alive(pid) {
  try { process.kill(Number(pid), 0); return true; } catch { return false; }
}

/** Path-encoded project directory name Claude Code uses: every non-alphanumeric char becomes "-". */
function encodePath(p) {
  return p.replace(/[^a-zA-Z0-9]/g, "-");
}

/**
 * Read up to `bytes` bytes of a file, from the start or from the end.
 * Without `bytes` (or when the file is smaller) the whole file is read.
 */
function readPart(file, bytes, fromEnd = true) {
  const fd = fs.openSync(file, "r");
  try {
    const size = fs.fstatSync(fd).size;
    const len = bytes ? Math.min(bytes, size) : size;
    const buf = Buffer.alloc(len);
    fs.readSync(fd, buf, 0, len, fromEnd ? size - len : 0);
    return buf.toString("utf8");
  } finally { fs.closeSync(fd); }
}

/**
 * Parse a .jsonl transcript, skipping lines that are partial or malformed.
 * With `maxBytes`, only the last (or, with fromEnd=false, the first) `maxBytes` bytes are parsed;
 * the line cut off at the edge is dropped as malformed. Only JSON objects are kept (a line like `null` or `[]` is dropped).
 */
function readJsonl(file, maxBytes, fromEnd = true) {
  try {
    return readPart(file, maxBytes, fromEnd).split("\n").filter(Boolean).flatMap((l) => {
      try {
        const v = JSON.parse(l);
        return v && typeof v === "object" && !Array.isArray(v) ? [v] : [];
      } catch { return []; }
    });
  } catch { return []; }
}

/** One-line summary of an assistant action: a tool call, or the start of its text. */
function describe(entry) {
  const parts = entry?.message?.content;
  if (!Array.isArray(parts)) return null;
  const tool = [...parts].reverse().find((p) => p?.type === "tool_use");
  if (tool) {
    const i = tool.input || {};
    if (tool.name === "Agent") return `→ delegating to ${i.subagent_type}: ${i.description || ""}`;
    const arg = i.command || i.file_path || i.pattern || i.description || "";
    return `${tool.name} ${String(arg).replace(/\s+/g, " ")}`;
  }
  const text = parts.find((p) => p?.type === "text")?.text;
  return text ? `“${String(text).replace(/\s+/g, " ")}”` : null;
}

/** The last assistant action and its timestamp in a transcript. */
function lastAction(lines) {
  for (let i = lines.length - 1; i >= 0; i--) {
    if (lines[i].type === "assistant") {
      const d = describe(lines[i]);
      if (d) return { what: d, ts: Date.parse(lines[i].timestamp) };
    }
  }
  return null;
}

/**
 * Find the most recently active transcript of a session: the main one or one of its subagents.
 * Subagent transcripts live in <session>/subagents/. Only file times are read here (no contents).
 * Returns { file, mtime, isSub }, or null if no transcript could be stat'ed.
 */
function activeTranscript(main) {
  const candidates = [main];
  const subDir = main.replace(/\.jsonl$/, "") + "/subagents";
  try {
    for (const f of fs.readdirSync(subDir).filter((f) => f.endsWith(".jsonl"))) candidates.push(path.join(subDir, f));
  } catch {}
  return candidates.flatMap((file) => { try { return [{ file, mtime: fs.statSync(file).mtimeMs, isSub: file !== main }]; } catch { return []; } })
    .sort((a, b) => b.mtime - a.mtime)[0] || null;
}

/** A subagent transcript's agent type, from its sibling .meta.json ("subagent" if unknown). */
function subagentType(file) {
  try { return JSON.parse(fs.readFileSync(file.replace(/\.jsonl$/, ".meta.json"), "utf8")).agentType || "subagent"; } catch { return "subagent"; }
}

/** Inspect the orchestrator session and its subagents for one task's worktree. */
function inspect(worktree) {
  const dir = path.join(PROJECTS, encodePath(worktree));
  let sessions = [];
  try {
    sessions = fs.readdirSync(dir).filter((f) => f.endsWith(".jsonl"))
      .map((f) => path.join(dir, f))
      .sort((a, b) => fs.statSync(b).mtimeMs - fs.statSync(a).mtimeMs);
  } catch { return null; }
  if (!sessions.length) return null;

  const main = sessions[0];
  const mainLines = readJsonl(main);
  // The order the orchestrator called its agents in
  const sequence = mainLines.flatMap((l) => (l.type === "assistant" && Array.isArray(l.message?.content) ? l.message.content : []))
    .filter((p) => p?.type === "tool_use" && p.name === "Agent").map((p) => p.input?.subagent_type).filter(Boolean);

  // The most recently active transcript (the orchestrator itself or a subagent) is the active agent
  const active = activeTranscript(main);
  if (!active) return null;  // the transcript vanished between readdir and stat
  const lines = active.isSub ? readJsonl(active.file) : mainLines;
  return { sequence, active: active.isSub ? subagentType(active.file) : "orchestrator", last: lastAction(lines), lastWrite: active.mtime };
}

/**
 * Last value of `key` in a list of transcript entries, or null.
 * Used for `cwd` and for `agentSetting` (written as {"type":"agent-setting"} when a session runs with --agent).
 */
function lastField(lines, key) {
  for (let i = lines.length - 1; i >= 0; i--) if (lines[i][key]) return lines[i][key];
  return null;
}

/** True if path `p` is strictly inside one of the `roots` (path.sep-aware, so worktrees-old/ is not inside worktrees/). */
function isInside(p, roots) {
  let real = path.resolve(p);
  try { real = fs.realpathSync(real); } catch {}
  return roots.some((r) => {
    const rel = path.relative(r, real);
    return rel !== "" && !rel.startsWith("..") && !path.isAbsolute(rel);
  });
}

/**
 * Claude sessions the user started themselves, active within ACTIVE_MINUTES, most recent first.
 * Only top-level transcripts in ~/.claude/projects/<dir>/ are considered; project dirs under the
 * farm's worktrees/ are farm runs (shown in the farm section) and are skipped: a dir whose encoded name
 * matches is skipped when its transcript's cwd is inside worktrees/ (or unknown), so a sibling like
 * worktrees-old/, which encodes the same way, still shows up. Only files that pass
 * the mtime filter are parsed, and only their tail (plus the head, if needed for the agent name).
 * Returns { total, sessions } where sessions holds at most MAX_INTERACTIVE entries.
 */
function interactiveSessions(now) {
  const farmRoots = new Set([path.resolve(FARM, "worktrees")]);
  try { farmRoots.add(fs.realpathSync(path.join(FARM, "worktrees"))); } catch {}
  const roots = [...farmRoots];
  const skip = roots.map((p) => encodePath(p) + "-");
  const cutoff = now - ACTIVE_MIN * 60000;

  const found = [];
  let dirs = [];
  try { dirs = fs.readdirSync(PROJECTS, { withFileTypes: true }).filter((d) => d.isDirectory()).map((d) => d.name); } catch {}
  for (const d of dirs) {
    const maybeFarm = skip.some((p) => d.startsWith(p));
    let files = [];
    try { files = fs.readdirSync(path.join(PROJECTS, d)).filter((f) => f.endsWith(".jsonl")); } catch { continue; }
    for (const f of files) {
      const file = path.join(PROJECTS, d, f);
      // A busy subagent can be newer than its main transcript, so the session counts as active if either is recent
      const active = activeTranscript(file);
      if (!active || active.mtime < cutoff) continue;
      if (maybeFarm) {
        // Encoded names are ambiguous, so confirm with the real cwd (only for recent sessions, so it stays cheap)
        const cwd = lastField(readJsonl(file, TAIL_BYTES), "cwd");
        if (typeof cwd !== "string" || isInside(cwd, roots)) continue;
      }
      found.push({ file, active });
    }
  }
  found.sort((a, b) => b.active.mtime - a.active.mtime);

  // A session that can't be read is dropped rather than breaking the screen
  const sessions = found.slice(0, MAX_INTERACTIVE).flatMap(({ file, active }) => {
    try {
      const mainLines = readJsonl(file, TAIL_BYTES);
      // agent-setting entries repeat through the transcript; if none is in the tail, the first line usually has one
      const agent = lastField(mainLines, "agentSetting") || lastField(readJsonl(file, HEAD_BYTES, false), "agentSetting");
      const lines = active.isSub ? readJsonl(active.file, TAIL_BYTES) : mainLines;
      return [{
        cwd: clean(lastField(mainLines, "cwd") || lastField(lines, "cwd") || "?"),
        agent: clean(agent || "main session"),
        subagent: active.isSub ? clean(subagentType(active.file)) : null,
        last: lastAction(lines),
        lastWrite: active.mtime,
      }];
    } catch { return []; }
  });
  return { total: found.length, sessions };
}

/**
 * Farm settings from farm.conf: known keys only, the file is parsed (never evaluated), environment variables
 * win, and anything that is not a non-negative integer falls back to the default. Same rules as bin/lib/config.sh.
 */
function farmConfig() {
  const conf = { USAGE_LIMIT_5H: 75, USAGE_LIMIT_WEEK: 90, USAGE_MAX_AGE: 600 };
  const fromFile = {};
  try {
    for (const line of fs.readFileSync(path.join(FARM, "farm.conf"), "utf8").split("\n")) {
      const m = line.replace(/\r$/, "").match(/^([A-Z0-9_]+)=(.*)$/);
      if (m) fromFile[m[1]] = m[2].replace(/#.*$/, "").trim().replace(/^"|"$/g, "");
    }
  } catch {}
  for (const key of Object.keys(conf)) {
    const v = process.env[key] ?? fromFile[key];
    if (v !== undefined && /^[0-9]+$/.test(v)) conf[key] = Number(v);
  }
  return conf;
}

/** Reset time of a usage window: "18:10" within 20 hours, otherwise with the weekday ("Thu 21:00"). */
function resetTime(iso, now) {
  const d = new Date(iso);
  if (!iso || isNaN(d)) return "?";
  const hm = `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
  return d - now < 20 * 3600e3 ? hm : `${["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][d.getDay()]} ${hm}`;
}

/**
 * The usage line under the header, from state/usage.json and the farm.conf limits.
 * Each percentage is yellow within 10 points of its limit and red at or over it; a reading older than
 * 2 x USAGE_MAX_AGE is marked stale. A missing or malformed file gives an "unknown" line instead of an error.
 */
function usageLine(now) {
  const conf = farmConfig();
  const label = dim("usage");
  let u;
  try { u = JSON.parse(fs.readFileSync(path.join(FARM, "state", "usage.json"), "utf8")); } catch (e) {
    return `${label}  ${dim(e.code === "ENOENT" ? "unknown (run bin/usage.sh)" : "unknown (state/usage.json is unreadable; run bin/usage.sh --refresh)")}`;
  }
  if (!u || typeof u !== "object" || Array.isArray(u)) return `${label}  ${dim("unknown (state/usage.json is unreadable; run bin/usage.sh --refresh)")}`;
  const part = (name, w, limit) => {
    const pct = Number(w?.percent);
    if (!w || typeof w !== "object" || !Number.isFinite(pct)) return `${name} ?`;
    const text = `${Math.round(pct)}%`;
    const colored = limit > 0 && pct >= limit ? red(text) : limit > 0 && pct >= limit - 10 ? yellow(text) : text;
    return `${name} ${colored} ${dim(`(resets ${resetTime(w.resets_at, now)})`)}`;
  };
  const limits = [conf.USAGE_LIMIT_5H, conf.USAGE_LIMIT_WEEK].map((l) => (l > 0 ? `${l}%` : "off")).join(" / ");
  const checked = Date.parse(u.checked_at);
  const age = Number.isFinite(checked)
    ? (now - checked > 2 * conf.USAGE_MAX_AGE * 1000 ? yellow(`checked ${ago(now - checked)} ago (stale)`) : dim(`checked ${ago(now - checked)} ago`))
    : yellow("checked ? (stale)");
  return `${label}  ${part("5h", u.five_hour, conf.USAGE_LIMIT_5H)} · ${part("week", u.seven_day, conf.USAGE_LIMIT_WEEK)} · ${dim(`limits ${limits}`)} · ${age}`;
}

function render() {
  let snap = { tasks: {} };
  try { snap = JSON.parse(fs.readFileSync(path.join(FARM, "state", "status.json"), "utf8")); } catch {}
  const tasks = Object.entries(snap.tasks || {});
  const now = Date.now();
  const width = (process.stdout.columns || 120) - 6;
  const out = [];

  const inbox = (() => { try { return fs.readdirSync(path.join(FARM, "tasks", "inbox")).filter((f) => f.endsWith(".md")).length; } catch { return 0; } })();
  let paused = "";
  try {
    const until = Number(fs.readFileSync(path.join(FARM, "state", "paused-until"), "utf8")) * 1000;
    if (until > now) paused = yellow(`   ⏸ paused (usage limit) for ${ago(until - now)}`);
  } catch {}
  const running = tasks.filter(([, t]) => t.state === "started");
  out.push(bold(`Agent farm · ${snap.machine || os.hostname()}`) + dim(`   ${new Date().toLocaleTimeString()}`) + paused);
  const interactive = interactiveSessions(now);
  out.push(`running ${bold(String(running.length))}   queued ${bold(String(inbox))}   interactive ${bold(String(interactive.total))}`);
  out.push(usageLine(now));
  out.push("");

  if (!running.length) out.push(dim("  no tasks running"));
  for (const [id, t] of running) {
    const started = Date.parse(t.updated) || now;
    const procAlive = t.pid ? alive(t.pid) : true;
    out.push(`${procAlive ? green("●") : red("●")} ${bold(t.title || id)}  ${dim(id)}`);
    out.push(`  ${dim("repo")} ${t.repo || "?"}   ${dim("running for")} ${ago(now - started)}   ${dim("model")} ${t.model || "?"}`);
    if (!procAlive) { out.push(red("  ! runner process is gone: it crashed or was killed. Check logs/" + id + ".err")); out.push(""); continue; }
    // One unreadable transcript must not take down the whole screen
    let info;
    try { info = t.branch ? inspect(path.join(FARM, "worktrees", id)) : null; } catch { out.push(yellow("  ! could not read this task's transcript")); out.push(""); continue; }
    if (!info) { out.push(dim("  starting up…")); out.push(""); continue; }
    const idle = now - info.lastWrite;
    const flow = info.sequence.length ? info.sequence.map(clean).join(" → ") : "planning";
    out.push(`  ${dim("agents")}  ${flow}`);
    out.push(`  ${dim("active")}  ${cyan(clean(info.active))}${idle > STALE_MIN * 60000 ? yellow(`   ⚠ no activity for ${ago(idle)} (stuck or waiting on a long command?)`) : dim(`   (last activity ${ago(idle)} ago)`)}`);
    if (info.last) out.push(`  ${dim("doing")}   ${clean(info.last.what).slice(0, width - 10)}`);
    out.push("");
  }

  out.push(bold("Interactive sessions") + (interactive.total > interactive.sessions.length ? dim(`   (${interactive.sessions.length} most recent of ${interactive.total})`) : ""));
  if (!interactive.sessions.length) out.push(dim(`  no interactive sessions in the last ${ACTIVE_MIN} min`));
  for (const s of interactive.sessions) {
    const idle = now - s.lastWrite;
    // Idle sessions are dimmed as a whole, so no inner colors (their reset codes would cancel the dim)
    const quiet = idle > IDLE_MS;
    const [b, cy, dm] = quiet ? [(x) => x, (x) => x, (x) => x] : [bold, cyan, dim];
    const who = s.subagent ? `${s.agent} → ${cy(s.subagent)}` : s.agent;
    const head = `${quiet ? "○" : green("●")} ${b(s.cwd)}  ${who}   ${dm(`last activity ${ago(idle)} ago`)}`;
    out.push(quiet ? dim(head) : head);
    if (s.last) { const line = `  ${dm("doing")}   ${clean(s.last.what).slice(0, width - 10)}`; out.push(quiet ? dim(line) : line); }
  }
  out.push("");

  const finished = tasks.filter(([, t]) => ["done", "failed", "requeued"].includes(t.state))
    .sort((a, b) => Date.parse(b[1].updated) - Date.parse(a[1].updated)).slice(0, 5);
  if (finished.length) {
    out.push(bold("Recent"));
    for (const [id, t] of finished) {
      const icon = t.state === "done" ? green("✓") : t.state === "failed" ? red("✗") : yellow("↺");
      const where = t.pr ? t.pr : t.state === "done" ? dim(`local branch agent/${id}`) : dim(`logs/${id}.report.md`);
      out.push(`  ${icon} ${(t.title || id).slice(0, 40).padEnd(40)} ${dim(ago(now - Date.parse(t.updated)) + " ago")}  ${where}`);
    }
  }
  return out.join("\n");
}

process.stdout.write(render() + "\n");
