// Shared parts of both loops (run.ts = classic, evolve.ts = self-improving):
// workspace setup, artifact snapshots, shell, git, the three core agents and the summary.

import { execFile, spawn } from "node:child_process";
import { copyFileSync, cpSync, existsSync, mkdirSync, readFileSync, watch, writeFileSync, type FSWatcher } from "node:fs";
import { join, resolve } from "node:path";
import { EventLog, type AgentName, type EventType } from "./events.ts";
import { runAgent, usageWindow, type AgentOutcome, type AgentRun } from "./agents/common.ts";
import { EVALUATOR, GENERATOR, PLANNER, PLANNER_TASK, evaluatorTask, generatorTask } from "./agents/prompts.ts";
import type { RoundScore } from "./criteria.ts";

export const ROOT = resolve(import.meta.dirname, "..");
export const TOOLS = join(ROOT, "tools");
export const RUNS = join(ROOT, "runs");
export const MODEL_IDS: Record<string, string> = { haiku: "claude-haiku-5-5", sonnet: "claude-sonnet-5-5", opus: "claude-opus-5-5" };

export function parseModels(spec: string): Record<string, string> {
  return Object.fromEntries(spec.split(",").map((kv) => { const [k, v] = kv.split("="); return [k, MODEL_IDS[v] ?? v]; }));
}

export class Stop extends Error {
  status: string;
  reason: string;
  constructor(status: string, reason: string) {
    super(reason);
    this.status = status;
    this.reason = reason;
  }
}

export interface HarnessOptions {
  runId: string;
  appName: string;
  models: Record<string, string>;
  budgetPerAgent: number;
  generatorTurns: number;
  evaluatorTurns: number;
}

const GIT = ["-c", "user.name=harness", "-c", "user.email=harness@local"];
const ARTIFACTS = ["spec.md", "handoff.md", "qa_report.md"];

export class Harness {
  readonly log: EventLog;
  readonly ws: string;
  readonly opts: HarnessOptions;
  round = 0;
  private lastSnapshot = new Map<string, string>();

  constructor(opts: HarnessOptions) {
    this.opts = opts;
    this.log = new EventLog(opts.runId, RUNS);
    this.ws = join(this.log.dir, "app");
  }

  emit(round: number, type: EventType, summary: string, payload: Record<string, unknown> = {}) {
    return this.log.emitEvent({ agent: "orchestrator", round, type, summary, payload });
  }

  sh(cmd: string, argv: string[], cwd = this.ws, timeoutMs = 600_000): Promise<{ code: number; out: string }> {
    return new Promise((ok) => {
      execFile(cmd, argv, { cwd, timeout: timeoutMs, maxBuffer: 64 * 1024 * 1024, env: { ...process.env, AXCLI: join(TOOLS, "axcli/.build/release/axcli") } },
        (err, stdout, stderr) => {
          const code = err ? (typeof (err as { code?: unknown }).code === "number" ? (err as { code: number }).code : 1) : 0;
          ok({ code, out: String(stdout) + String(stderr) });
        });
    });
  }

  git(...argv: string[]) { return this.sh("git", [...GIT, ...argv]); }
  async commit(message: string) { await this.git("add", "-A"); await this.git("commit", "-qm", message); return (await this.git("rev-parse", "HEAD")).out.trim(); }

  // ---------------------------------------------------------------- workspace

  /** A new workspace from app-template, or a clone of an earlier run's workspace (its git history comes along). */
  async setupWorkspace(src: { prompt?: string; spec?: string; fromRun?: string }) {
    if (existsSync(this.ws)) return;
    if (src.fromRun) {
      const from = join(RUNS, src.fromRun, "app");
      if (!existsSync(from)) throw new Stop("error", `--from-run: ${from} does not exist`);
      await this.sh("git", ["clone", "-q", from, this.ws], RUNS);
      // Untracked harness files that the clone does not carry.
      for (const f of ["test.env", "prompt.md"]) if (existsSync(join(from, f)) && !existsSync(join(this.ws, f))) copyFileSync(join(from, f), join(this.ws, f));
    } else {
      cpSync(join(ROOT, "app-template"), this.ws, { recursive: true });
      writeFileSync(join(this.ws, "app.env"), `APP_NAME=${this.opts.appName}\nBUNDLE_ID=com.harness.${this.opts.appName.toLowerCase()}\n`);
    }
    if (src.prompt) {
      copyFileSync(resolve(src.prompt), join(this.ws, "prompt.md"));
      const testEnv = src.prompt.replace(/\.md$/, ".test.env");
      if (existsSync(testEnv)) copyFileSync(resolve(testEnv), join(this.ws, "test.env"));
    }
    if (src.spec) copyFileSync(resolve(src.spec), join(this.ws, "spec.md"));
  }

  async init() {
    const init = await this.sh("./init.sh", [], this.ws, 120_000);
    if (!existsSync(join(this.ws, ".git"))) {
      await this.git("init", "-q");
      await this.commit("workspace from app-template");
    }
    this.emit(0, "build_result", init.code === 0 ? "init ok" : "init failed", { step: "init", ok: init.code === 0, output: init.out.slice(-1500) });
    if (init.code !== 0) throw new Stop("error", `init.sh failed: ${init.out.trim().split("\n")[0]}`);
  }

  async build(round: number) {
    const build = await this.sh("./build.sh", []);
    const ok = build.code === 0;
    this.log.writeRaw("orchestrator", round, "build", build.out);
    this.emit(round, "build_result", ok ? "build ok" : "build failed", { ok, output: build.out.slice(-1500) });
    return { ok, out: build.out };
  }

  // ---------------------------------------------------------------- snapshots

  snapshot(name: string, round = this.round, dir = this.ws, publishAs = name) {
    const src = join(dir, name);
    if (!existsSync(src)) return;
    const body = readFileSync(src, "utf8");
    const key = `${publishAs}|${round}`;
    if (this.lastSnapshot.get(key) === body) return;
    this.lastSnapshot.set(key, body);
    const rel = `artifacts/r${round}/${publishAs}`;
    mkdirSync(join(this.log.dir, rel, ".."), { recursive: true });
    writeFileSync(join(this.log.dir, rel), body);
    this.emit(round, "artifact_written", publishAs, { name: publishAs, path: rel, bytes: body.length });
  }

  watchArtifacts(extra: string[] = []): FSWatcher {
    const timers = new Map<string, NodeJS.Timeout>();
    const names = [...ARTIFACTS, ...extra];
    return watch(this.ws, { recursive: true }, (_event, file) => {
      const f = String(file ?? "");
      if (!names.includes(f)) return;
      clearTimeout(timers.get(f));
      timers.set(f, setTimeout(() => this.snapshot(f, this.round, this.ws, f.split("/").pop()), 400));
    });
  }

  // ---------------------------------------------------------------- agents

  async agent(run: Omit<AgentRun, "appName" | "toolsDir" | "cwd" | "maxBudgetUsd"> & { cwd?: string }): Promise<AgentOutcome> {
    // Agents that look at the app need an unlocked screen; on a locked one every check fails.
    if (!run.macTools) return runAgent(this.log, { appName: this.opts.appName, toolsDir: TOOLS, cwd: this.ws, maxBudgetUsd: this.opts.budgetPerAgent, ...run });
    await this.waitForScreen(run.round);
    // Sample the lock state while the agent works: a verdict taken on a locked screen is void.
    let lockedDuring = false;
    const timer = setInterval(async () => { if (await this.screenLocked()) lockedDuring = true; }, 30_000);
    try {
      const o = await runAgent(this.log, { appName: this.opts.appName, toolsDir: TOOLS, cwd: this.ws, maxBudgetUsd: this.opts.budgetPerAgent, ...run });
      if (lockedDuring || (await this.screenLocked())) {
        o.screenLocked = true;
        this.emit(run.round, "paused", `screen was locked while ${run.agent} worked; its results are not trusted`, { reason: "screen_locked_during", agent: run.agent });
      }
      return o;
    } finally {
      clearInterval(timer);
    }
  }

  planner(): Promise<AgentOutcome> {
    return this.agent({
      agent: "planner", round: 0, model: this.opts.models.planner, rolePrompt: PLANNER, task: PLANNER_TASK,
      builtinTools: ["Read", "Write", "Glob"], macTools: false, writable: [join(this.ws, "spec.md")], maxTurns: 40,
    });
  }

  /** Paths the generator may Write/Edit: the app, not the files other agents own. */
  generatorWritable(ws = this.ws) {
    return ["Sources", "Tests", "Package.swift", "Package.resolved", "Info.plist", "handoff.md", "Resources"].map((p) => join(ws, p));
  }

  /** True when the workspace came from an earlier run: round 1 then fixes, it does not build from scratch. */
  continuing = false;
  /** Workspace-relative paths the generator may not write (design files a sprint owns). */
  protectedPaths: string[] = [];

  generator(round: number, buildErrors: string | null, extraTask = ""): Promise<AgentOutcome> {
    return this.agent({
      agent: "generator", round, model: this.opts.models.generator,
      rolePrompt: GENERATOR.replaceAll("$APP_NAME", this.opts.appName),
      task: generatorTask(round, this.opts.appName, buildErrors, this.continuing) + (extraTask ? "\n\n" + extraTask : ""),
      builtinTools: ["Bash", "Read", "Write", "Edit", "Glob", "Grep"], macTools: true,
      writable: this.generatorWritable(), denied: this.protectedPaths.map((p) => join(this.ws, p)),
      maxTurns: this.opts.generatorTurns,
    });
  }

  evaluator(round: number, extraTask = ""): Promise<AgentOutcome> {
    return this.agent({
      agent: "evaluator", round, model: this.opts.models.evaluator, rolePrompt: EVALUATOR,
      task: evaluatorTask(round, this.opts.appName) + (extraTask ? "\n\n" + extraTask : ""),
      builtinTools: ["Bash", "Read", "Write", "Glob", "Grep"], macTools: true,
      writable: [join(this.ws, "qa_report.md")], maxTurns: this.opts.evaluatorTurns,
    });
  }

  // ---------------------------------------------------------------- screen

  /** Keeps the display awake for this process's lifetime, so idle sleep does not lock the screen. */
  keepAwake() {
    const c = spawn("caffeinate", ["-di", "-w", String(process.pid)], { stdio: "ignore", detached: true });
    c.unref();
  }

  async screenLocked(): Promise<boolean> {
    const r = await this.sh(join(TOOLS, "axcli/.build/release/axcli"), ["check"]);
    // Blocked means the accessibility API returns nothing; the lock flag is the fallback.
    try { const c = JSON.parse(r.out); return c.ax_usable === false || (c.ax_usable == null && c.screen_locked === true); } catch { return false; }
  }

  /** Waits (checking every 30 s) while the screen is locked. Returns the minutes waited. */
  async waitForScreen(round: number): Promise<number> {
    if (!(await this.screenLocked())) return 0;
    const t0 = Date.now();
    this.emit(round, "paused", "screen is locked: waiting for it to be unlocked", { reason: "screen_locked" });
    while (await this.screenLocked()) await new Promise((r) => setTimeout(r, 30_000));
    const mins = Math.round((Date.now() - t0) / 60000);
    this.emit(round, "paused", `screen unlocked after ${mins} min: resuming`, { resumed: true });
    return mins;
  }

  // ---------------------------------------------------------------- budget

  totalCost(): number {
    return this.log.query<{ c: number }>("SELECT COALESCE(SUM(cost_usd),0) c FROM events")[0]?.c ?? 0;
  }

  /**
   * The Team seat's 5-hour window is the real limit. Above `cap` utilisation, wait for the
   * reset instead of failing mid-round. Returns the minutes waited.
   */
  async waitForWindow(cap: number, round: number): Promise<number> {
    const w = usageWindow();
    if (w.fiveHour == null || (w.fiveHour < cap && w.status !== "rejected")) return 0;
    const until = (w.resetsAt ?? Date.now() / 1000 + 600) * 1000 + 60_000;
    const mins = Math.max(1, Math.round((until - Date.now()) / 60000));
    this.emit(round, "paused", `5-hour window at ${Math.round(w.fiveHour * 100)}%: waiting ${mins} min for the reset`, { five_hour: w.fiveHour, resets_at: w.resetsAt, wait_min: mins });
    await new Promise((r) => setTimeout(r, Math.max(0, until - Date.now())));
    this.emit(round, "paused", "window reset: resuming", { resumed: true });
    return mins;
  }

  // ---------------------------------------------------------------- summary

  writeSummary(status: string, reason: string, rounds: { round: number; build_ok: boolean; score: RoundScore | null; note?: string }[], extra = "") {
    const rows = this.log.query<{ agent: AgentName; round: number; input: number; output: number; cost: number; tools: number }>(
      `SELECT agent, round, SUM(COALESCE(input_tokens,0)) input, SUM(COALESCE(output_tokens,0)) output,
              SUM(COALESCE(cost_usd,0)) cost, SUM(type='tool_use') tools
       FROM events WHERE agent != 'orchestrator' GROUP BY agent, round ORDER BY round, agent`,
    );
    const sdk = this.log.query<{ agent: string; round: number; payload: string }>(`SELECT agent, round, payload FROM events WHERE type='agent_end'`);
    const sdkCost = new Map<string, number>();
    for (const r of sdk) { const c = JSON.parse(r.payload).sdk_cost_usd as number | null; if (c != null) sdkCost.set(`${r.agent}|${r.round}`, (sdkCost.get(`${r.agent}|${r.round}`) ?? 0) + c); }
    const totalCost = rows.reduce((s, r) => s + r.cost, 0);
    const m = this.opts.models;
    const md = [
      `# Run ${this.opts.runId}`, "",
      `Status: **${status}** (${reason})`, "",
      `Models: ${Object.entries(m).map(([k, v]) => `${k} ${v}`).join(", ")}`, "",
      "## Hard criteria per round", "",
      "| round | build | hard pass | soft pass | scores | note |", "|---|---|---|---|---|---|",
      ...rounds.map((r) => `| ${r.round} | ${r.build_ok ? "ok" : "broken"} | ${r.score ? `${r.score.hard_pass}/${r.score.hard_total}` : "-"} | ${r.score ? `${r.score.soft_pass}/${r.score.soft_total}` : "-"} | ${r.score ? Object.entries(r.score.scores).map(([k, v]) => `${k} ${v}`).join(", ") : "-"} | ${r.note ?? ""} |`),
      extra,
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
    writeFileSync(join(this.log.dir, "summary.md"), md);
    writeFileSync(join(this.log.dir, "summary.json"), JSON.stringify({ runId: this.opts.runId, status, reason, models: m, rounds, cost: rows }, null, 2));
  }
}
