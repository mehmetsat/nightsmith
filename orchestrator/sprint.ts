// Design sprint: one surface (e.g. the Clothesline), a strong designer, and a critique loop.
// In a git worktree: design → build → photograph and record the surface → critique against the
// best existing product → revise, N times. Then two judges compare the result with the current
// build, and it is merged only if it wins and clears an absolute score. The design files it owns
// become protected from the generator, so later rounds cannot slide the craft back.

import { existsSync, mkdirSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { JUDGE_RUBRICS, SPRINT_DESIGNER, SPRINT_PHOTOGRAPHER, critiqueTask, judgeTask } from "./agents/prompts.ts";
import { Harness, TOOLS } from "./harness.ts";

export interface SprintConfig {
  focus: string;          // what the surface is, in words
  title: string;          // window/panel title of the surface
  open: string;           // key combo that toggles it, e.g. ctrl+alt+cmd+l
  iterations: number;
  reference: string[];    // images of the best existing product (never copied, only compared)
  minScore: number;       // average rubric score needed to merge
  brief?: string;         // design direction from the human (ideas, not fixed rules)
  base?: string;          // git ref to start the sprint from (continue an earlier sprint's branch)
}

export interface SprintOutcome { merged: boolean; scores: number[][]; notes: string; protectedPath: string }

const AXCLI = join(TOOLS, "axcli/.build/release/axcli");

export async function designSprint(h: Harness, round: number, cfg: SprintConfig, models: Record<string, string>): Promise<SprintOutcome> {
  const app = h.opts.appName;
  const dir = join(h.log.dir, "sprint", `r${round}`);
  const branch = `sprint/r${round}`;
  const protectedPath = `Sources/${app}/Design`;
  mkdirSync(join(h.log.dir, "sprint"), { recursive: true });
  await h.git("worktree", "add", "-q", "-b", branch, dir, cfg.base ?? "HEAD");
  h.emit(round, "design", `design sprint: ${cfg.focus} (${cfg.iterations} iterations)`, { sprint: true, focus: cfg.focus, reference: cfg.reference.length });

  const scores: number[][] = [];
  let critique = "";
  let last: { stills: string[]; frames: string[] } = { stills: [], frames: [] };

  for (let i = 1; i <= cfg.iterations; i++) {
    await h.agent({
      agent: "designer", round, model: models.sprint, cwd: dir,
      rolePrompt: SPRINT_DESIGNER.replaceAll("<focus>", cfg.focus).replaceAll("<title>", cfg.title).replaceAll("$APP_NAME", app).replaceAll("<iteration>", String(i)),
      task: [
        `Iteration ${i} of ${cfg.iterations}. Surface: ${cfg.focus}.`,
        ...(cfg.brief ? ["", "Design brief from the human. Treat these as direction, not fixed rules: build the ideas that work, and for any you drop, say why in your commit message.", cfg.brief] : []),
        "", "Reference images (Read them):", ...cfg.reference.map((p) => `- ${p}`),
        ...(critique ? ["", "Critique of your previous iteration (act on it):", critique] : []),
        ...(last.stills.length ? ["", "How your previous iteration looked:", ...last.stills.map((p) => `- ${p}`), ...last.frames.slice(0, 4).map((p) => `- ${p}`)] : []),
      ].join("\n"),
      builtinTools: ["Bash", "Read", "Write", "Edit", "Glob", "Grep"], macTools: false,
      writable: h.generatorWritable(dir), maxTurns: 200,
    });
    if ((await h.sh("./build.sh", [], dir)).code !== 0) { critique = "The build failed. Fix it first; keep the design."; scores.push([0, 0, 0, 0, 0]); continue; }
    last = await photograph(h, round, dir, cfg, models);
    if (!last.stills.length) { critique = `The surface was not found on screen: its window or panel must be titled "${cfg.title}" and open with ${cfg.open}.`; scores.push([0, 0, 0, 0, 0]); continue; }
    // A nearly empty PNG is a blank capture (night2, iteration 3: a blur material came out solid white).
    if (last.stills.every((p) => statSync(p).size < 20_000)) {
      critique = "Your surface rendered BLANK in the window capture: the still is a single flat colour. Usually a system blur material (NSVisualEffectView) or layer that window capture cannot see, or content that is not drawn yet. Draw the backdrop yourself (a plain gradient or scrim) and make sure the content is visible as soon as the panel is ordered front. Keep the rest of your design.";
      scores.push([0, 0, 0, 0, 0]);
      h.emit(round, "design", `sprint ${i}: blank capture, sent back`, { iteration: i, blank: true });
      continue;
    }

    const c = await h.agent({
      agent: "judge", round, model: models.sprint, rolePrompt: "You are an exacting design critic. Specific, visual, actionable.",
      task: critiqueTask(cfg.focus, cfg.reference, last.stills, last.frames, i) + (cfg.brief ? `\n\nThe designer follows this brief from the human; judge how well its ideas land and which are missing:\n${cfg.brief}` : ""), builtinTools: ["Read"], macTools: false, writable: [], maxTurns: 25,
    });
    try {
      const v = JSON.parse(c.finalText.match(/\{[\s\S]*\}/)?.[0] ?? "{}");
      scores.push(Array.isArray(v.scores) ? v.scores.map(Number) : []);
      critique = `${v.summary ?? ""}\n${(v.changes ?? []).map((x: string, k: number) => `${k + 1}. ${x}`).join("\n")}`;
      h.emit(round, "design", `sprint ${i}: avg ${avg(scores.at(-1)!).toFixed(1)}${v.beats_reference ? ", beats the reference" : ""}`, { iteration: i, scores: scores.at(-1), beats_reference: v.beats_reference === true });
    } catch {
      scores.push([]);
    }
  }

  // Final: does the sprint beat the current build? Two judges, and an absolute floor.
  await h.sh("pkill", ["-x", app]);
  const current = await photograph(h, round, h.ws, cfg, models);
  const finalAvg = avg(scores.at(-1) ?? []);
  let wins = 0;
  if (current.stills.length && last.stills.length) {
    for (const rubric of Object.values(JUDGE_RUBRICS)) {
      const swap = Math.random() < 0.5;
      const [A, B] = swap ? [current.stills, last.stills] : [last.stills, current.stills];
      const o = await h.agent({ agent: "judge", round, model: models.sprint, rolePrompt: "You are a design judge. Be decisive and specific.", task: judgeTask(rubric, A, B), builtinTools: ["Read"], macTools: false, writable: [], maxTurns: 12 });
      const w = JSON.parse(o.finalText.match(/\{[\s\S]*\}/)?.[0] ?? "{}").winner;
      if ((w === "A" && !swap) || (w === "B" && swap)) wins++;
    }
  } else if (last.stills.length) {
    wins = 2; // nothing to compare against: the surface did not exist before
  }
  // Merge when it beats the current build: a better design should not wait for a perfect one.
  // minScore is the goal the next sprint aims for, logged but not a gate.
  const merged = wins >= 1 && (await h.git("merge", "--no-edit", "-q", branch)).code === 0;
  if (!merged) await h.git("merge", "--abort");
  await h.git("worktree", "remove", "--force", dir);

  const notes = `design sprint r${round} (${cfg.focus}): ${merged ? "merged" : "not merged"}, scores ${scores.map((s) => avg(s).toFixed(1)).join(" → ")} (goal ${cfg.minScore}), beat current in ${wins}/2`;
  writeFileSync(join(h.ws, `research/sprint_r${round}.json`), JSON.stringify({ focus: cfg.focus, scores, wins, merged, critique }, null, 2));
  h.emit(round, "design", notes, { sprint: true, merged, wins, final_avg: finalAvg });
  return { merged, scores, notes, protectedPath };
}

const avg = (xs: number[]) => (xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : 0);

/** Launch the build in `cwd` with realistic test images and capture the surface (still + frames). */
async function photograph(h: Harness, round: number, cwd: string, cfg: SprintConfig, models: Record<string, string>) {
  const env = `export WS="$PWD" AXCLI="${AXCLI}"; [ -f test.env ] && { set -a; . ./test.env; set +a; }`;
  await h.sh("pkill", ["-x", h.opts.appName]);
  await h.sh("bash", ["-c", `${env}; for d in "$SHOTBOX_DATA_DIR" "$SHOTBOX_WATCH_DIR"; do [ -n "$d" ] && rm -rf "$d"; done; [ -n "$SHOTBOX_WATCH_DIR" ] && mkdir -p "$SHOTBOX_WATCH_DIR"; true`], cwd);
  if ((await h.sh("./run.sh", [], cwd)).code !== 0) return { stills: [], frames: [] };
  await h.sh("bash", ["-c", `${env}; [ -n "$SHOTBOX_WATCH_DIR" ] && for f in fixtures/real_*.png fixtures/fixture_1.png; do [ -e "$f" ] && cp "$f" "$SHOTBOX_WATCH_DIR"/ && sleep 0.5; done; true`], cwd);
  await new Promise((r) => setTimeout(r, 3000));
  const shotsDir = join(h.log.dir, "screenshots");
  const before = new Set(readdirSync(shotsDir));
  await h.agent({
    agent: "designer", round, model: models.photographer, cwd,
    rolePrompt: SPRINT_PHOTOGRAPHER.replaceAll("<open>", cfg.open).replaceAll("<title>", cfg.title),
    task: `Photograph the ${cfg.title}.`, builtinTools: [], macTools: true, writable: [], maxTurns: 20,
  });
  await h.sh("pkill", ["-x", h.opts.appName]);
  const fresh = readdirSync(shotsDir).filter((f) => !before.has(f));
  const stills = fresh.filter((f) => f.includes("sprint_still") && f.endsWith(".1280.png")).map((f) => join(shotsDir, f));
  const frameDir = fresh.find((f) => f.endsWith("_frames") && existsSync(join(shotsDir, f)));
  const frames = frameDir ? readdirSync(join(shotsDir, frameDir)).filter((f) => /^frame_\d+\.640\.png$/.test(f)).sort().map((f) => join(shotsDir, frameDir, f)) : [];
  return { stills, frames };
}
