// Design track: a redesign costs one agent session, so search instead of polishing.
// Every few rounds: a director writes K far-apart directions (inspiration and constraint drawn
// by the loop), K designers build them in parallel git worktrees, a photographer captures the
// same three screens of each, and two judges with different rubrics compare them pairwise.
// The winner is merged only if it beats the current design; functional damage is caught by the
// ratchet in the next QA round.

import { existsSync, mkdirSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { DESIGNER, DIRECTOR, JUDGE_RUBRICS, PHOTOGRAPHER, judgeTask } from "./agents/prompts.ts";
import { DESIGN_CONSTRAINTS, DOMAINS, pick } from "./agents/lenses.ts";
import { Harness, TOOLS } from "./harness.ts";

export interface DesignOutcome { merged: string | null; candidates: Candidate[]; notes: string }
interface Candidate { key: string; branch: string | null; dir: string; name: string; built: boolean; shots: string[]; wins: number; beatBaseline: number }

const AXCLI = join(TOOLS, "axcli/.build/release/axcli");

export async function designRound(h: Harness, round: number, k: number, random: () => number, models: Record<string, string>, screenshots: string[]): Promise<DesignOutcome> {
  const domains = pick(DOMAINS, random, k);
  const constraints = pick(DESIGN_CONSTRAINTS, random, k);
  const pairs = domains.map((d, i) => `${i + 1}. Inspiration: ${d}. Constraint: ${constraints[i]}`);
  h.emit(round, "design", `design round: ${k} directions`, { pairs });

  // 1. Director
  await h.agent({
    agent: "director", round, model: models.director, rolePrompt: DIRECTOR.replaceAll("<round>", String(round)),
    task: [`Round ${round}. One direction per pair:`, ...pairs, "", "Screenshots of the current design:", ...screenshots.map((s) => `- ${s}`)].join("\n"),
    builtinTools: ["Read", "Write", "Glob"], macTools: false, writable: [join(h.ws, `research/design_r${round}.md`)], maxTurns: 30,
  });
  h.snapshot(`research/design_r${round}.md`, round, h.ws, `design_r${round}.md`);
  await h.commit(`design directions round ${round}`);

  // 2. Designers in parallel, each in its own worktree from the current commit.
  const root = join(h.log.dir, "design");
  mkdirSync(root, { recursive: true });
  const cands: Candidate[] = [{ key: "current", branch: null, dir: h.ws, name: "current design", built: true, shots: [], wins: 0, beatBaseline: 0 }];
  for (let i = 1; i <= k; i++) {
    const branch = `design/r${round}-${i}`;
    const dir = join(root, `r${round}-${i}`);
    await h.git("worktree", "add", "-q", "-b", branch, dir, "HEAD");
    cands.push({ key: `r${round}-${i}`, branch, dir, name: `direction ${i}`, built: false, shots: [], wins: 0, beatBaseline: 0 });
  }
  await Promise.all(cands.slice(1).map((c, i) => h.agent({
    agent: "designer", round, model: models.designer, cwd: c.dir,
    rolePrompt: DESIGNER.replaceAll("<round>", String(round)).replaceAll("<k>", String(i + 1)),
    task: `Implement direction ${i + 1} from research/design_r${round}.md. Worktree: ${c.dir}`,
    builtinTools: ["Bash", "Read", "Write", "Edit", "Glob", "Grep"], macTools: false,
    writable: h.generatorWritable(c.dir), maxTurns: 150,
  })));

  // 3. Build and photograph each candidate, one at a time (they share the app name and the Mac).
  for (const c of cands) {
    if (c !== cands[0]) c.built = (await h.sh("./build.sh", [], c.dir)).code === 0;
    if (!c.built) continue;
    await h.sh("pkill", ["-x", h.opts.appName]);
    const env = `export WS="$PWD" AXCLI="${AXCLI}"; [ -f test.env ] && { set -a; . ./test.env; set +a; }`;
    await h.sh("bash", ["-c", `${env}; for d in "$SHOTBOX_DATA_DIR" "$SHOTBOX_WATCH_DIR"; do [ -n "$d" ] && rm -rf "$d"; done; [ -n "$SHOTBOX_WATCH_DIR" ] && mkdir -p "$SHOTBOX_WATCH_DIR"; true`], c.dir);
    if ((await h.sh("./run.sh", [], c.dir)).code !== 0) { c.built = false; continue; }
    // Files arrive after launch, like real captures, so a watch-only app ingests them too.
    await h.sh("bash", ["-c", `${env}; [ -n "$SHOTBOX_WATCH_DIR" ] && for f in fixtures/fixture_[1-5].png; do cp "$f" "$SHOTBOX_WATCH_DIR"/; sleep 0.4; done; true`], c.dir);
    await new Promise((r) => setTimeout(r, 2500));
    const before = new Set(readdirSync(join(h.log.dir, "screenshots")));
    await h.agent({
      agent: "designer", round, model: models.photographer, cwd: c.dir, rolePrompt: PHOTOGRAPHER,
      task: `Photograph ${c.key}.`, builtinTools: [], macTools: true, writable: [], maxTurns: 30,
    });
    const fresh = readdirSync(join(h.log.dir, "screenshots")).filter((f) => !before.has(f) && /\.1280\.png$/.test(f));
    c.shots = ["grid", "search", "preview"].map((l) => fresh.find((f) => f.includes(`_${l}`))).filter(Boolean).map((f) => join(h.log.dir, "screenshots", f!));
  }
  await h.sh("pkill", ["-x", h.opts.appName]);

  // 4. Judges: every pair, both rubrics, A/B order shuffled against position bias.
  const ready = cands.filter((c) => c.built && c.shots.length >= 2);
  const verdicts: { a: string; b: string; rubric: string; winner: string; why: string }[] = [];
  const jobs: Promise<void>[] = [];
  for (let i = 0; i < ready.length; i++) for (let j = i + 1; j < ready.length; j++) for (const [rubricKey, rubric] of Object.entries(JUDGE_RUBRICS)) {
    const swap = random() < 0.5;
    const [A, B] = swap ? [ready[j], ready[i]] : [ready[i], ready[j]];
    jobs.push(h.agent({
      agent: "judge", round, model: models.judge, rolePrompt: "You are a design judge. Be decisive and specific.",
      task: judgeTask(rubric, A.shots, B.shots), builtinTools: ["Read"], macTools: false, writable: [], maxTurns: 12,
    }).then((o) => {
      const m = o.finalText.match(/\{[\s\S]*\}/);
      try {
        const v = JSON.parse(m?.[0] ?? "{}");
        const win = v.winner === "A" ? A : v.winner === "B" ? B : null;
        if (!win) return;
        win.wins++;
        const lose = win === A ? B : A;
        if (lose === cands[0]) win.beatBaseline++;
        verdicts.push({ a: A.key, b: B.key, rubric: rubricKey, winner: win.key, why: String(v.why ?? "").slice(0, 240) });
      } catch { /* unreadable verdict: no vote */ }
    }));
  }
  await Promise.all(jobs);

  // 5. Merge the winner if it beat the current design under at least one rubric.
  const best = ready.filter((c) => c !== cands[0]).sort((x, y) => y.wins - x.wins)[0];
  let merged: string | null = null;
  if (best && best.beatBaseline >= 1 && best.wins > cands[0].wins) {
    const r = await h.git("merge", "--no-edit", "-q", best.branch!);
    if (r.code === 0) merged = best.key; else await h.git("merge", "--abort");
  }
  for (const c of cands.slice(1)) if (existsSync(c.dir)) await h.git("worktree", "remove", "--force", c.dir);

  const notes = `design round ${round}: ${merged ? `merged ${merged}` : "kept the current design"} (${cands.map((c) => `${c.key} ${c.wins} wins${c.built ? "" : ", build failed"}`).join("; ")})`;
  h.emit(round, "design", notes, {
    merged, pairs, verdicts,
    candidates: cands.map((c) => ({ key: c.key, wins: c.wins, beat_current: c.beatBaseline, built: c.built, shots: c.shots.map((s) => s.slice(s.indexOf("screenshots/"))) })),
  });
  return { merged, candidates: cands, notes };
}
