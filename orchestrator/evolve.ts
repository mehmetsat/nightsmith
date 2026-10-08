// Self-improving loop (v2). The planner's spec is a floor, not a ceiling:
//   - when every hard criterion passes (or every N rounds), a researcher searches the web through a
//     lens the loop picks, outsiders look at the app cold, and the replanner raises the bar;
//   - passed criteria become a ratchet: a change that breaks one is fixed next round or reverted;
//   - the budget (5-hour window and an estimated-dollar cap) is the only planned stop;
//   - every few rounds a checkpoint page is written for the human, who never blocks the loop.
//
//   node evolve.ts --from-run run1 [--run-id evo1] [--max-rounds 20] [--budget-usd 60]
//   node evolve.ts --prompt ../prompts/shotbox.md [--spec ../prompts/shotbox.spec.md]
//
// Human feedback: write lines into runs/<run_id>/feedback.md at any time:
//   veto I-4-2: too gimmicky      note: focus on keyboard flow next      pick design 2

import { appendFileSync, existsSync, mkdirSync, readFileSync, readdirSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { parseArgs } from "node:util";
import { firstLine } from "./events.ts";
import type { AgentOutcome } from "./agents/common.ts";
import { COLD, OUTSIDER, REPLANNER, RESEARCHER, coldTask, outsiderTask, replannerTask, researcherTask } from "./agents/prompts.ts";
import { DOMAINS, LENSES, pick, rng } from "./agents/lenses.ts";
import { guardSpec, parseCriteria, parseQaReport, scoreRound, writeCriteria, type Criterion, type RoundScore } from "./criteria.ts";
import { startPanel } from "./panel/server.ts";
import { Harness, RUNS, Stop, parseModels } from "./harness.ts";
import { designRound } from "./design.ts";
import { ensureTasks, runTasks, taskRegressions, type TaskResult, type UserTask } from "./usertasks.ts";

const { values: args } = parseArgs({
  options: {
    prompt: { type: "string" },
    spec: { type: "string" },
    "from-run": { type: "string" },
    "run-id": { type: "string" },
    "max-rounds": { type: "string", default: "20" },
    models: { type: "string", default: "planner=sonnet,generator=haiku,evaluator=sonnet,researcher=sonnet,outsider=sonnet,cold=haiku,director=sonnet,designer=sonnet,photographer=haiku,judge=sonnet,user=haiku" },
    "app-name": { type: "string", default: "ShotBox" },
    "panel-port": { type: "string", default: "4317" },
    "budget-usd": { type: "string", default: "60" },
    "window-cap": { type: "string", default: "0.9" },
    "budget-per-agent": { type: "string", default: "25" },
    "generator-turns": { type: "string", default: "250" },
    "evaluator-turns": { type: "string", default: "220" },
    "replan-every": { type: "string", default: "3" },
    "max-new-criteria": { type: "string", default: "8" },
    "checkpoint-every": { type: "string", default: "4" },
    "design-every": { type: "string", default: "4" },
    "design-directions": { type: "string", default: "3" },
    "tasks-every": { type: "string", default: "1" },
    "no-design": { type: "boolean", default: false },
    "no-tasks": { type: "boolean", default: false },
    "keep-panel": { type: "boolean", default: false },
  },
});

if (!args.prompt && !args.spec && !args["from-run"]) {
  console.error("need --from-run <run_id>, or --prompt <prompt.md> [--spec <spec.md>]");
  process.exit(2);
}

const runId = args["run-id"] ?? `evo_${new Date().toISOString().replace(/[:.]/g, "-").slice(0, 19)}`;
const appName = args["app-name"]!;
const models = parseModels(args.models!);
const cfg = {
  maxRounds: Number(args["max-rounds"]), budgetUsd: Number(args["budget-usd"]), windowCap: Number(args["window-cap"]),
  replanEvery: Number(args["replan-every"]), maxNew: Number(args["max-new-criteria"]), checkpointEvery: Number(args["checkpoint-every"]),
  designEvery: args["no-design"] ? 0 : Number(args["design-every"]), designK: Number(args["design-directions"]),
  tasksEvery: args["no-tasks"] ? 0 : Number(args["tasks-every"]),
};
const h = new Harness({
  runId, appName, models, budgetPerAgent: Number(args["budget-per-agent"]),
  generatorTurns: Number(args["generator-turns"]), evaluatorTurns: Number(args["evaluator-turns"]),
});
const R = (p: string) => join(h.ws, p);
const random = rng(runId);

// ---------------------------------------------------------------------------
// Durable loop state (state.json in the run folder), so a crashed run can be read afterwards.

interface State {
  ratchet: string[];             // hard criteria that have passed at least once
  lastGood: string | null;       // commit where every ratchet criterion passed
  pendingRegression: string[];   // ratchet criteria broken last round, to fix this round
  replans: { round: number; added: string[]; lens: string; domain: string }[];
  lastReplanRound: number;
  vetoed: string[];              // idea ids the human vetoed
  notes: string[];               // human notes not yet given to a replan
  pickDesign?: string | null;    // "r4-2": the human prefers this design candidate
}
const statePath = join(h.log.dir, "state.json");
const st: State = existsSync(statePath)
  ? JSON.parse(readFileSync(statePath, "utf8"))
  : { ratchet: [], lastGood: null, pendingRegression: [], replans: [], lastReplanRound: 0, vetoed: [], notes: [] };
const save = () => writeFileSync(statePath, JSON.stringify(st, null, 2));

function outcome(line: string) {
  mkdirSync(R("research"), { recursive: true });
  appendFileSync(R("research/outcomes.md"), `- ${line}\n`);
}

// ---------------------------------------------------------------------------
// Human feedback: read, apply, move to feedback.done.md. Never waits for it.

function readFeedback(round: number) {
  const f = join(h.log.dir, "feedback.md");
  if (!existsSync(f)) return;
  const lines = readFileSync(f, "utf8").split("\n").map((l) => l.trim()).filter(Boolean);
  if (!lines.length) return;
  for (const l of lines) {
    const veto = l.match(/^veto\s+(I-\d+-\d+)\s*:?\s*(.*)$/i);
    const pickD = l.match(/^pick\s+design\s+(r\d+-\d+)/i);
    if (pickD) {
      st.pickDesign = pickD[1];
      h.emit(round, "feedback", `pick design ${pickD[1]}`, { pick: pickD[1] });
    } else if (veto) {
      st.vetoed.push(veto[1]);
      outcome(`${veto[1]}: vetoed by the human in round ${round}${veto[2] ? ` (${veto[2]})` : ""}`);
      // The human outranks the ratchet: criteria from a vetoed idea leave the spec.
      const spec = readFileSync(R("spec.md"), "utf8");
      const crit = parseCriteria(spec);
      const gone = crit.filter((c) => c.origin === veto[1]).map((c) => c.id);
      if (gone.length) {
        writeFileSync(R("spec.md"), writeCriteria(spec, crit.filter((c) => c.origin !== veto[1])));
        st.ratchet = st.ratchet.filter((id) => !gone.includes(id));
      }
      h.emit(round, "feedback", `veto ${veto[1]}${gone.length ? `: removed ${gone.join(", ")}` : ""}`, { veto: veto[1], removed: gone });
    } else {
      st.notes.push(l.replace(/^note\s*:\s*/i, ""));
      h.emit(round, "feedback", `note: ${firstLine(l, 120)}`, { note: l });
    }
  }
  appendFileSync(join(h.log.dir, "feedback.done.md"), `## Round ${round}\n${lines.join("\n")}\n\n`);
  renameSync(f, join(h.log.dir, `feedback.read-r${round}.md`));
  save();
}

// ---------------------------------------------------------------------------
// Screenshots for the researcher and the outsiders: the latest evaluator round, evenly sampled.

function latestShots(n = 8): string[] {
  const dirs = [join(h.log.dir, "screenshots"), ...(args["from-run"] ? [join(RUNS, args["from-run"], "screenshots")] : [])];
  for (const dir of dirs) {
    if (!existsSync(dir)) continue;
    const files = readdirSync(dir).filter((f) => /_evaluator_.*\.1280\.png$/.test(f));
    if (!files.length) continue;
    const rounds = files.map((f) => Number(f.match(/^r(\d+)_/)?.[1] ?? 0));
    const last = Math.max(...rounds);
    const mine = files.filter((f) => f.startsWith(`r${last}_`)).sort();
    const step = Math.max(1, Math.floor(mine.length / n));
    return mine.filter((_, i) => i % step === 0).slice(0, n).map((f) => join(dir, f));
  }
  return [];
}

// ---------------------------------------------------------------------------
// Agents beyond the classic three

async function coldBaseline() {
  if (existsSync(R("research/obvious.md"))) return;
  mkdirSync(R("research"), { recursive: true });
  const brief = existsSync(R("prompt.md")) ? readFileSync(R("prompt.md"), "utf8") : readFileSync(R("spec.md"), "utf8").slice(0, 1500);
  const o = await h.agent({ agent: "cold", round: 0, model: models.cold, rolePrompt: COLD, task: coldTask(brief), builtinTools: [], macTools: false, writable: [], maxTurns: 2 });
  writeFileSync(R("research/obvious.md"), `# The obvious answers\n\nWhat a model with no context suggests. Ideas that overlap this list are "obvious".\n\n${o.finalText}\n`);
  h.snapshot("research/obvious.md", 0, h.ws, "obvious.md");
}

async function replan(round: number): Promise<Criterion[]> {
  const lens = LENSES[st.replans.length % LENSES.length];
  const [domain] = pick(DOMAINS, random);
  const shots = latestShots();
  h.emit(round, "replan", `replan ${st.replans.length + 1}: ${firstLine(lens, 90)}`, { lens, domain, screenshots: shots.length });
  if (!existsSync(R("research/ledger.md"))) writeFileSync(R("research/ledger.md"), "# Research ledger\n\nEvery question, query, source and idea so far. Never repeat one.\n");
  if (!existsSync(R("research/outcomes.md"))) writeFileSync(R("research/outcomes.md"), "# Idea outcomes\n\n");

  const before = parseCriteria(readFileSync(R("spec.md"), "utf8"));
  // Researcher and outsiders do not depend on each other: run them side by side.
  await Promise.all([
    h.agent({
      agent: "researcher", round, model: models.researcher, rolePrompt: RESEARCHER.replaceAll("<round>", String(round)),
      task: researcherTask(round, lens, domain, shots), builtinTools: ["Read", "Write", "Edit", "Glob", "WebSearch", "WebFetch"], macTools: false,
      writable: [R("research")], maxTurns: 80,
    }),
    h.agent({
      agent: "outsider", round, model: models.outsider, rolePrompt: OUTSIDER.replaceAll("<round>", String(round)),
      task: outsiderTask(round, shots, before.map((c) => `${c.id} (${c.class}): ${firstLine(c.text, 110)}`)),
      builtinTools: ["Read", "Write"], macTools: false, writable: [R(`research/outsider_r${round}.md`)], maxTurns: 30,
    }),
  ]);
  for (const f of [`research/r${round}.md`, `research/outsider_r${round}.md`]) h.snapshot(f, round, h.ws, f.split("/").pop());

  const feedback = st.notes.splice(0).map((n) => `- ${n}`).join("\n");
  await h.agent({
    agent: "planner", round, model: models.planner,
    rolePrompt: REPLANNER.replaceAll("<round>", String(round)).replaceAll("<max>", String(cfg.maxNew)),
    task: replannerTask(round, cfg.maxNew, feedback), builtinTools: ["Read", "Write", "Edit", "Glob"], macTools: false,
    writable: [R("spec.md"), R(`research/replan_r${round}.md`)], maxTurns: 50,
  });

  // The loop, not the replanner, decides what the floor is.
  let next: Criterion[];
  try { next = parseCriteria(readFileSync(R("spec.md"), "utf8")); } catch { next = before; }
  const g = guardSpec(before, next, cfg.maxNew, round, new Set(st.vetoed));
  writeFileSync(R("spec.md"), writeCriteria(readFileSync(R("spec.md"), "utf8"), g.criteria));
  h.snapshot("spec.md", round);
  h.snapshot(`research/replan_r${round}.md`, round, h.ws, `replan_r${round}.md`);
  for (const c of g.added) outcome(`${c.origin ?? "?"} → ${c.id} (${c.class}, ${c.novelty}) added in round ${round}: ${firstLine(c.text, 100)}`);
  st.replans.push({ round, added: g.added.map((c) => c.id), lens, domain });
  st.lastReplanRound = round;
  save();
  const novel = g.added.filter((c) => c.novelty === "new").length;
  h.emit(round, "replan", `+${g.added.length} criteria (${novel} new, ${g.added.length - novel} obvious)${g.restored.length ? `; restored ${g.restored.length}` : ""}`, {
    // Ids only: full criteria are in spec.md; a long list here would be cut to fit the 2 KB payload.
    added_count: g.added.length, added: g.added.map((c) => `${c.id}:${c.class[0]}:${c.novelty === "new" ? "n" : "o"}:${c.origin ?? ""}`),
    restored: g.restored, dropped: g.dropped, lens, domain,
  });
  await h.commit(`replan round ${round}: +${g.added.length} criteria`);
  return g.criteria;
}

// ---------------------------------------------------------------------------
// Checkpoint page for the human: a report, never a gate.

function checkpoint(round: number, rounds: RoundRec[]) {
  const since = rounds.filter((r) => r.round > round - cfg.checkpointEvery);
  const replans = st.replans.filter((p) => p.round > round - cfg.checkpointEvery);
  const outcomes = existsSync(R("research/outcomes.md")) ? readFileSync(R("research/outcomes.md"), "utf8").trim().split("\n").slice(-30) : [];
  const md = [
    `# Checkpoint after round ${round}`, "",
    `Cost so far: $${h.totalCost().toFixed(2)} of $${cfg.budgetUsd}. Ratchet: ${st.ratchet.length} hard criteria locked in.`, "",
    "## Rounds", "", "| round | build | hard | soft | scores | note |", "|---|---|---|---|---|---|",
    ...since.map((r) => `| ${r.round} | ${r.build_ok ? "ok" : "broken"} | ${r.score ? `${r.score.hard_pass}/${r.score.hard_total}` : "-"} | ${r.score ? `${r.score.soft_pass}/${r.score.soft_total}` : "-"} | ${r.score ? Object.entries(r.score.scores).map(([k, v]) => `${k} ${v}`).join(", ") : "-"} | ${r.note ?? ""} |`),
    "", "## Replans", "", ...(replans.length ? replans.map((p) => `- Round ${p.round}: +${p.added.length} (${p.added.join(", ") || "none"}). Lens: ${p.lens} Analogy: ${p.domain}.`) : ["- none in this stretch"]),
    "", "## Idea outcomes (latest)", "", ...outcomes,
    "", "## Your move (optional, the loop does not wait)", "",
    `Write lines into runs/${runId}/feedback.md: \`veto I-x-y: reason\`, or \`note: anything\`.`, "",
  ].join("\n");
  mkdirSync(join(h.log.dir, "checkpoints"), { recursive: true });
  const rel = `checkpoints/r${round}.md`;
  writeFileSync(join(h.log.dir, rel), md);
  h.emit(round, "checkpoint", `checkpoint after round ${round}`, { path: rel });
  h.emit(round, "artifact_written", `checkpoint_r${round}.md`, { name: "checkpoint.md", path: rel, bytes: md.length });
}

// ---------------------------------------------------------------------------
// The loop

interface RoundRec { round: number; build_ok: boolean; score: RoundScore | null; note?: string }

async function main() {
  await h.setupWorkspace({ prompt: args.prompt, spec: args.spec, fromRun: args["from-run"] });
  h.keepAwake();
  const panelUrl = await startPanel(RUNS, Number(args["panel-port"])).catch(() => null);
  console.log(`run ${runId} (evolve)\nworkspace ${h.ws}\npanel ${panelUrl ? `${panelUrl}/?run=${runId}` : "(port busy; the panel already running shows this run too)"}`);
  h.emit(0, "run_start", runId, { max_rounds: cfg.maxRounds, models, app: appName, workspace: h.ws, mode: "evolve", ...cfg, from_run: args["from-run"] ?? null });
  const watcher = h.watchArtifacts();
  const rounds: RoundRec[] = [];
  let status = "incomplete", reason = "";
  let buildErrors: string | null = null;
  let emptyReplans = 0;
  let agentErrors = 0;
  let tasks: UserTask[] = [];
  const taskHistory: TaskResult[][] = [];
  let usability: string[] = [];

  try {
    await h.init();
    if (!existsSync(R("spec.md"))) {
      const p = await h.planner();
      if (!p.ok) throw new Stop("error", `planner ended with ${p.status}`);
    }
    h.snapshot("spec.md", 0);
    let criteria = parseCriteria(readFileSync(R("spec.md"), "utf8"));

    // Starting from an earlier run: its last QA report seeds the ratchet.
    if (args["from-run"] && existsSync(R("qa_report.md")) && !st.ratchet.length) {
      const s = scoreRound(criteria, parseQaReport(readFileSync(R("qa_report.md"), "utf8")));
      st.ratchet = criteria.filter((c) => c.class === "hard" && !s.hard_fail_ids.includes(c.id)).map((c) => c.id);
      st.lastGood = (await h.git("rev-parse", "HEAD")).out.trim();
      h.emit(0, "qa_verdict", `${s.hard_pass}/${s.hard_total} hard pass (from ${args["from-run"]})`, { ...s });
      rounds.push({ round: 0, build_ok: true, score: s, note: `baseline from ${args["from-run"]}` });
      save();
    }
    await coldBaseline();
    if (cfg.tasksEvery) {
      tasks = await ensureTasks(h, models.planner);
      h.emit(0, "tasks", `${tasks.length} user tasks written`, { tasks: tasks.map((t) => ({ id: t.id, goal: t.goal })) });
      h.snapshot("research/tasks.json", 0, h.ws, "tasks.json");
    }

    for (let round = 1; round <= cfg.maxRounds; round++) {
      h.round = round;
      h.emit(round, "round_start", `round ${round}`);
      readFeedback(round);
      criteria = parseCriteria(readFileSync(R("spec.md"), "utf8"));
      if (h.totalCost() >= cfg.budgetUsd) throw new Stop("budget", `estimated spend $${h.totalCost().toFixed(2)} reached the $${cfg.budgetUsd} cap`);
      await h.waitForWindow(cfg.windowCap, round);

      // Raise the bar when the floor is met, or every N rounds even if it is not.
      const last = rounds.at(-1)?.score;
      const floorMet = last != null && last.hard_pass === last.hard_total;
      let added: string[] = [];
      if (floorMet || round - st.lastReplanRound > cfg.replanEvery) {
        criteria = await replan(round);
        added = st.replans.at(-1)!.added;
        emptyReplans = added.length ? 0 : emptyReplans + 1;
        if (emptyReplans >= 2) throw new Stop("converged", "two replans in a row added no criteria");
        await h.waitForWindow(cfg.windowCap, round);
      }

      // The human picked a design candidate from an earlier design round.
      if (st.pickDesign) {
        const r = await h.git("merge", "--no-edit", "-q", `design/${st.pickDesign}`);
        h.emit(round, "design", r.code === 0 ? `merged design ${st.pickDesign} (human pick)` : `could not merge design ${st.pickDesign}`, { picked: st.pickDesign, ok: r.code === 0 });
        if (r.code !== 0) await h.git("merge", "--abort");
        outcome(`design ${st.pickDesign}: picked by the human in round ${round}${r.code === 0 ? "" : " (merge failed)"}`);
        st.pickDesign = null; save();
      }
      // Design track: a full redesign is cheap, so search far-apart directions every few rounds.
      if (cfg.designEvery && round % cfg.designEvery === 0 && rounds.at(-1)?.build_ok !== false) {
        const d = await designRound(h, round, cfg.designK, random, models, latestShots(6));
        outcome(d.notes);
        await h.waitForWindow(cfg.windowCap, round);
      }

      const tasksNote: string[] = [];
      if (usability.length) tasksNote.push(`USABILITY REGRESSIONS from the timed user tasks (they worked before, now a test user fails): ${usability.join("; ")}. Fix these too.`);
      if (st.pendingRegression.length) tasksNote.push(`REGRESSIONS, fix these first. They passed before and fail now: ${st.pendingRegression.join(", ")}. If you cannot fix them without undoing your last change, undo it.`);
      if (added.length) tasksNote.push(`The spec gained new criteria this round: ${added.join(", ")}. Implement them, then fix any FAIL in qa_report.md. Keep every criterion that passes today passing.`);
      const gen = await h.generator(round, buildErrors, tasksNote.join("\n\n"));
      h.snapshot("handoff.md", round);
      const rec: RoundRec = { round, build_ok: false, score: null };
      rounds.push(rec);
      agentErrors = gen.ok ? 0 : agentErrors + 1;
      if (agentErrors >= 2) throw new Stop("error", `two agent sessions in a row failed (${gen.status})`);

      const build = await h.build(round);
      rec.build_ok = build.ok;
      if (!build.ok) {
        buildErrors = build.out;
        rec.note = "build broken";
        h.emit(round, "round_end", `round ${round}: build broken`, { build_ok: false });
        continue;
      }
      buildErrors = null;

      await h.waitForWindow(cfg.windowCap, round);
      let ev: AgentOutcome = await h.evaluator(round);
      if (ev.screenLocked) {
        // A verdict from a locked screen would read as mass regression. Wait and test again.
        await h.waitForScreen(round);
        ev = await h.evaluator(round, "The previous QA attempt ran on a locked screen and is void. Test everything again.");
      }
      await h.sh("pkill", ["-x", appName]);
      h.snapshot("qa_report.md", round);
      try {
        rec.score = scoreRound(criteria, parseQaReport(readFileSync(R("qa_report.md"), "utf8")));
        h.emit(round, "qa_verdict", `${rec.score.hard_pass}/${rec.score.hard_total} hard pass`, { ...rec.score });
      } catch (e) {
        h.emit(round, "error", `qa_report.md unreadable: ${(e as Error).message}`, { evaluator_status: ev.status });
      }
      const head = await h.commit(`round ${round}: QA ${rec.score ? `${rec.score.hard_pass}/${rec.score.hard_total}` : "unreadable"}`);

      // Ratchet: what passed once must keep passing.
      if (rec.score) {
        const failing = new Set(rec.score.hard_fail_ids);
        const regressed = st.ratchet.filter((id) => failing.has(id) && criteria.some((c) => c.id === id));
        if (regressed.length && st.pendingRegression.length && st.lastGood) {
          // Second round in a row with broken ratchet criteria: revert the app code.
          // restore (not checkout) also deletes tracked files that did not exist in lastGood.
          await h.git("restore", `--source=${st.lastGood}`, "--staged", "--worktree", "--", "Sources", "Package.swift");
          const sha = await h.commit(`revert app code to ${st.lastGood.slice(0, 7)}: ${regressed.join(", ")} still broken`);
          for (const id of added) outcome(`${id}: reverted in round ${round} (it broke ${regressed.join(", ")})`);
          h.emit(round, "revert", `reverted app code to ${st.lastGood.slice(0, 7)}`, { regressed, to: st.lastGood, commit: sha });
          rec.note = `reverted (${regressed.join(", ")})`;
          st.pendingRegression = [];
        } else if (regressed.length) {
          st.pendingRegression = regressed;
          h.emit(round, "regression", `ratchet broken: ${regressed.join(", ")}`, { regressed });
          rec.note = `regressed ${regressed.join(", ")}`;
        } else {
          st.pendingRegression = [];
          const passing = criteria.filter((c) => c.class === "hard" && !failing.has(c.id)).map((c) => c.id);
          const newlyLocked = passing.filter((id) => !st.ratchet.includes(id));
          st.ratchet = [...new Set([...st.ratchet, ...passing])];
          st.lastGood = head;
          for (const id of newlyLocked) { const c = criteria.find((x) => x.id === id); if (c?.origin) outcome(`${c.origin} → ${id}: built and passing in round ${round}, now locked`); }
        }
        save();
      }

      // Timed user tasks: behaviour, not opinion.
      if (cfg.tasksEvery && tasks.length && round % cfg.tasksEvery === 0) {
        await h.waitForWindow(cfg.windowCap, round);
        let res = await runTasks(h, round, tasks, models.user);
        if (await h.screenLocked()) { await h.waitForScreen(round); res = await runTasks(h, round, tasks, models.user); }
        usability = taskRegressions(taskHistory, res);
        taskHistory.push(res);
        const ok = res.filter((r) => r.ok).length;
        rec.note = [rec.note, `tasks ${ok}/${res.length}`].filter(Boolean).join("; ");
        if (usability.length) h.emit(round, "regression", `usability: ${usability.length} task(s) broke`, { usability });
      }

      h.emit(round, "round_end", `round ${round} done`, { build_ok: true, hard_pass: rec.score?.hard_pass ?? null, ratchet: st.ratchet.length });
      if (round % cfg.checkpointEvery === 0) checkpoint(round, rounds);
    }
    status = "incomplete";
    reason = `max_rounds (${cfg.maxRounds}) reached`;
  } catch (e) {
    if (e instanceof Stop) { status = e.status; reason = e.reason; }
    else { status = "error"; reason = (e as Error).stack ?? String(e); h.emit(h.round, "error", firstLine(reason), { stack: reason }); }
  } finally {
    watcher.close();
    await h.sh("pkill", ["-x", appName]);
  }

  checkpoint(h.round, rounds);
  h.emit(h.round, "run_end", `${status}: ${reason}`, { status, reason });
  const replanTable = ["", "## Replans", "", "| round | added | lens | analogy |", "|---|---|---|---|",
    ...st.replans.map((p) => `| ${p.round} | ${p.added.join(", ") || "-"} | ${firstLine(p.lens, 60)} | ${p.domain} |`)].join("\n");
  h.writeSummary(status, reason, rounds, replanTable);
  console.log(`\n${status}: ${reason}\nsummary: ${join(h.log.dir, "summary.md")}`);
  if (!args["keep-panel"]) process.exit(status === "budget" || status === "converged" ? 0 : 1);
}

process.on("SIGINT", () => {
  h.emit(h.round, "run_end", "aborted by user", { status: "aborted" });
  process.exit(130);
});

await main();
