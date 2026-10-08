# mac-app-harness

A planner → generator → evaluator harness for building a macOS app with the Claude Agent SDK,
with a live panel showing which agent is running which tool. The app (ShotBox, a screenshot
clipboard) is the test subject. What we measure is the loop, the handoff files and the
observability layer. The full brief is `Screenshot Clipboard Harness Claude Code Handoff.pdf`.

## Layout

```
orchestrator/        TypeScript on the Agent SDK. Node 22.18+ runs .ts directly.
  run.ts             the loop, the stop rules, model routing, summary
  agents/            common.ts (one agent session), prompts.ts (v0 prompts), mactools.ts (MCP tools)
  events.ts          SDK stream -> one event shape -> runs/<id>/events.jsonl + events.db
  criteria.ts        criteria from spec.md, verdict from qa_report.md
  panel/             index.html + server.ts (SSE from the JSONL tail; read-only)
  fake.ts            fake run for testing the panel without tokens
tools/
  axcli/             Swift CLI: tree, find, click, type, key, window-id, pbimage, fixture
  screenshot.sh      PNG of the app window only
  record_frames.sh   records the window, returns N evenly spaced frames
app-template/        build.sh, run.sh, init.sh copied into each run's workspace
prompts/             prompt.md inputs: trivial.md (loop test), shotbox.md (the real app)
runs/<run_id>/       events.jsonl, events.db, raw/, screenshots/, artifacts/r<N>/, app/, summary.md
```

Each run gets its own workspace at `runs/<run_id>/app/`, a git repo the agents treat as their
whole world. Run 2 reuses run 1's spec with `--spec runs/<run1>/app/spec.md`.

## Setup (once)

1. Xcode 16+ (for the Swift toolchain), ffmpeg (`brew install ffmpeg`), Node 22.18+.
2. `cd tools/axcli && swift build -c release`
3. `cd orchestrator && npm install`
4. Give the terminal app that runs the harness **Accessibility** and **Screen & System Audio
   Recording** (System Settings → Privacy & Security). Check with `tools/axcli/.build/release/axcli check`.
5. Optional: an "Apple Development" signing identity. build.sh uses it so the app's own
   permission grants (e.g. Desktop folder access) survive rebuilds. Falls back to ad-hoc signing.

## Running

```bash
cd orchestrator
# step 3: loop test, all Haiku, 2 rounds
node run.ts --prompt ../prompts/trivial.md --app-name Counter --max-rounds 2 \
  --models planner=haiku,generator=haiku,evaluator=haiku
# step 4: planner only would be: run, stop after spec, review/trim, then rerun with --spec
# run 1: Haiku generator, Sonnet evaluator
node run.ts --prompt ../prompts/shotbox.md --run-id run1 --max-rounds 5
# run 2: Opus against the same spec (set ANTHROPIC_API_KEY with a spending limit first)
node run.ts --spec ../runs/run1/app/spec.md --run-id run2 --models planner=opus,generator=opus,evaluator=sonnet
```

The panel is at http://127.0.0.1:4317 while a run is going. To look at old runs:
`node panel/server.ts`. Stop rules: all hard criteria pass (`done`), `max_rounds` reached
(`incomplete`), hard pass count flat for two rounds (`stalled`), evaluator sets `spec_issue`
(`spec_issue`, ask a human), more than 40 hard criteria (`needs_trim`).

Auth: with no `ANTHROPIC_API_KEY` the SDK uses the Claude Code login (Team seat, subject to the
5-hour window). Setting the key switches auth; no code change.

## v2: the self-improving loop (`evolve.ts`)

`run.ts` stops when the planner's criteria pass, so the planner's first guess is the ceiling.
`evolve.ts` treats the spec as a floor and keeps raising it:

- **Replan.** When every hard criterion passes, or every `--replan-every` rounds: a researcher
  (web search) works through a lens the loop picks, plus a random far-away analogy; an outsider
  reads only screenshots and argues against the direction; the replanner appends up to
  `--max-new-criteria` criteria, each with its source idea. `guardSpec` restores any edit to an
  existing criterion.
- **Anti-convergence.** `research/obvious.md` (a cold model's default answers) tags obvious ideas;
  `research/ledger.md` forbids repeating a question or source; lenses rotate (`agents/lenses.ts`).
- **Ratchet.** Hard criteria that passed once must keep passing. One round of grace, then the app
  code is reverted to the last good commit.
- **Design track.** Every `--design-every` rounds: K directions, K designers in parallel git
  worktrees, a photographer, and two pairwise judges (craft and character). The winner is merged
  only if it beats the current design.
- **User agent.** Timed realistic tasks (`research/tasks.json`) checked by shell commands. Tasks
  that used to work and now fail go back to the generator as usability regressions.
- **Stops.** Only the budget (`--budget-usd`, estimated), `--max-rounds`, or two empty replans in a
  row. The 5-hour window (`--window-cap`) pauses the loop until reset; a locked screen pauses it
  until unlock, and QA taken on a locked screen is redone. `caffeinate` keeps the display awake.
- **You.** Every `--checkpoint-every` rounds a page lands in `runs/<id>/checkpoints/`. Write
  `veto I-3-2: reason`, `note: …` or `pick design r4-2` into `runs/<id>/feedback.md` whenever you
  like; the loop reads it at the next round and never waits for it.

```bash
cd orchestrator
node evolve.ts --from-run run1 --run-id evo1 --max-rounds 20 --budget-usd 60
```

## Things that are easy to get wrong

- **Connector tools.** Without `strictMcpConfig`, the user's claude.ai connectors (Notion, Slack,
  Figma…) add ~140k tokens of tool definitions to every agent request. A one-command Haiku call
  went from $0.0004 to $0.17. `agents/common.ts` turns them off.
- **Streamed usage is stale.** Assistant frames under-report output tokens. The live cost is an
  estimate; each `agent_end` event carries the correction to the SDK's own total.
- **Input stays inside the app.** `axcli key/type` post events to the target app's process, so the
  agents do not type into whatever app you are using. `--global` (system hotkeys) and `--mouse`
  (real pointer) are the exceptions.
- **Path ids shift.** `w0.3.1` changes when the UI changes. Prefer `@identifier`; the generator
  prompt asks for `.accessibilityIdentifier` on every control.
- **Writes.** Write/Edit are limited per agent (generator: Sources, Package.swift, handoff.md…;
  evaluator: qa_report.md only). Bash is not sandboxed.
