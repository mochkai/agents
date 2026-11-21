#!/usr/bin/env node
// Live monitor for the agent farm: what each running task is doing right now.
//   node bin/watch.js            print once
//   bin/watch.sh [seconds]       refresh continuously (default every 5 s)
//
// It reads state/status.json for the task list, plus the session transcripts Claude Code writes under
// ~/.claude/projects/<worktree-path>/ to see which agent is active and what it last did.
// It is read-only and uses no API calls, so it costs nothing to run.
const fs = require("fs");
const os = require("os");
const path = require("path");

const FARM = path.join(__dirname, "..");
const PROJECTS = path.join(os.homedir(), ".claude", "projects");
const STALE_MIN = Number(process.env.STALE_MINUTES || 10);
const tty = process.stdout.isTTY;
const c = (code, s) => (tty ? `\x1b[${code}m${s}\x1b[0m` : s);
const dim = (s) => c(2, s), bold = (s) => c(1, s), green = (s) => c(32, s), red = (s) => c(31, s), yellow = (s) => c(33, s), cyan = (s) => c(36, s);

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

/** Parse a .jsonl transcript, skipping lines that are partial or malformed. */
function readJsonl(file) {
  try {
    return fs.readFileSync(file, "utf8").split("\n").filter(Boolean).flatMap((l) => {
      try { return [JSON.parse(l)]; } catch { return []; }
    });
  } catch { return []; }
}

/** One-line summary of an assistant action: a tool call, or the start of its text. */
function describe(entry) {
  const parts = entry?.message?.content;
  if (!Array.isArray(parts)) return null;
  const tool = [...parts].reverse().find((p) => p.type === "tool_use");
  if (tool) {
    const i = tool.input || {};
    if (tool.name === "Agent") return `→ delegating to ${i.subagent_type}: ${i.description || ""}`;
    const arg = i.command || i.file_path || i.pattern || i.description || "";
    return `${tool.name} ${String(arg).replace(/\s+/g, " ")}`;
  }
  const text = parts.find((p) => p.type === "text")?.text;
  return text ? `“${text.replace(/\s+/g, " ")}”` : null;
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

/** Inspect the orchestrator session and its subagents for one task's worktree. */
function inspect(worktree) {
  const dir = path.join(PROJECTS, worktree.replace(/[^a-zA-Z0-9]/g, "-"));
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
    .filter((p) => p.type === "tool_use" && p.name === "Agent").map((p) => p.input?.subagent_type).filter(Boolean);

  // The most recently active transcript (the orchestrator itself or a subagent) is the active agent
  const candidates = [{ agent: "orchestrator", file: main }];
  const subDir = main.replace(/\.jsonl$/, "") + "/subagents";
  try {
    for (const f of fs.readdirSync(subDir).filter((f) => f.endsWith(".jsonl"))) {
      let agent = "subagent";
      try { agent = JSON.parse(fs.readFileSync(path.join(subDir, f.replace(/\.jsonl$/, ".meta.json")), "utf8")).agentType || agent; } catch {}
      candidates.push({ agent, file: path.join(subDir, f) });
    }
  } catch {}
  const active = candidates.map((x) => ({ ...x, mtime: fs.statSync(x.file).mtimeMs }))
    .sort((a, b) => b.mtime - a.mtime)[0];
  return { sequence, active: active.agent, last: lastAction(readJsonl(active.file)), lastWrite: active.mtime };
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
  out.push(`running ${bold(String(running.length))}   queued ${bold(String(inbox))}`);
  out.push("");

  if (!running.length) out.push(dim("  no tasks running"));
  for (const [id, t] of running) {
    const started = Date.parse(t.updated) || now;
    const procAlive = t.pid ? alive(t.pid) : true;
    out.push(`${procAlive ? green("●") : red("●")} ${bold(t.title || id)}  ${dim(id)}`);
    out.push(`  ${dim("repo")} ${t.repo || "?"}   ${dim("running for")} ${ago(now - started)}   ${dim("model")} ${t.model || "?"}`);
    if (!procAlive) { out.push(red("  ! runner process is gone: it crashed or was killed. Check logs/" + id + ".err")); out.push(""); continue; }
    const info = t.branch ? inspect(path.join(FARM, "worktrees", id)) : null;
    if (!info) { out.push(dim("  starting up…")); out.push(""); continue; }
    const idle = now - info.lastWrite;
    const flow = info.sequence.length ? info.sequence.join(" → ") : "planning";
    out.push(`  ${dim("agents")}  ${flow}`);
    out.push(`  ${dim("active")}  ${cyan(info.active)}${idle > STALE_MIN * 60000 ? yellow(`   ⚠ no activity for ${ago(idle)} (stuck or waiting on a long command?)`) : dim(`   (last activity ${ago(idle)} ago)`)}`);
    if (info.last) out.push(`  ${dim("doing")}   ${info.last.what.slice(0, width - 10)}`);
    out.push("");
  }

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
