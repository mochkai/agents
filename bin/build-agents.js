#!/usr/bin/env node
// Agent profile tools for the farm.
//   build-agents.js <agents-dir>          print the subagent JSON that `claude --agents <file>` expects
//                                         (profiles with `role: main` are skipped: they run as the main session)
//   build-agents.js --body <profile.md>   print just the prompt body of one profile
const fs = require("fs");
const path = require("path");

/** Parse a profile file into { meta, body }. Frontmatter is simple `key: value` lines. */
function parse(file) {
  const text = fs.readFileSync(file, "utf8");
  const m = text.match(/^---\n([\s\S]*?)\n---\n([\s\S]*)$/);
  if (!m) throw new Error(`${path.basename(file)}: missing --- frontmatter ---`);
  const meta = Object.fromEntries(
    m[1].split("\n").filter(Boolean).map((line) => {
      const i = line.indexOf(":");
      return [line.slice(0, i).trim(), line.slice(i + 1).trim()];
    })
  );
  return { meta, body: m[2].trim() };
}

const list = (v) => v.split(",").map((s) => s.trim()).filter(Boolean);

if (process.argv[2] === "--body") {
  process.stdout.write(parse(process.argv[3]).body + "\n");
} else {
  const dir = process.argv[2];
  const out = {};
  for (const file of fs.readdirSync(dir).filter((f) => f.endsWith(".md"))) {
    const { meta, body } = parse(path.join(dir, file));
    if (meta.role === "main") continue;
    const agent = { description: meta.description, prompt: body };
    if (meta.model && meta.model !== "inherit") agent.model = meta.model;
    if (meta.tools) agent.tools = list(meta.tools);
    if (meta.skills) agent.skills = list(meta.skills);
    out[meta.name || path.basename(file, ".md")] = agent;
  }
  process.stdout.write(JSON.stringify(out, null, 2));
}
