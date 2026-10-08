// Fake run for testing events.ts and the panel without spending tokens.
// Feeds synthetic SDK messages through SdkNormalizer, writes artifacts and a screenshot.
//   node fake.ts [--fast]

import { copyFileSync, existsSync, mkdirSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { EventLog, SdkNormalizer, type AgentName } from "./events.ts";
import { startPanel } from "./panel/server.ts";

const RUNS = resolve(import.meta.dirname, "..", "runs");
const fast = process.argv.includes("--fast");
const sleep = (ms: number) => new Promise((r) => setTimeout(r, fast ? 0 : ms));
const runId = `fake_${new Date().toISOString().replace(/[:.]/g, "-").slice(0, 19)}`;
const log = new EventLog(runId, RUNS);
const models = { planner: "claude-sonnet-5-5", generator: "claude-haiku-5-5", evaluator: "claude-sonnet-5-5" };

let msgId = 0;
let toolId = 0;

async function fakeAgent(agent: AgentName, round: number, steps: [string, string][], say: string) {
  const model = models[agent as keyof typeof models];
  const n = new SdkNormalizer(log, agent, round, model);
  log.emitEvent({ agent, round, type: "agent_start", payload: { model } });
  let ctx = 20000;
  for (const [tool, arg] of steps) {
    ctx += 3000;
    const id = `toolu_${++toolId}`;
    const usage = { input_tokens: 500, cache_read_input_tokens: ctx - 500, output_tokens: 300 };
    // Same message id twice: the second frame must not double-count usage.
    n.handle({ type: "assistant", parent_tool_use_id: null, message: { id: `msg_${++msgId}`, model, usage, content: [{ type: "text", text: say + ` (${tool})` }] } });
    n.handle({ type: "assistant", parent_tool_use_id: null, message: { id: `msg_${msgId}`, model, usage, content: [{ type: "tool_use", id, name: `mcp__mac__${tool}`, input: { command: arg } }] } });
    await sleep(700);
    if (tool === "screenshot") {
      const rel = `screenshots/r${round}_${agent}_${toolId}.png`;
      const src = "/private/tmp/claude-501/calc.png";
      if (existsSync(src)) copyFileSync(src, join(log.dir, rel));
    }
    const out = tool === "screenshot" ? `saved: screenshots/r${round}_${agent}_${toolId}.png` : `ok: ${arg}\nline 2 of output`;
    n.handle({ type: "user", parent_tool_use_id: null, message: { content: [{ type: "tool_result", tool_use_id: id, content: out }] } });
  }
  log.emitEvent({ agent, round, type: "agent_end", payload: { status: "ok", context_tokens: n.lastContextTokens, ...n.totals } });
  return n.totals;
}

function writeArtifact(name: string, round: number, body: string) {
  const rel = `artifacts/r${round}/${name}`;
  mkdirSync(join(log.dir, `artifacts/r${round}`), { recursive: true });
  writeFileSync(join(log.dir, rel), body);
  log.emitEvent({ agent: "orchestrator", round, type: "artifact_written", summary: name, payload: { name, path: rel } });
}

const url = await startPanel(RUNS, 4317);
console.log(`panel: ${url}  run: ${runId}`);
log.emitEvent({ agent: "orchestrator", round: 0, type: "run_start", payload: { max_rounds: 3, models, app: "ShotBox" } });

await fakeAgent("planner", 0, [["Read", "prompt.md"], ["Write", "spec.md"]], "Writing the spec");
writeArtifact("spec.md", 0, "# ShotBox\n\n## Criteria\n- H1 grid shows\n- H2 search works\n- H3 pin works\n");

const passes = [3, 5, 8];
for (let r = 1; r <= 3; r++) {
  log.emitEvent({ agent: "orchestrator", round: r, type: "round_start", payload: {} });
  await fakeAgent("generator", r, [["Bash", "cat handoff.md"], ["Edit", "ShotBox/GridView.swift"], ["Bash", "./build.sh"]], `Round ${r}: fixing failing items`);
  writeArtifact("handoff.md", r, `# Handoff r${r}\n\n- changed grid\n- fixed item ${r}\n- still missing: ${3 - r} things\n`);
  const ok = r !== 2 || fast;
  log.emitEvent({ agent: "orchestrator", round: r, type: "build_result", summary: ok ? "build ok" : "build failed", payload: { ok } });
  await fakeAgent("evaluator", r, [["ax_tree", "w0"], ["screenshot", "ShotBox"], ["ax_click", "@Pin"], ["screenshot", "ShotBox"]], "Checking criteria");
  writeArtifact("qa_report.md", r, `# QA r${r}\n\nPASS ${passes[r - 1]}/10\n\n- FAIL H${r + 3}: search empty state\n`);
  log.emitEvent({ agent: "orchestrator", round: r, type: "qa_verdict", summary: `${passes[r - 1]}/10 hard pass`, payload: { hard_pass: passes[r - 1], hard_total: 10, spec_issue: false } });
  log.emitEvent({ agent: "orchestrator", round: r, type: "round_end", payload: {} });
}
log.emitEvent({ agent: "orchestrator", round: 3, type: "run_end", payload: { status: "incomplete" } });

const sums = log.query<{ agent: string; round: number; cost: number; n: number }>(
  "SELECT agent, round, SUM(cost_usd) cost, COUNT(*) n FROM events GROUP BY agent, round ORDER BY round, agent",
);
console.table(sums);
if (fast) process.exit(0);
console.log("fake run complete; panel still serving (Ctrl-C to stop)");
