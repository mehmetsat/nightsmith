// Classic loop: planner once, then generator <-> evaluator rounds until every hard
// criterion passes. The ceiling is the planner's spec. For the self-improving loop see evolve.ts.
//
//   node run.ts --prompt prompts/shotbox.md [--run-id r1] [--max-rounds 5]
//               [--models planner=sonnet,generator=haiku,evaluator=sonnet]
//               [--spec path/to/spec.md] [--app-name ShotBox] [--panel-port 4317]
//               [--budget-per-agent 20] [--allow-many-criteria] [--keep-panel] [--plan-only]

import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { parseArgs } from "node:util";
import { firstLine } from "./events.ts";
import type { AgentOutcome } from "./agents/common.ts";
import { parseCriteria, parseQaReport, scoreRound, type Criterion, type RoundScore } from "./criteria.ts";
import { startPanel } from "./panel/server.ts";
import { Harness, RUNS, Stop, parseModels } from "./harness.ts";

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

const maxRounds = Number(args["max-rounds"]);
const appName = args["app-name"]!;
const runId = args["run-id"] ?? `r_${new Date().toISOString().replace(/[:.]/g, "-").slice(0, 19)}`;
const h = new Harness({
  runId, appName, models: parseModels(args.models!), budgetPerAgent: Number(args["budget-per-agent"]),
  generatorTurns: Number(args["generator-turns"]), evaluatorTurns: Number(args["evaluator-turns"]),
});

interface RoundRecord { round: number; build_ok: boolean; score: RoundScore | null; generator: AgentOutcome; evaluator?: AgentOutcome }

async function main() {
  await h.setupWorkspace({ prompt: args.prompt, spec: args.spec });
  h.keepAwake();
  const panelUrl = await startPanel(RUNS, Number(args["panel-port"])).catch(() => null);
  console.log(`run ${runId}\nworkspace ${h.ws}\npanel ${panelUrl ? `${panelUrl}/?run=${runId}` : "(port busy; run node panel/server.ts)"}`);

  h.emit(0, "run_start", runId, { max_rounds: maxRounds, models: h.opts.models, app: appName, workspace: h.ws, mode: "classic" });
  const watcher = h.watchArtifacts();
  let status = "incomplete";
  let reason = "";
  const rounds: RoundRecord[] = [];

  try {
    await h.init();

    // 1. Planner (once), then parse criteria.
    if (!existsSync(join(h.ws, "spec.md"))) {
      const p = await h.planner();
      h.snapshot("spec.md", 0);
      if (!p.ok) throw new Stop("error", `planner ended with ${p.status}`);
    } else h.snapshot("spec.md", 0);

    let criteria: Criterion[];
    try {
      criteria = parseCriteria(readFileSync(join(h.ws, "spec.md"), "utf8"));
    } catch (e) {
      throw new Stop("spec_issue", `cannot parse criteria: ${(e as Error).message}`);
    }
    const hardCount = criteria.filter((c) => c.class === "hard").length;
    h.emit(0, "qa_verdict", `${criteria.length} criteria, ${hardCount} hard`, { step: "criteria", criteria: criteria.length, hard: hardCount });
    if (hardCount > 40 && !args["allow-many-criteria"]) {
      throw new Stop("needs_trim", `${hardCount} hard criteria; trim spec.md to 25-30 and rerun with --spec`);
    }
    if (args["plan-only"]) throw new Stop("planned", `spec.md written: ${hardCount} hard of ${criteria.length} criteria; review it, then rerun with --spec`);

    // 2-5. Generator <-> evaluator rounds.
    let buildErrors: string | null = null;
    const passHistory: number[] = [];
    for (let round = 1; round <= maxRounds; round++) {
      h.round = round;
      h.emit(round, "round_start", `round ${round}`);

      const gen = await h.generator(round, buildErrors);
      h.snapshot("handoff.md", round);
      const rec: RoundRecord = { round, build_ok: false, score: null, generator: gen };
      rounds.push(rec);

      const build = await h.build(round);
      rec.build_ok = build.ok;

      if (!rec.build_ok) {
        // Broken build: straight back to the generator, QA skipped.
        buildErrors = build.out;
        passHistory.push(passHistory.at(-1) ?? 0);
      } else {
        buildErrors = null;
        rec.evaluator = await h.evaluator(round);
        if (rec.evaluator.screenLocked) {
          await h.waitForScreen(round);
          rec.evaluator = await h.evaluator(round, "The previous QA attempt ran on a locked screen and is void. Test everything again.");
        }
        await h.sh("pkill", ["-x", appName]);
        h.snapshot("qa_report.md", round);
        try {
          const verdict = parseQaReport(readFileSync(join(h.ws, "qa_report.md"), "utf8"));
          rec.score = scoreRound(criteria, verdict);
          h.emit(round, "qa_verdict", `${rec.score.hard_pass}/${rec.score.hard_total} hard pass`, { ...rec.score });
          passHistory.push(rec.score.hard_pass);
        } catch (e) {
          h.emit(round, "error", `qa_report.md unreadable: ${(e as Error).message}`, {});
          passHistory.push(passHistory.at(-1) ?? 0);
        }
        // QA must not leave a stale report that the next round could mistake for fresh.
        await h.commit(`QA report round ${round}`);
      }

      h.emit(round, "round_end", `round ${round} done`, { build_ok: rec.build_ok, hard_pass: rec.score?.hard_pass ?? null });

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
    else { status = "error"; reason = (e as Error).stack ?? String(e); h.emit(h.round, "error", firstLine(reason), { stack: reason }); }
  } finally {
    watcher.close();
    await h.sh("pkill", ["-x", appName]);
  }

  h.emit(h.round, "run_end", `${status}: ${reason}`, { status, reason });
  h.writeSummary(status, reason, rounds.map((r) => ({ round: r.round, build_ok: r.build_ok, score: r.score })));
  console.log(`\n${status}: ${reason}\nsummary: ${join(h.log.dir, "summary.md")}`);
  if (!args["keep-panel"]) process.exit(status === "done" || status === "planned" ? 0 : 1);
}

process.on("SIGINT", () => {
  h.emit(h.round, "run_end", "aborted by user", { status: "aborted" });
  process.exit(130);
});

await main();
