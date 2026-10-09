// Mac app tools for the evaluator (and the generator's self-checks), exposed as an
// in-process MCP server. They wrap tools/axcli, screenshot.sh and record_frames.sh.
// Saved images live in runs/<id>/screenshots/; the tool text names the saved path so
// the event normaliser can put it in the panel gallery.

import { execFile, spawn } from "node:child_process";
import { readFileSync } from "node:fs";
import { join, relative } from "node:path";
import { createSdkMcpServer, tool } from "@anthropic-ai/claude-agent-sdk";
import { z } from "zod";
import type { AgentName } from "../events.ts";

export interface MacToolContext {
  appName: string;
  toolsDir: string;
  runDir: string;
  agent: AgentName;
  round: number;
}

interface Exec { code: number; stdout: string; stderr: string }

function run(cmd: string, args: string[], timeoutMs = 60_000, env?: NodeJS.ProcessEnv): Promise<Exec> {
  return new Promise((ok) => {
    execFile(cmd, args, { timeout: timeoutMs, maxBuffer: 64 * 1024 * 1024, env: env ?? process.env }, (err, stdout, stderr) => {
      const code = err ? (typeof (err as { code?: unknown }).code === "number" ? (err as { code: number }).code : 1) : 0;
      ok({ code, stdout: String(stdout), stderr: String(stderr) });
    });
  });
}

const text = (t: string, isError = false) => ({ content: [{ type: "text" as const, text: t }], isError });

let shotCounter = 0;

export function macToolsServer(ctx: MacToolContext) {
  const axcli = join(ctx.toolsDir, "axcli/.build/release/axcli");
  const env = { ...process.env, AXCLI_APP: ctx.appName };
  const ax = async (args: string[]) => {
    const r = await run(axcli, args, 30_000, env);
    const out = (r.stdout + r.stderr).trim();
    return text(out || `(exit ${r.code})`, r.code !== 0);
  };
  const shotPath = (label: string) =>
    join(ctx.runDir, "screenshots", `r${ctx.round}_${ctx.agent}_${String(++shotCounter).padStart(3, "0")}_${label}.png`);

  /** Downscaled copy for the model; the full-size PNG stays on disk. */
  async function imageBlock(path: string, maxPx: number) {
    const small = path.replace(/\.png$/, `.${maxPx}.png`);
    await run("sips", ["-Z", String(maxPx), path, "--out", small]);
    return { type: "image" as const, data: readFileSync(small).toString("base64"), mimeType: "image/png" };
  }

  type Action = { action: "click" | "doubleclick" | "key" | "type"; id?: string; combo?: string; text?: string; delay_ms?: number };
  async function perform(a: Action) {
    if (a.delay_ms) await new Promise((r) => setTimeout(r, a.delay_ms));
    if (a.action === "key") return ax(["key", a.combo ?? ""]);
    if (a.action === "type") return ax(["type", a.id ?? "", a.text ?? ""]);
    return ax([a.action, a.id ?? ""]);
  }

  return createSdkMcpServer({
    name: "mac",
    version: "1.0.0",
    tools: [
      tool(
        "ax_tree",
        `Dump the accessibility tree of ${ctx.appName} as JSON (role, title, value, desc, identifier, frame [x,y,w,h], enabled, actions). ` +
          "Ids: '@identifier' is stable; path ids like 'w0.3.1' shift when the UI changes, so re-run before reusing them. " +
          "The tree shows an image as one node and says nothing about its pixels: use screenshot for visual checks.",
        {
          window: z.string().optional().describe("window index or title substring; default all windows"),
          menubar: z.boolean().optional().describe("dump the app's menubar status item instead of windows"),
          depth: z.number().int().optional(),
        },
        async (a) => ax(["tree", ...(a.window ? ["--window", a.window] : []), ...(a.menubar ? ["--menubar"] : []), ...(a.depth ? ["--depth", String(a.depth)] : [])]),
      ),
      tool(
        "ax_find",
        "Find elements whose identifier, title, description, value or help contains the text ('*' = all). Returns a flat list with ids. Cheaper than ax_tree.",
        { text: z.string(), role: z.string().optional().describe("e.g. AXButton, AXTextField, AXImage, AXStaticText") },
        async (a) => ax(["find", a.text, ...(a.role ? ["--role", a.role] : [])]),
      ),
      tool(
        "ax_click",
        "Click an element by id via AXPress. double=true double-clicks with the real pointer. mouse=true clicks with the real pointer for elements without AXPress (e.g. grid cards).",
        { id: z.string(), double: z.boolean().optional(), mouse: z.boolean().optional() },
        async (a) => ax([a.double ? "doubleclick" : "click", a.id, ...(a.mouse ? ["--mouse"] : [])]),
      ),
      tool(
        "ax_type",
        "Focus an element and type text into it (keystrokes go to the app only).",
        { id: z.string(), text: z.string() },
        async (a) => ax(["type", a.id, a.text]),
      ),
      tool(
        "ax_key",
        "Send a key combo to the app, e.g. 'cmd+f', 'escape', 'left', 'return', 'cmd+shift+3'. " +
          "global=true sends it to the whole system: needed for system hotkeys (cmd+shift+3/4/5) and for the app's own global hotkey.",
        { combo: z.string(), global: z.boolean().optional() },
        async (a) => ax(["key", a.combo, ...(a.global ? ["--global"] : [])]),
      ),
      tool(
        "screenshot",
        `PNG of one of ${ctx.appName}'s windows, returned as an image. Default: the main window. Pass title to capture another window or panel (e.g. a strip at the screen edge). Never capture the whole screen.`,
        { title: z.string().optional().describe("window title substring; also finds floating panels"), label: z.string().optional().describe("short file label, e.g. 'grid_empty'") },
        async (a) => {
          const out = shotPath((a.label ?? "shot").replace(/[^a-z0-9_-]/gi, "_").slice(0, 40));
          const r = await run(join(ctx.toolsDir, "screenshot.sh"), [ctx.appName, out, ...(a.title ? ["--title", a.title] : [])]);
          if (r.code !== 0) return text(`screenshot failed: ${(r.stderr || r.stdout).trim()}`, true);
          return { content: [{ type: "text" as const, text: `saved: ${relative(ctx.runDir, out)}` }, await imageBlock(out, 1280)] };
        },
      ),
      tool(
        "record_frames",
        "Record the app window for `seconds` and return `n` evenly spaced frames. Put the interaction to judge in `during`; " +
          "it runs ~0.3s after recording starts. Judge motion from the frames: no transition / broken / smooth.",
        {
          seconds: z.number().min(0.5).max(10),
          n: z.number().int().min(2).max(12),
          title: z.string().optional().describe("record this window or panel instead of the main window"),
          during: z
            .array(z.object({
              action: z.enum(["click", "doubleclick", "key", "type"]),
              id: z.string().optional(),
              combo: z.string().optional(),
              text: z.string().optional(),
              delay_ms: z.number().optional(),
            }))
            .optional(),
        },
        async (a) => {
          const dir = shotPath("frames").replace(/\.png$/, "");
          const rec = spawn(join(ctx.toolsDir, "record_frames.sh"), [String(a.seconds), String(a.n), ctx.appName, dir, ...(a.title ? ["--title", a.title] : [])], { env });
          let out = "", err = "";
          rec.stdout.on("data", (d) => (out += d));
          rec.stderr.on("data", (d) => (err += d));
          const done = new Promise<number>((ok) => rec.on("close", (c) => ok(c ?? 1)));
          await new Promise((r) => setTimeout(r, 300));
          const actionResults: string[] = [];
          for (const act of a.during ?? []) {
            const r = await perform(act as Action);
            actionResults.push(`${act.action} ${act.id ?? act.combo ?? ""}: ${r.content[0].text}`);
          }
          if ((await done) !== 0) return text(`record_frames failed: ${(err || out).trim()}`, true);
          const frames = out.trim().split("\n").filter((l) => l.endsWith(".png"));
          const images = await Promise.all(frames.map((f) => imageBlock(f, 640)));
          const saved = frames.map((f) => `saved: ${relative(ctx.runDir, f)}`).join("\n");
          return { content: [{ type: "text" as const, text: `${frames.length} frames over ${a.seconds}s\n${actionResults.join("\n")}\n${saved}` }, ...images] };
        },
      ),
      tool(
        "pasteboard_image",
        "Put an image file on the system pasteboard, as if the user copied it (e.g. after `screencapture -x /tmp/t.png`, or a file in fixtures/).",
        { path: z.string() },
        async (a) => ax(["pbimage", a.path]),
      ),
    ],
  });
}

export const MAC_TOOL_NAMES = ["ax_tree", "ax_find", "ax_click", "ax_type", "ax_key", "screenshot", "record_frames", "pasteboard_image"].map(
  (t) => `mcp__mac__${t}`,
);
