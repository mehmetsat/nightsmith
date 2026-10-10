// QA only: test an existing run's current build against its spec, without building anything.
// For when a round's QA failed (turn limit, locked screen) and the verdict needs to be taken again.
//
//   node qa.ts --run-id polish1 [--model opus] [--round 2]

import { existsSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { parseArgs } from "node:util";
import { Harness, MODEL_IDS } from "./harness.ts";
import { parseCriteria, parseQaReport, scoreRound } from "./criteria.ts";

const { values: args } = parseArgs({
  options: { "run-id": { type: "string" }, model: { type: "string", default: "opus" }, round: { type: "string" }, "app-name": { type: "string", default: "ShotBox" } },
});
if (!args["run-id"]) { console.error("need --run-id"); process.exit(2); }

const h = new Harness({
  runId: args["run-id"], appName: args["app-name"]!, models: { evaluator: MODEL_IDS[args.model!] ?? args.model! },
  budgetPerAgent: 40, generatorTurns: 0, evaluatorTurns: 220,
});
if (!existsSync(join(h.ws, "spec.md"))) { console.error(`no workspace at ${h.ws}`); process.exit(2); }
h.keepAwake();

const criteria = parseCriteria(readFileSync(join(h.ws, "spec.md"), "utf8"));
h.criteriaCount = criteria.length;
const round = Number(args.round ?? 99);
h.round = round;

const build = await h.build(round);
if (!build.ok) { console.error("build failed"); process.exit(1); }
const t0 = Date.now();
const ev = await h.evaluator(round, "This is a QA-only pass on the current build: test every criterion, nothing was built this round.");
await h.sh("pkill", ["-x", h.opts.appName]);
const f = join(h.ws, "qa_report.md");
if (!existsSync(f) || statSync(f).mtimeMs < t0) { console.error(`qa_report.md not written (evaluator ${ev.status})`); process.exit(1); }
h.snapshot("qa_report.md", round);
const s = scoreRound(criteria, parseQaReport(readFileSync(f, "utf8")));
h.emit(round, "qa_verdict", `${s.hard_pass}/${s.hard_total} hard pass (QA-only)`, { ...s });
await h.commit(`QA-only pass: ${s.hard_pass}/${s.hard_total}`);
console.log(`${s.hard_pass}/${s.hard_total} hard, ${s.soft_pass}/${s.soft_total} soft, cost $${ev.costUsd.toFixed(2)}; failing: ${s.hard_fail_ids.join(", ")}`);
process.exit(0);
