// Orchestrator: planner once, then generator <-> evaluator rounds. Control flow is a
// deterministic loop in this file; agents only read and write files.
//
//   node run.ts --prompt prompts/shotbox.md [--run-id r1] [--max-rounds 5]
//               [--models planner=sonnet,generator=haiku,evaluator=sonnet]
//               [--spec path/to/spec.md] [--app-name ShotBox] [--panel-port 4317]
//               [--budget-per-agent 20] [--allow-many-criteria] [--keep-panel] [--plan-only]

import { execFile } from "node:child_process";
import { cpSync, existsSync, mkdirSync, readFileSync, watch, writeFileSync, copyFileSync, type FSWatcher } from "node:fs";
import { join, resolve } from "node:path";
import { parseArgs } from "node:util";
import { EventLog, firstLine, type AgentName } from "./events.ts";
import { runAgent, type AgentOutcome } from "./agents/common.ts";
import { EVALUATOR, GENERATOR, PLANNER, PLANNER_TASK, evaluatorTask, generatorTask } from "./agents/prompts.ts";
import { parseCriteria, parseQaReport, scoreRound, type Criterion, type RoundScore } from "./criteria.ts";
import { startPanel } from "./panel/server.ts";

const ROOT = resolve(import.meta.dirname, "..");
const TOOLS = join(ROOT, "tools");
const RUNS = join(ROOT, "runs");

const MODEL_IDS: Record<string, string> = { haiku: "claude-haiku-5-5", sonnet: "claude-sonnet-5-5", opus: "claude-opus-5-5" };

const { values: args } = parseArgs({
  options: {
    prompt: { type: "string" },
    spec: { type: "string" },
    "run-id": { type: "string" },
    "max-rounds": { type: "string", default: "5" },
    models: { type: "string", default: "planner=sonnet,generator=haiku,evaluator=sonnet" },
    "app-name": { type: "string", default: "ShotBox" },
    "panel-port": { type: "string", default: "4317" },
    "budget-per-agent": { type: "string", default: "25" },
    "generator-turns": { type: "string", default: "250" },
    "evaluator-turns": { type: "string", default: "200" },
    "allow-many-criteria": { type: "boolean", default: false },
    "keep-panel": { type: "boolean", default: false },
    "plan-only": { type: "boolean", default: false },
  },
});

if (!args.prompt && !args.spec) {
  console.error("need --prompt <prompt.md> (or --spec <spec.md> to skip the planner)");
  process.exit(2);
}

const models = Object.fromEntries(
  args.models!.split(",").map((kv) => {
    const [k, v] = kv.split("=");
    return [k, MODEL_IDS[v] ?? v];
  }),
) as Record<"planner" | "generator" | "evaluator", string>;
const maxRounds = Number(args["max-rounds"]);
const appName = args["app-name"]!;
const budget = Number(args["budget-per-agent"]);
const runId = args["run-id"] ?? `r_${new Date().toISOString().replace(/[:.]/g, "-").slice(0, 19)}`;

const log = new EventLog(runId, RUNS);
const ws = join(log.dir, "app");
const orch = (round: number, type: Parameters<EventLog["emitEvent"]>[0]["type"], summary: string, payload: Record<string, unknown> = {}) =>
  log.emitEvent({ agent: "orchestrator", round, type, summary, payload });

function sh(cmd: string, argv: string[], cwd: string, timeoutMs = 600_000): Promise<{ code: number; out: string }> {
  return new Promise((ok) => {
    execFile(cmd, argv, { cwd, timeout: timeoutMs, maxBuffer: 64 * 1024 * 1024, env: { ...process.env, AXCLI: join(TOOLS, "axcli/.build/release/axcli") } },
      (err, stdout, stderr) => {
        const code = err ? (typeof (err as { code?: unknown }).code === "number" ? (err as { code: number }).code : 1) : 0;
        ok({ code, out: String(stdout) + String(stderr) });
      });
  });
}

// ---------------------------------------------------------------------------
// Workspace and artifact snapshots

function setupWorkspace() {
  if (!existsSync(ws)) {
    cpSync(join(ROOT, "app-template"), ws, { recursive: true });
    writeFileSync(join(ws, "app.env"), `APP_NAME=${appName}\nBUNDLE_ID=com.harness.${appName.toLowerCase()}\n`);
    if (args.prompt) copyFileSync(resolve(args.prompt), join(ws, "prompt.md"));
    // prompts/<name>.test.env sits next to the prompt and becomes the workspace's test.env.
    const testEnv = args.prompt?.replace(/\.md$/, ".test.env");
    if (testEnv && existsSync(testEnv)) copyFileSync(resolve(testEnv), join(ws, "test.env"));
    if (args.spec) copyFileSync(resolve(args.spec), join(ws, "spec.md"));
  }
}

const ARTIFACTS = ["spec.md", "handoff.md", "qa_report.md"];
let currentRound = 0;
const lastSnapshot = new Map<string, string>();

function snapshot(name: string, round = currentRound) {
  const src = join(ws, name);
  if (!existsSync(src)) return;
  const body = readFileSync(src, "utf8");
  const key = `${name}|${round}`;
  if (lastSnapshot.get(key) === body) return;
  lastSnapshot.set(key, body);
  const rel = `artifacts/r${round}/${name}`;
  mkdirSync(join(log.dir, `artifacts/r${round}`), { recursive: true });
  writeFileSync(join(log.dir, rel), body);
  orch(round, "artifact_written", name, { name, path: rel, bytes: body.length });
}

function watchArtifacts(): FSWatcher {
  const timers = new Map<string, NodeJS.Timeout>();
  return watch(ws, (_event, file) => {
    if (!file || !ARTIFACTS.includes(String(file))) return;
    clearTimeout(timers.get(String(file)));
    timers.set(String(file), setTimeout(() => snapshot(String(file)), 400));
  });
}

// ---------------------------------------------------------------------------
// Agents

const common = { appName, toolsDir: TOOLS, cwd: ws, maxBudgetUsd: budget };

function planner(): Promise<AgentOutcome> {
  return runAgent(log, {
    ...common, agent: "planner", round: 0, model: models.planner,
    rolePrompt: PLANNER, task: PLANNER_TASK,
    builtinTools: ["Read", "Write", "Glob"], macTools: false,
    writable: [join(ws, "spec.md")], maxTurns: 40,
  });
}

function generator(round: number, buildErrors: string | null): Promise<AgentOutcome> {
  return runAgent(log, {
    ...common, agent: "generator", round, model: models.generator,
    rolePrompt: GENERATOR.replaceAll("$APP_NAME", appName), task: generatorTask(round, appName, buildErrors),
    builtinTools: ["Bash", "Read", "Write", "Edit", "Glob", "Grep"], macTools: true,
    // Everything in the workspace except the files other agents own.
    writable: [join(ws, "Sources"), join(ws, "Tests"), join(ws, "Package.swift"), join(ws, "Package.resolved"), join(ws, "Info.plist"), join(ws, "handoff.md"), join(ws, "Resources")],
    maxTurns: Number(args["generator-turns"]),
  });
}

function evaluator(round: number): Promise<AgentOutcome> {
  return runAgent(log, {
    ...common, agent: "evaluator", round, model: models.evaluator,
    rolePrompt: EVALUATOR, task: evaluatorTask(round, appName),
    builtinTools: ["Bash", "Read", "Write", "Glob", "Grep"], macTools: true,
    writable: [join(ws, "qa_report.md")], maxTurns: Number(args["evaluator-turns"]),
  });
}

// ---------------------------------------------------------------------------
// Loop

interface RoundRecord { round: number; build_ok: boolean; score: RoundScore | null; generator: AgentOutcome; evaluator?: AgentOutcome }

async function main() {
  setupWorkspace();
  const panelUrl = await startPanel(RUNS, Number(args["panel-port"])).catch(() => null);
  console.log(`run ${runId}\nworkspace ${ws}\npanel ${panelUrl ? `${panelUrl}/?run=${runId}` : "(port busy; run node panel/server.ts)"}`);

  orch(0, "run_start", runId, { max_rounds: maxRounds, models, app: appName, workspace: ws });
  const watcher = watchArtifacts();
  let status = "incomplete";
  let reason = "";
  const rounds: RoundRecord[] = [];

  try {
    const init = await sh("./init.sh", [], ws, 120_000);
    if (!existsSync(join(ws, ".git"))) {
      await sh("git", ["init", "-q"], ws);
      await sh("git", ["add", "-A"], ws);
      await sh("git", ["-c", "user.name=harness", "-c", "user.email=harness@local", "commit", "-qm", "workspace from app-template"], ws);
    }
    orch(0, "build_result", init.code === 0 ? "init ok" : "init failed", { step: "init", ok: init.code === 0, output: init.out.slice(-1500) });
    if (init.code !== 0) throw new Stop("error", `init.sh failed: ${firstLine(init.out)}`);

    // 1. Planner (once), then parse criteria.
    if (!existsSync(join(ws, "spec.md"))) {
      const p = await planner();
      snapshot("spec.md", 0);
      if (!p.ok) throw new Stop("error", `planner ended with ${p.status}`);
    } else snapshot("spec.md", 0);

    let criteria: Criterion[];
    try {
      criteria = parseCriteria(readFileSync(join(ws, "spec.md"), "utf8"));
    } catch (e) {
      throw new Stop("spec_issue", `cannot parse criteria: ${(e as Error).message}`);
    }
    const hardCount = criteria.filter((c) => c.class === "hard").length;
    orch(0, "qa_verdict", `${criteria.length} criteria, ${hardCount} hard`, { step: "criteria", criteria: criteria.length, hard: hardCount });
    if (hardCount > 40 && !args["allow-many-criteria"]) {
      throw new Stop("needs_trim", `${hardCount} hard criteria; trim spec.md to 25-30 and rerun with --spec`);
    }

    if (args["plan-only"]) throw new Stop("planned", `spec.md written: ${hardCount} hard of ${criteria.length} criteria; review it, then rerun with --spec`);

    // 2-5. Generator <-> evaluator rounds.
    let buildErrors: string | null = null;
    const passHistory: number[] = [];
    for (let round = 1; round <= maxRounds; round++) {
      currentRound = round;
      orch(round, "round_start", `round ${round}`);

      const gen = await generator(round, buildErrors);
      snapshot("handoff.md", round);
      const rec: RoundRecord = { round, build_ok: false, score: null, generator: gen };
      rounds.push(rec);

      const build = await sh("./build.sh", [], ws);
      rec.build_ok = build.code === 0;
      log.writeRaw("orchestrator", round, "build", build.out);
      orch(round, "build_result", rec.build_ok ? "build ok" : "build failed", { ok: rec.build_ok, output: build.out.slice(-1500) });

      if (!rec.build_ok) {
        // Broken build: straight back to the generator, QA skipped.
        buildErrors = build.out;
        passHistory.push(passHistory.at(-1) ?? 0);
      } else {
        buildErrors = null;
        rec.evaluator = await evaluator(round);
        await sh("pkill", ["-x", appName], ws);
        snapshot("qa_report.md", round);
        try {
          const verdict = parseQaReport(readFileSync(join(ws, "qa_report.md"), "utf8"));
          rec.score = scoreRound(criteria, verdict);
          orch(round, "qa_verdict", `${rec.score.hard_pass}/${rec.score.hard_total} hard pass`, { ...rec.score });
          passHistory.push(rec.score.hard_pass);
        } catch (e) {
          orch(round, "error", `qa_report.md unreadable: ${(e as Error).message}`, {});
          passHistory.push(passHistory.at(-1) ?? 0);
        }
        // QA must not leave a stale report that the next round could mistake for fresh.
        await sh("git", ["add", "-A"], ws);
        await sh("git", ["-c", "user.name=harness", "-c", "user.email=harness@local", "commit", "-qm", `QA report round ${round}`], ws);
      }

      orch(round, "round_end", `round ${round} done`, { build_ok: rec.build_ok, hard_pass: rec.score?.hard_pass ?? null });

      // Termination rules.
      if (rec.score?.spec_issue) throw new Stop("spec_issue", rec.score.spec_issue_reason || "evaluator flagged a spec issue; ask a human");
      if (rec.score && rec.score.hard_pass === rec.score.hard_total) throw new Stop("done", "all hard criteria pass");
      const n = passHistory.length;
      if (n >= 3 && passHistory[n - 1] <= passHistory[n - 2] && passHistory[n - 2] <= passHistory[n - 3]) {
        throw new Stop("stalled", "hard pass count did not increase for two consecutive rounds");
      }
      if (!gen.ok && (gen.status === "error" || gen.status === "error_during_execution")) {
        throw new Stop("error", `generator ended with ${gen.status}`);
      }
    }
    status = "incomplete";
    reason = `max_rounds (${maxRounds}) reached`;
  } catch (e) {
    if (e instanceof Stop) { status = e.status; reason = e.reason; }
    else { status = "error"; reason = (e as Error).stack ?? String(e); orch(currentRound, "error", firstLine(reason), { stack: reason }); }
  } finally {
    watcher.close();
    await sh("pkill", ["-x", appName], ws);
  }

  orch(currentRound, "run_end", `${status}: ${reason}`, { status, reason });
  writeSummary(status, reason, rounds);
  console.log(`\n${status}: ${reason}\nsummary: ${join(log.dir, "summary.md")}`);
  if (!args["keep-panel"]) process.exit(status === "done" || status === "planned" ? 0 : 1);
}

class Stop extends Error {
  status: string;
  reason: string;
  constructor(status: string, reason: string) {
    super(reason);
    this.status = status;
    this.reason = reason;
  }
}

// ---------------------------------------------------------------------------
// Token and cost breakdown per agent per round

function writeSummary(status: string, reason: string, rounds: RoundRecord[]) {
  const rows = log.query<{ agent: AgentName; round: number; input: number; output: number; cost: number; tools: number }>(
    `SELECT agent, round, SUM(COALESCE(input_tokens,0)) input, SUM(COALESCE(output_tokens,0)) output,
            SUM(COALESCE(cost_usd,0)) cost, SUM(type='tool_use') tools
     FROM events WHERE agent != 'orchestrator' GROUP BY agent, round ORDER BY round, agent`,
  );
  const sdk = log.query<{ agent: string; round: number; payload: string }>(`SELECT agent, round, payload FROM events WHERE type='agent_end'`);
  const sdkCost = new Map(sdk.map((r) => [`${r.agent}|${r.round}`, JSON.parse(r.payload).sdk_cost_usd as number | null]));
  const totalCost = rows.reduce((s, r) => s + r.cost, 0);

  const md = [
    `# Run ${runId}`, "",
    `Status: **${status}** (${reason})`, "",
    `Models: planner ${models.planner}, generator ${models.generator}, evaluator ${models.evaluator}`, "",
    "## Hard criteria per round", "",
    "| round | build | hard pass | soft pass | scores |", "|---|---|---|---|---|",
    ...rounds.map((r) => `| ${r.round} | ${r.build_ok ? "ok" : "broken"} | ${r.score ? `${r.score.hard_pass}/${r.score.hard_total}` : "-"} | ${r.score ? `${r.score.soft_pass}/${r.score.soft_total}` : "-"} | ${r.score ? Object.entries(r.score.scores).map(([k, v]) => `${k} ${v}`).join(", ") : "-"} |`),
    "", "## Tokens and cost per agent per round", "",
    "`cost` sums the event stream; each agent_end corrects it to the Agent SDK's own figure (`sdk cost`). They differ only if a session crashed.", "",
    "| round | agent | input tokens | output tokens | tool calls | cost | sdk cost |", "|---|---|---|---|---|---|---|",
    ...rows.map((r) => {
      const s = sdkCost.get(`${r.agent}|${r.round}`);
      return `| ${r.round} | ${r.agent} | ${r.input} | ${r.output} | ${r.tools} | $${r.cost.toFixed(4)} | ${s == null ? "-" : "$" + s.toFixed(4)} |`;
    }),
    `| | **total** | ${rows.reduce((s, r) => s + r.input, 0)} | ${rows.reduce((s, r) => s + r.output, 0)} | ${rows.reduce((s, r) => s + r.tools, 0)} | **$${totalCost.toFixed(4)}** | |`,
    "",
  ].join("\n");
  writeFileSync(join(log.dir, "summary.md"), md);
  writeFileSync(join(log.dir, "summary.json"), JSON.stringify({ runId, status, reason, models, rounds: rounds.map((r) => ({ round: r.round, build_ok: r.build_ok, score: r.score })), cost: rows }, null, 2));
}

process.on("SIGINT", () => {
  orch(currentRound, "run_end", "aborted by user", { status: "aborted" });
  process.exit(130);
});

await main();
