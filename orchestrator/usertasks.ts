// User agent: does the app actually help a person? A small model with only the mac tools does
// realistic tasks; the loop times them and checks the outcome with a shell command. This measures
// behaviour ("found the invoice in 6 steps"), not opinion ("looks good").

import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { TASK_WRITER, USER } from "./agents/prompts.ts";
import { TOOLS, type Harness } from "./harness.ts";

export interface UserTask { id: string; goal: string; setup: string[]; check: string; max_steps: number }
export interface TaskResult { id: string; goal: string; ok: boolean; steps: number | null; seconds: number; gaveUp: string | null; check: string }

const AXCLI = join(TOOLS, "axcli/.build/release/axcli");

/** Runs a command in the workspace with test.env exported, the way run.sh launches the app. */
function inWorkspace(h: Harness, cmd: string, timeoutMs = 60_000) {
  const script = `cd "${h.ws}" && export WS="$PWD" AXCLI="${AXCLI}" && if [ -f test.env ]; then set -a; . ./test.env; set +a; fi\n${cmd}`;
  return h.sh("bash", ["-c", script], h.ws, timeoutMs);
}

export async function ensureTasks(h: Harness, model: string): Promise<UserTask[]> {
  const file = join(h.ws, "research/tasks.json");
  if (!existsSync(file)) {
    await h.agent({
      agent: "user", round: 0, model, rolePrompt: TASK_WRITER, task: "Write research/tasks.json.",
      builtinTools: ["Read", "Write", "Glob"], macTools: false, writable: [file], maxTurns: 25,
    });
  }
  try {
    const tasks = JSON.parse(readFileSync(file, "utf8")) as UserTask[];
    return tasks.filter((t) => t.id && t.goal && t.check);
  } catch {
    return [];
  }
}

export async function runTasks(h: Harness, round: number, tasks: UserTask[], model: string): Promise<TaskResult[]> {
  const results: TaskResult[] = [];
  for (const t of tasks) {
    await h.sh("pkill", ["-x", h.opts.appName]);
    // Fresh state for every task: clear the test folders, then the task's own setup.
    await inWorkspace(h, `for d in "$SHOTBOX_DATA_DIR" "$SHOTBOX_WATCH_DIR"; do [ -n "$d" ] && rm -rf "$d"; done; [ -n "$SHOTBOX_WATCH_DIR" ] && mkdir -p "$SHOTBOX_WATCH_DIR"; true`);
    // Setup runs before launch (it may delete and recreate the app's folders). After launch the
    // watch folder's files are moved out and back in one by one, so an app that only notices
    // files arriving while it runs still ingests them, like real captures.
    for (const cmd of t.setup ?? []) await inWorkspace(h, cmd);
    const launch = await h.sh("./run.sh", []);
    if (launch.code !== 0) { results.push({ id: t.id, goal: t.goal, ok: false, steps: null, seconds: 0, gaveUp: "app did not launch", check: t.check }); continue; }
    await inWorkspace(h, `[ -n "$SHOTBOX_WATCH_DIR" ] && [ -d "$SHOTBOX_WATCH_DIR" ] || exit 0
      tmp=$(mktemp -d); mv "$SHOTBOX_WATCH_DIR"/* "$tmp"/ 2>/dev/null
      # cp, not mv: a move inside one volume is reported as a rename, which watchers may ignore.
      for f in "$tmp"/*; do [ -e "$f" ] && cp -p "$f" "$SHOTBOX_WATCH_DIR"/ && sleep 0.6; done; rm -rf "$tmp"`);
    await new Promise((r) => setTimeout(r, 3000)); // let the app ingest and OCR them

    const t0 = Date.now();
    const o = await h.agent({
      agent: "user", round, model, rolePrompt: USER, task: `Your goal: ${t.goal}`,
      builtinTools: [], macTools: true, writable: [], maxTurns: Math.max(10, (t.max_steps ?? 20) * 2),
    });
    const seconds = Math.round((Date.now() - t0) / 1000);
    const check = await inWorkspace(h, t.check, 30_000);
    const gave = /GAVE UP/i.test(o.finalText) ? o.finalText.replace(/[\s\S]*GAVE UP[:\s-]*/i, "").trim().slice(0, 300) : null;
    results.push({ id: t.id, goal: t.goal, ok: check.code === 0, steps: o.turns, seconds, gaveUp: gave, check: t.check });
  }
  await h.sh("pkill", ["-x", h.opts.appName]);
  const ok = results.filter((r) => r.ok).length;
  const steps = results.filter((r) => r.ok && r.steps != null).map((r) => r.steps!).sort((a, b) => a - b);
  const median = steps.length ? steps[Math.floor(steps.length / 2)] : null;
  h.emit(round, "tasks", `user tasks ${ok}/${results.length}${median != null ? `, median ${median} steps` : ""}`, { ok, total: results.length, median_steps: median, results });
  return results;
}

/** Tasks that succeeded in the best earlier round and fail now: usability regressions. */
export function taskRegressions(history: TaskResult[][], now: TaskResult[]): string[] {
  const everOk = new Set(history.flat().filter((r) => r.ok).map((r) => r.id));
  return now.filter((r) => !r.ok && everOk.has(r.id)).map((r) => `${r.id} (${r.goal})${r.gaveUp ? `: user gave up, "${r.gaveUp}"` : ""}`);
}
