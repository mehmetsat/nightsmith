// One event stream feeds everything. Every Agent SDK message is normalised into
// HarnessEvent and appended to runs/<run_id>/events.jsonl and events.db.
// Observability only reads this; it never makes control decisions.

import { appendFileSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { EventEmitter } from "node:events";
import { DatabaseSync } from "node:sqlite";

export type AgentName = "planner" | "generator" | "evaluator" | "orchestrator";

export type EventType =
  | "agent_start"
  | "agent_end"
  | "assistant_text"
  | "tool_use"
  | "tool_result"
  | "artifact_written"
  | "build_result"
  | "qa_verdict"
  | "round_start"
  | "round_end"
  | "run_start"
  | "run_end"
  | "error";

export interface HarnessEvent {
  ts: string;
  run_id: string;
  agent: AgentName;
  round: number;
  type: EventType;
  tool?: string;
  summary?: string;
  duration_ms?: number;
  input_tokens?: number;
  output_tokens?: number;
  cost_usd?: number;
  payload: Record<string, unknown>;
}

const PAYLOAD_LIMIT = 2048;

// USD per million tokens, for the live estimate only. Cache reads bill at 0.1x input; the SDK
// writes 1-hour cache entries, billed at 2x. agent_end corrects the totals to the SDK's figure.
const PRICES: Record<string, { input: number; output: number }> = {
  haiku: { input: 0.1, output: 0.5 },
  sonnet: { input: 2, output: 10 },
  opus: { input: 4, output: 20 },
};

export function priceFor(model: string): { input: number; output: number } {
  const family = Object.keys(PRICES).find((k) => model.includes(k));
  return PRICES[family ?? "sonnet"];
}

export interface Usage {
  input_tokens?: number;
  output_tokens?: number;
  cache_read_input_tokens?: number | null;
  cache_creation_input_tokens?: number | null;
}

export function usageCost(model: string, u: Usage): number {
  const p = priceFor(model);
  const input =
    (u.input_tokens ?? 0) +
    (u.cache_read_input_tokens ?? 0) * 0.1 +
    (u.cache_creation_input_tokens ?? 0) * 2;
  return (input * p.input + (u.output_tokens ?? 0) * p.output) / 1e6;
}

export function totalInput(u: Usage): number {
  return (u.input_tokens ?? 0) + (u.cache_read_input_tokens ?? 0) + (u.cache_creation_input_tokens ?? 0);
}

/**
 * Keeps the payload under PAYLOAD_LIMIT by cutting its biggest fields, never its ids.
 * Small fields (tool_use_id, is_error, raw, images…) survive, so events still pair up.
 */
function truncatePayload(payload: Record<string, unknown>): Record<string, unknown> {
  if (JSON.stringify(payload).length <= PAYLOAD_LIMIT) return payload;
  const out: Record<string, unknown> = { ...payload, truncated: true };
  const sizes = Object.entries(out).map(([k, v]) => [k, JSON.stringify(v ?? null).length] as const).sort((a, b) => b[1] - a[1]);
  for (const [k, size] of sizes) {
    if (JSON.stringify(out).length <= PAYLOAD_LIMIT) break;
    if (size <= 200) continue;
    const s = typeof out[k] === "string" ? (out[k] as string) : JSON.stringify(out[k]);
    out[k] = s.slice(0, 400) + `… [${s.length} chars]`;
  }
  return out;
}

export class EventLog extends EventEmitter {
  readonly dir: string;
  readonly rawDir: string;
  private db: DatabaseSync;
  private insert: ReturnType<DatabaseSync["prepare"]>;
  private rawCounter = 0;

  readonly runId: string;

  constructor(runId: string, runsRoot: string) {
    super();
    this.runId = runId;
    this.dir = join(runsRoot, runId);
    this.rawDir = join(this.dir, "raw");
    mkdirSync(this.rawDir, { recursive: true });
    mkdirSync(join(this.dir, "screenshots"), { recursive: true });
    mkdirSync(join(this.dir, "artifacts"), { recursive: true });
    this.db = new DatabaseSync(join(this.dir, "events.db"));
    this.db.exec(`CREATE TABLE IF NOT EXISTS events (
      id INTEGER PRIMARY KEY, ts TEXT, run_id TEXT, agent TEXT, round INTEGER, type TEXT,
      tool TEXT, summary TEXT, duration_ms INTEGER, input_tokens INTEGER, output_tokens INTEGER,
      cost_usd REAL, payload TEXT)`);
    this.insert = this.db.prepare(
      `INSERT INTO events (ts, run_id, agent, round, type, tool, summary, duration_ms, input_tokens, output_tokens, cost_usd, payload)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    );
  }

  emitEvent(e: Omit<HarnessEvent, "ts" | "run_id" | "payload"> & { payload?: Record<string, unknown> }): HarnessEvent {
    const ev: HarnessEvent = {
      ts: new Date().toISOString(),
      run_id: this.runId,
      ...e,
      payload: truncatePayload(e.payload ?? {}),
    };
    appendFileSync(join(this.dir, "events.jsonl"), JSON.stringify(ev) + "\n");
    this.insert.run(
      ev.ts, ev.run_id, ev.agent, ev.round, ev.type, ev.tool ?? null, ev.summary ?? null,
      ev.duration_ms ?? null, ev.input_tokens ?? null, ev.output_tokens ?? null, ev.cost_usd ?? null,
      JSON.stringify(ev.payload),
    );
    this.emit("event", ev);
    return ev;
  }

  /** Full, untruncated output goes to runs/<id>/raw/. Returns the relative path. */
  writeRaw(agent: AgentName, round: number, label: string, content: string): string {
    const name = `r${round}_${agent}_${String(++this.rawCounter).padStart(4, "0")}_${label.replace(/[^a-z0-9_-]/gi, "_")}.txt`;
    writeFileSync(join(this.rawDir, name), content);
    return `raw/${name}`;
  }

  query<T = Record<string, unknown>>(sql: string, ...params: (string | number)[]): T[] {
    return this.db.prepare(sql).all(...params) as T[];
  }

  close(): void {
    this.db.close();
  }
}

// ---------------------------------------------------------------------------
// SDK stream -> HarnessEvent

/** Short human summary of a tool call's input, for the panel and the JSONL. */
export function summarizeToolInput(tool: string, input: Record<string, unknown>): string {
  const pick = (k: string) => (typeof input[k] === "string" ? (input[k] as string) : undefined);
  const s =
    pick("command") ?? pick("file_path") ?? pick("path") ?? pick("pattern") ??
    pick("id") ?? pick("combo") ?? pick("text") ?? pick("query") ?? JSON.stringify(input);
  return firstLine(s, 160);
}

export function firstLine(s: string, max = 200): string {
  const line = s.trim().split("\n")[0] ?? "";
  return line.length > max ? line.slice(0, max - 1) + "…" : line;
}

type ContentBlock = { type: string; [k: string]: unknown };

/**
 * Stateful normaliser for one agent session. Feed it every SDK message in order.
 * Token usage arrives per API message, possibly repeated across streamed frames of
 * the same message id, so it is counted once per id as a delta.
 */
export class SdkNormalizer {
  private toolStart = new Map<string, { tool: string; at: number }>();
  private seenUsage = new Map<string, { input: number; output: number; cost: number }>();
  lastContextTokens = 0;
  totals = { input_tokens: 0, output_tokens: 0, cost_usd: 0 };

  private log: EventLog;
  private agent: AgentName;
  private round: number;
  private model: string;

  constructor(log: EventLog, agent: AgentName, round: number, model: string) {
    this.log = log;
    this.agent = agent;
    this.round = round;
    this.model = model;
  }

  handle(msg: { type: string; [k: string]: unknown }): void {
    if (msg.type === "assistant") this.onAssistant(msg);
    else if (msg.type === "user") this.onUser(msg);
    else if (msg.type === "result") this.onResult(msg);
  }

  private usageDelta(id: string, model: string, u: Usage) {
    const now = { input: totalInput(u), output: u.output_tokens ?? 0, cost: usageCost(model, u) };
    const prev = this.seenUsage.get(id) ?? { input: 0, output: 0, cost: 0 };
    this.seenUsage.set(id, now);
    const d = { input: now.input - prev.input, output: now.output - prev.output, cost: now.cost - prev.cost };
    this.totals.input_tokens += d.input;
    this.totals.output_tokens += d.output;
    this.totals.cost_usd += d.cost;
    if (now.input > 0) this.lastContextTokens = now.input;
    return d;
  }

  private onAssistant(msg: Record<string, unknown>) {
    if (msg.parent_tool_use_id) return; // subagent frames; agents here do not spawn subagents
    const m = msg.message as { id: string; model?: string; content: ContentBlock[]; usage?: Usage };
    const d = m.usage ? this.usageDelta(m.id, m.model ?? this.model, m.usage) : { input: 0, output: 0, cost: 0 };
    let first = true;
    for (const block of m.content ?? []) {
      // Attach this frame's token delta to its first event so per-event sums equal totals.
      const tokens = first ? { input_tokens: d.input, output_tokens: d.output, cost_usd: d.cost } : {};
      if (block.type === "text" && typeof block.text === "string" && block.text.trim()) {
        this.log.emitEvent({
          agent: this.agent, round: this.round, type: "assistant_text",
          summary: firstLine(block.text), ...tokens,
          payload: { text: block.text, context_tokens: this.lastContextTokens },
        });
        first = false;
      } else if (block.type === "tool_use") {
        const name = String(block.name).replace(/^mcp__mac__/, "");
        const input = (block.input ?? {}) as Record<string, unknown>;
        this.toolStart.set(String(block.id), { tool: name, at: Date.now() });
        this.log.emitEvent({
          agent: this.agent, round: this.round, type: "tool_use", tool: name,
          summary: summarizeToolInput(name, input), ...tokens,
          payload: { tool_use_id: block.id, input, context_tokens: this.lastContextTokens },
        });
        first = false;
      }
    }
    if (first && (d.input || d.output)) {
      // Thinking-only frame: still account for its tokens.
      this.log.emitEvent({
        agent: this.agent, round: this.round, type: "assistant_text", summary: "(thinking)",
        input_tokens: d.input, output_tokens: d.output, cost_usd: d.cost, payload: {},
      });
    }
  }

  private onUser(msg: Record<string, unknown>) {
    if (msg.parent_tool_use_id) return;
    const m = msg.message as { content: string | ContentBlock[] };
    if (typeof m.content === "string") return;
    for (const block of m.content) {
      if (block.type !== "tool_result") continue;
      const id = String(block.tool_use_id);
      const start = this.toolStart.get(id);
      this.toolStart.delete(id);
      const text = toolResultText(block.content);
      const raw = this.log.writeRaw(this.agent, this.round, start?.tool ?? "tool", text);
      // Mac tools name every image they save as "saved: screenshots/<file>.png".
      const images = [...text.matchAll(/saved: (screenshots\/\S+\.png)/g)].map((m) => m[1]);
      this.log.emitEvent({
        agent: this.agent, round: this.round, type: "tool_result", tool: start?.tool,
        summary: firstLine(text || (images.length ? `${images.length} image(s)` : "(empty)")),
        duration_ms: start ? Date.now() - start.at : undefined,
        payload: { tool_use_id: id, is_error: block.is_error === true, raw, bytes: text.length, images },
      });
    }
  }

  private onResult(msg: Record<string, unknown>) {
    this.resultMessage = msg;
  }

  resultMessage: Record<string, unknown> | null = null;
}

function toolResultText(content: unknown): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content
      .map((c: ContentBlock) => (c.type === "text" ? String(c.text) : c.type === "image" ? "[image]" : `[${c.type}]`))
      .join("\n");
  }
  return content == null ? "" : JSON.stringify(content);
}
