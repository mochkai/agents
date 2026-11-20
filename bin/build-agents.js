#!/usr/bin/env node
// Converts agents/*.md (frontmatter + prompt body) into the JSON format
// that `claude --agents <file>` expects. Usage: build-agents.js <agents-dir>
const fs = require("fs");
const path = require("path");

const dir = process.argv[2];
const out = {};
for (const file of fs.readdirSync(dir).filter((f) => f.endsWith(".md"))) {
  const text = fs.readFileSync(path.join(dir, file), "utf8");
  const m = text.match(/^---\n([\s\S]*?)\n---\n([\s\S]*)$/);
  if (!m) throw new Error(`${file}: missing --- frontmatter ---`);
  const meta = Object.fromEntries(
    m[1].split("\n").filter(Boolean).map((line) => {
      const i = line.indexOf(":");
      return [line.slice(0, i).trim(), line.slice(i + 1).trim()];
    })
  );
  const agent = { description: meta.description, prompt: m[2].trim() };
  if (meta.model && meta.model !== "inherit") agent.model = meta.model;
  if (meta.tools) agent.tools = meta.tools.split(",").map((t) => t.trim());
  // skills: comma list; bare names refer to the my-skills library (~/skills)
  if (meta.skills)
    agent.skills = meta.skills.split(",").map((s) => s.trim()).filter(Boolean)
      .map((s) => (s.includes(":") ? s : `my-skills:${s}`));
  out[path.basename(file, ".md")] = agent;
}
process.stdout.write(JSON.stringify(out, null, 2));
